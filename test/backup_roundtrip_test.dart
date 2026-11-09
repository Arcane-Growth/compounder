import 'dart:convert';
import 'dart:io';

import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/services/backup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Baseline audit M2: the backup export omitted `balance_snapshots` and
/// `reminders`, and the import never cleared them, so a restore silently
/// dropped net-worth history and every reminder. These tests pin the
/// round-trip (counts survive), the format-2 compatibility path, and the
/// format bump.
///
/// Baseline audit m4: `saveAccount` inserted a `balance_snapshots` row with
/// `account_id = 0` when the UPDATE matched no row. The tests below pin the
/// guard and the `PRAGMA foreign_keys = ON` setting that makes the declared
/// cascades real.

/// path_provider is a plugin, so its method channel has to be answered by hand
/// in a unit test. Export writes into the documents directory.
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory docs;
  late String dbPath;
  late String otherDbPath;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    docs = await Directory.systemTemp.createTemp('compounder_backup_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return docs.path;
      return null;
    });
    final base = await databaseFactory.getDatabasesPath();
    dbPath = p.join(base, 'compounder_backup_source_test.db');
    otherDbPath = p.join(base, 'compounder_backup_target_test.db');
    await databaseFactory.deleteDatabase(dbPath);
    await databaseFactory.deleteDatabase(otherDbPath);
  });

  tearDown(() async {
    await databaseFactory.deleteDatabase(dbPath);
    await databaseFactory.deleteDatabase(otherDbPath);
    await docs.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
  });

  /// Seeds one row in every table the backup carries, so a round-trip can be
  /// checked table by table rather than only on the two tables M2 named.
  /// Returns the reminder's due time, which must be in the future for the
  /// store's due-reminder cache to surface it.
  Future<int> seed(AppStore store) async {
    final dueAt = DateTime.now().millisecondsSinceEpoch + 86400000;
    final workoutId = await store.db.insert('workouts', {
      'name': 'Leg day',
      'started_at': 1000,
      'ended_at': 2000,
    });
    final entryId = await store.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': 1,
      'position': 0,
    });
    await store.db.insert('workout_sets', {
      'workout_exercise_id': entryId,
      'position': 0,
      'weight_kg': 100.0,
      'reps': 5,
      'completed_at': 1500,
      'is_warmup': 0,
    });
    await store.db.insert('meals', {
      'timestamp': 3000,
      'dish': 'Oats',
      'calories': 400.0,
      'protein': 20.0,
      'carbs': 50.0,
      'fat': 8.0,
    });
    final accountId = await store.db.insert('accounts', {
      'name': 'Checking',
      'type': 'Cash',
      'balance': 1234.0,
      'updated_at': 4000,
    });
    await store.db.insert('balance_snapshots', {
      'account_id': accountId,
      'balance': 1234.0,
      'taken_at': 4000,
    });
    await store.db.insert('reminders', {
      'text': 'Stretch',
      'due_at': dueAt,
      'created_at': 4500,
    });
    await store.db.insert('moods', {
      'timestamp': 6000,
      'mood': 4,
      'note': 'ok',
    });
    await store.db.insert('meditations', {
      'timestamp': 7000,
      'minutes': 10,
      'kind': 'Breathing',
    });
    await store.db.insert('thought_records', {
      'timestamp': 8000,
      'situation': 's',
      'thought': 't',
      'reframe': 'r',
    });
    await store.db.insert('plan_blocks', {
      'day': '2026-11-09',
      'title': 'Deep work',
      'start_min': 540,
      'end_min': 600,
      'done': 0,
      'created_at': 9000,
      'position': 0,
    });
    return dueAt;
  }

  test('export/import round-trip keeps balance snapshots and reminders',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final source = await AppStore.open(prefs, path: dbPath);
    final dueAt = await seed(source);

    final file = await BackupService.export(source);
    final json =
        jsonDecode(await File(file).readAsString()) as Map<String, Object?>;
    expect(json['format'], 5,
        reason:
            'plan blocks require the format bump to 5 (habits bumped it to 4)');
    expect(json['app'], 'compounder');
    expect(json['balanceSnapshots'], hasLength(1));
    expect(json['reminders'], hasLength(1));
    expect(json['planBlocks'], hasLength(1),
        reason: 'the day planner must be part of the backup');
    // The format-2 key names must not change.
    for (final key in [
      'workouts',
      'workoutExercises',
      'workoutSets',
      'exercises',
      'customExercises',
      'meals',
      'accounts',
      'moods',
      'meditations',
      'thoughtRecords',
      'healthRecords',
      'healthDaily',
      'healthSyncState',
    ]) {
      expect(json.containsKey(key), isTrue, reason: '$key must stay exported');
    }

    // Import into a *different*, empty database so nothing survives by luck.
    final target = await AppStore.open(prefs, path: otherDbPath);
    expect(await target.db.query('balance_snapshots'), isEmpty);
    expect(await target.db.query('reminders'), isEmpty);

    await BackupService.import(target, file);

    expect(await target.db.query('accounts'), hasLength(1));
    final snapshots = await target.db.query('balance_snapshots');
    expect(snapshots, hasLength(1),
        reason: 'net-worth history must survive the round-trip');
    expect(snapshots.single['account_id'], 1);
    expect(snapshots.single['balance'], 1234.0);
    expect(snapshots.single['taken_at'], 4000);
    final reminders = await target.db.query('reminders');
    expect(reminders, hasLength(1),
        reason: 'reminders must survive the round-trip');
    expect(reminders.single['text'], 'Stretch');
    expect(reminders.single['due_at'], dueAt);
    // Everything else still round-trips.
    expect(await target.db.query('workouts'), hasLength(1));
    expect(await target.db.query('workout_exercises'), hasLength(1));
    expect(await target.db.query('workout_sets'), hasLength(1));
    expect(await target.db.query('meals'), hasLength(1));
    expect(await target.db.query('moods'), hasLength(1));
    expect(await target.db.query('meditations'), hasLength(1));
    expect(await target.db.query('thought_records'), hasLength(1));
    final planBlocks = await target.db.query('plan_blocks');
    expect(planBlocks, hasLength(1),
        reason: 'plan blocks must survive the round-trip');
    expect(planBlocks.single['day'], '2026-11-09');
    expect(planBlocks.single['title'], 'Deep work');
    expect(planBlocks.single['start_min'], 540);
    expect(planBlocks.single['end_min'], 600);

    // The in-memory caches must reflect the restored rows, not the old ones.
    expect(target.accounts, hasLength(1));
    expect(target.netWorthHistory, isNotEmpty,
        reason: 'restored snapshots must feed the net-worth series');
    expect(target.reminders, hasLength(1));

    await source.db.close();
    await target.db.close();
  });

  test('import remaps exercise ids so workout entries keep their exercise',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final source = await AppStore.open(prefs, path: dbPath);
    // Source device: the user created a custom exercise FIRST, so it took id 1
    // and the built-in catalog row that followed took id 2.
    final customId = await source.db.insert('exercises', {
      'name': 'My Custom Lift',
      'muscle_group': 'Chest',
      'equipment': 'Barbell',
      'is_custom': 1,
    });
    final benchId = await source.db.insert('exercises', {
      'name': 'Bench Press',
      'muscle_group': 'Chest',
      'equipment': 'Barbell',
      'is_custom': 0,
    });
    expect(customId, 1);
    expect(benchId, 2);
    final workoutId = await source.db.insert('workouts', {
      'name': 'Push day',
      'started_at': 1000,
      'ended_at': 2000,
    });
    await source.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': benchId,
      'position': 0,
    });
    await source.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': customId,
      'position': 1,
    });

    final file = await BackupService.export(source);

    // Target device: the seeder ran first, so built-ins occupy ids 1-2 and the
    // source's custom id 1 collides with Bench Press.
    final target = await AppStore.open(prefs, path: otherDbPath);
    await target.db.insert('exercises', {
      'name': 'Bench Press',
      'muscle_group': 'Chest',
      'equipment': 'Barbell',
      'is_custom': 0,
    });
    await target.db.insert('exercises', {
      'name': 'Squat',
      'muscle_group': 'Legs',
      'equipment': 'Barbell',
      'is_custom': 0,
    });

    await BackupService.import(target, file);

    // The built-in catalog must not be overwritten by the custom row.
    final exercises = await target.db.query('exercises', orderBy: 'id');
    expect(exercises.firstWhere((e) => e['id'] == 1)['name'], 'Bench Press',
        reason: 'a custom exercise must not overwrite a built-in');
    expect(exercises.firstWhere((e) => e['id'] == 2)['name'], 'Squat');
    final restoredCustom =
        exercises.firstWhere((e) => e['name'] == 'My Custom Lift');
    expect(restoredCustom['is_custom'], 1);
    expect(restoredCustom['id'], isNot(1),
        reason:
            'the custom exercise must get a fresh id, not the colliding one');

    // Every workout entry must still resolve to the same exercise NAME.
    final entries =
        await target.db.query('workout_exercises', orderBy: 'position');
    expect(entries, hasLength(2));
    final names = <String>[];
    for (final e in entries) {
      final rows = await target.db.query('exercises',
          where: 'id = ?', whereArgs: [e['exercise_id']], limit: 1);
      expect(rows, hasLength(1),
          reason: 'entry must point at an existing exercise');
      names.add(rows.single['name'] as String);
    }
    expect(names, ['Bench Press', 'My Custom Lift'],
        reason: 'workout history must not silently change exercise');

    // The store's own view of the workout agrees.
    final detail = await target.workoutDetail(1);
    expect(detail, isNotNull);
    expect(detail!.exercises.map((e) => e.exercise.name).toList(),
        ['Bench Press', 'My Custom Lift']);

    await source.db.close();
    await target.db.close();
  });

  test('two custom exercises sharing a name keep their own equipment',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final source = await AppStore.open(prefs, path: dbPath);
    // `AppStore.createExercise` has no uniqueness constraint, so a user really
    // can create "Curl" twice with different equipment. Matching exercises by
    // name alone would collapse these two rows into one on import, silently
    // losing the second one's metadata and repointing its workout entry.
    await source.createExercise('Curl', 'Arms', 'Dumbbell');
    await source.createExercise('Curl', 'Arms', 'Barbell');
    final curls = await source.db.query('exercises', orderBy: 'id');
    expect(curls, hasLength(2));
    final dumbbellId = curls[0]['id'] as int;
    final barbellId = curls[1]['id'] as int;
    final workoutId = await source.db.insert('workouts', {
      'name': 'Arms day',
      'started_at': 1000,
      'ended_at': 2000,
    });
    await source.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': dumbbellId,
      'position': 0,
    });
    await source.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': barbellId,
      'position': 1,
    });

    final file = await BackupService.export(source);

    final target = await AppStore.open(prefs, path: otherDbPath);
    await BackupService.import(target, file);

    // Both rows must survive, each with its own equipment.
    final restored = await target.db
        .query('exercises', where: 'is_custom = 1', orderBy: 'id');
    expect(restored, hasLength(2),
        reason: 'two distinct custom exercises must not collapse into one');
    expect(restored.map((e) => e['name']).toList(), ['Curl', 'Curl']);
    expect(
        restored.map((e) => e['equipment']).toList(), ['Dumbbell', 'Barbell'],
        reason: 'equipment metadata must survive the import');

    // Each workout entry must resolve to its own exercise, not both to the
    // first one.
    final entries =
        await target.db.query('workout_exercises', orderBy: 'position');
    expect(entries, hasLength(2));
    final entryIds = entries.map((e) => e['exercise_id']).toList();
    expect(entryIds.toSet(), hasLength(2),
        reason: 'each entry must point at a different exercise row');
    final resolved = <String>[];
    for (final e in entries) {
      final rows = await target.db.query('exercises',
          where: 'id = ?', whereArgs: [e['exercise_id']], limit: 1);
      expect(rows, hasLength(1),
          reason: 'entry must point at an existing exercise');
      resolved.add('${rows.single['name']}:${rows.single['equipment']}');
    }
    expect(resolved, ['Curl:Dumbbell', 'Curl:Barbell'],
        reason: 'workout history must not silently change equipment');

    // The store's own view of the workout agrees.
    final detail = await target.workoutDetail(1);
    expect(detail, isNotNull);
    expect(
        detail!.exercises
            .map((e) => '${e.exercise.name}:${e.exercise.equipment}')
            .toList(),
        ['Curl:Dumbbell', 'Curl:Barbell']);

    await source.db.close();
    await target.db.close();
  });

  test('a file carrying columns this build does not know still imports',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final target = await AppStore.open(prefs, path: otherDbPath);
    // A future build adds columns to several tables but keeps format 3. This
    // build must still import the file, dropping only the fields it cannot
    // represent — inserting them verbatim would abort the whole transaction.
    final future = File(p.join(docs.path, 'future-format-3.json'));
    await future.writeAsString(jsonEncode({
      'format': 3,
      'app': 'compounder',
      'exportedAt': '2026-11-07T00:00:00.000',
      'workouts': [
        {
          'id': 1,
          'name': 'Push day',
          'started_at': 1000,
          'ended_at': 2000,
          'rpe_target': 8,
        }
      ],
      'workoutExercises': [
        {
          'id': 1,
          'workout_id': 1,
          'exercise_id': 1,
          'position': 0,
          'tempo': '3-1-1',
        }
      ],
      'workoutSets': [
        {
          'id': 1,
          'workout_exercise_id': 1,
          'position': 0,
          'weight_kg': 100.0,
          'reps': 5,
          'completed_at': 1500,
          'is_warmup': 0,
          'velocity_ms': 0.42,
        }
      ],
      'exercises': [
        {
          'id': 1,
          'name': 'Bench Press',
          'muscle_group': 'Chest',
          'equipment': 'Barbell',
          'is_custom': 0,
          'tempo': '3-1-1',
        }
      ],
      'customExercises': <Object?>[],
      'meals': [
        {
          'id': 1,
          'timestamp': 3000,
          'dish': 'Oats',
          'calories': 400.0,
          'protein': 20.0,
          'carbs': 50.0,
          'fat': 8.0,
          'photo_id': 'abc123',
        }
      ],
      'accounts': <Object?>[],
      'balanceSnapshots': <Object?>[],
      'reminders': <Object?>[],
      'moods': <Object?>[],
      'meditations': <Object?>[],
      'thoughtRecords': <Object?>[],
      'healthRecords': <Object?>[],
      'healthDaily': <Object?>[],
      'healthSyncState': <Object?>[],
    }));

    await BackupService.import(target, future.path);

    // The known columns landed; the unknown ones were dropped, not fatal.
    final exercises = await target.db.query('exercises');
    expect(exercises, hasLength(1));
    expect(exercises.single['name'], 'Bench Press');
    expect(exercises.single['equipment'], 'Barbell');
    expect(exercises.single.containsKey('tempo'), isFalse);

    final workouts = await target.db.query('workouts');
    expect(workouts, hasLength(1));
    expect(workouts.single['name'], 'Push day');
    expect(workouts.single.containsKey('rpe_target'), isFalse);

    final entries = await target.db.query('workout_exercises');
    expect(entries, hasLength(1));
    expect(entries.single['exercise_id'], exercises.single['id'],
        reason: 'the remap must still run on a forward-compatible file');
    expect(entries.single.containsKey('tempo'), isFalse);

    final sets = await target.db.query('workout_sets');
    expect(sets, hasLength(1));
    expect(sets.single['weight_kg'], 100.0);
    expect(sets.single.containsKey('velocity_ms'), isFalse);

    final meals = await target.db.query('meals');
    expect(meals, hasLength(1));
    expect(meals.single['dish'], 'Oats');
    expect(meals.single.containsKey('photo_id'), isFalse);

    await target.db.close();
  });

  test('a built-in whose metadata drifted reuses the target catalog row',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final target = await AppStore.open(prefs, path: otherDbPath);
    // The target catalog calls Bench Press a Barbell lift; a newer build's file
    // calls the same built-in a Smith Machine lift. Built-ins are matched by
    // name alone on purpose: keying them on equipment too would insert a second
    // "Bench Press" row instead of reusing the catalog entry, and the workout
    // entry would then point at a duplicate the picker also shows.
    await target.db.insert('exercises', {
      'name': 'Bench Press',
      'muscle_group': 'Chest',
      'equipment': 'Barbell',
      'is_custom': 0,
    });
    final file = File(p.join(docs.path, 'builtin-drift.json'));
    await file.writeAsString(jsonEncode({
      'format': 3,
      'app': 'compounder',
      'exercises': [
        {
          'id': 1,
          'name': 'Bench Press',
          'muscle_group': 'Chest',
          'equipment': 'Smith Machine',
          'is_custom': 0,
        }
      ],
      'customExercises': <Object?>[],
      'workouts': [
        {'id': 1, 'name': 'Push day', 'started_at': 1, 'ended_at': 2}
      ],
      'workoutExercises': [
        {'id': 1, 'workout_id': 1, 'exercise_id': 1, 'position': 0}
      ],
    }));

    await BackupService.import(target, file.path);

    final rows = await target.db.query('exercises');
    expect(rows, hasLength(1),
        reason: 'built-in metadata drift must not duplicate the catalog row');
    expect(rows.single['equipment'], 'Barbell',
        reason: 'the target catalog row is reused, not replaced');
    final entries = await target.db.query('workout_exercises');
    expect(entries.single['exercise_id'], rows.single['id']);

    await target.db.close();
  });

  test('a format-2 backup still imports (no snapshots/reminders keys)',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final target = await AppStore.open(prefs, path: otherDbPath);
    // Pre-existing local data that the import must replace.
    final accountId = await target.db.insert('accounts', {
      'name': 'Old',
      'type': 'Cash',
      'balance': 1.0,
      'updated_at': 1,
    });
    await target.db.insert('balance_snapshots', {
      'account_id': accountId,
      'balance': 1.0,
      'taken_at': 1,
    });
    await target.db.insert('reminders', {
      'text': 'Old reminder',
      'due_at': 2,
      'created_at': 1,
    });

    // A genuine format-2 file: the keys M2 added are absent entirely.
    final legacy = File(p.join(docs.path, 'legacy-format-2.json'));
    await legacy.writeAsString(jsonEncode({
      'format': 2,
      'app': 'compounder',
      'exportedAt': '2026-01-01T00:00:00.000',
      'workouts': <Object?>[],
      'workoutExercises': <Object?>[],
      'workoutSets': <Object?>[],
      'customExercises': <Object?>[],
      'meals': <Object?>[],
      'accounts': [
        {
          'id': 1,
          'name': 'Restored',
          'type': 'Bank',
          'balance': 99.0,
          'currency': 'USD',
          'updated_at': 10,
        }
      ],
      'moods': <Object?>[],
      'meditations': <Object?>[],
      'thoughtRecords': <Object?>[],
      'healthRecords': <Object?>[],
      'healthDaily': <Object?>[],
      'healthSyncState': <Object?>[],
    }));

    await BackupService.import(target, legacy.path);

    expect(await target.db.query('accounts'), hasLength(1));
    expect((await target.db.query('accounts')).single['name'], 'Restored');
    // A format-2 file carries no snapshot/reminder data, so the import clears
    // the local rows rather than leaving stale ones behind.
    expect(await target.db.query('balance_snapshots'), isEmpty);
    expect(await target.db.query('reminders'), isEmpty);

    await target.db.close();
  });

  test('a backup from a newer format is refused, not silently truncated',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final target = await AppStore.open(prefs, path: otherDbPath);
    final future = File(p.join(docs.path, 'format-6.json'));
    await future.writeAsString(jsonEncode({
      'format': 6,
      'app': 'compounder',
      'accounts': <Object?>[],
    }));

    await expectLater(
        BackupService.import(target, future.path), throwsA(isA<Exception>()));
    await target.db.close();
  });

  test('saveAccount writes no orphan snapshot when the account is gone',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await AppStore.open(prefs, path: dbPath);

    // The account was deleted while the editor was open: the UPDATE matches
    // zero rows, so no snapshot may be written for account_id 0.
    await store.saveAccount(const Account(
        id: 999, name: 'Ghost', type: 'Cash', balance: 10.0, updatedAt: 0));
    expect(await store.db.query('accounts'), isEmpty);
    expect(await store.db.query('balance_snapshots'), isEmpty,
        reason: 'a failed UPDATE must not leave an account_id = 0 snapshot');

    // Positive control: a new account still gets its baseline snapshot.
    await store.saveAccount(const Account(
        id: 0, name: 'Real', type: 'Cash', balance: 50.0, updatedAt: 0));
    final accounts = await store.db.query('accounts');
    expect(accounts, hasLength(1));
    final snapshots = await store.db.query('balance_snapshots');
    expect(snapshots, hasLength(1));
    expect(snapshots.single['account_id'], accounts.single['id']);

    await store.db.close();
  });

  test('foreign keys are enforced on every connection', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await AppStore.open(prefs, path: dbPath);

    final pragma = await store.db.rawQuery('PRAGMA foreign_keys');
    expect(pragma.single.values.first, 1,
        reason: 'onConfigure must enable PRAGMA foreign_keys');

    // A child row with a missing parent must be rejected outright.
    await expectLater(
        store.db.insert('workout_exercises',
            {'workout_id': 4242, 'exercise_id': 1, 'position': 0}),
        throwsA(isA<DatabaseException>()));

    // And the declared cascade must actually fire.
    final workoutId = await store.db.insert('workouts', {
      'name': 'Push day',
      'started_at': 1000,
      'ended_at': 2000,
    });
    final entryId = await store.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': 1,
      'position': 0,
    });
    await store.db.insert('workout_sets', {
      'workout_exercise_id': entryId,
      'position': 0,
      'weight_kg': 60.0,
      'reps': 8,
      'completed_at': 1500,
      'is_warmup': 0,
    });
    await store.db.delete('workouts', where: 'id = ?', whereArgs: [workoutId]);
    expect(await store.db.query('workout_exercises'), isEmpty,
        reason: 'ON DELETE CASCADE must remove the child entries');
    expect(await store.db.query('workout_sets'), isEmpty,
        reason: 'ON DELETE CASCADE must remove the grandchild sets');

    await store.db.close();
  });
}
