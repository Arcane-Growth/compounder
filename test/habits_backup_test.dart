import 'dart:convert';
import 'dart:io';

import 'package:compounder/data/store.dart';
import 'package:compounder/services/backup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature 4 backup proofs: habits and their completions round-trip through the
/// format-4 export/import, and an older backup that predates habits still
/// imports (clearing local habits rather than leaving stale rows).

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
    docs = await Directory.systemTemp.createTemp('compounder_habits_backup');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return docs.path;
      return null;
    });
    final base = await databaseFactory.getDatabasesPath();
    dbPath = p.join(base, 'compounder_habits_backup_source.db');
    otherDbPath = p.join(base, 'compounder_habits_backup_target.db');
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

  test('habits and completions round-trip through export/import', () async {
    final prefs = await SharedPreferences.getInstance();
    final source = await AppStore.open(prefs, path: dbPath);
    final readId = await source.createHabit('Read', 'weekly', 3);
    final walkId = await source.createHabit('Walk', 'daily', 1);
    await source.updateHabit(walkId, archived: true);
    await source.setHabitCompletion(readId, DateTime(2026, 11, 2), true);
    await source.setHabitCompletion(readId, DateTime(2026, 11, 4), true);
    await source.setHabitCompletion(walkId, DateTime(2026, 11, 8), true);

    final file = await BackupService.export(source);
    final json =
        jsonDecode(await File(file).readAsString()) as Map<String, Object?>;
    expect(json['format'], 5,
        reason: 'plan blocks require the format bump to 5 (habits bumped it to 4)');
    expect(json['habits'], hasLength(2));
    expect(json['habitCompletions'], hasLength(3));

    // Import into a different, empty database so nothing survives by luck.
    final target = await AppStore.open(prefs, path: otherDbPath);
    expect(await target.db.query('habits'), isEmpty);
    await BackupService.import(target, file);

    final habits = await target.db.query('habits', orderBy: 'id');
    expect(habits, hasLength(2));
    expect(habits[0]['name'], 'Read');
    expect(habits[0]['cadence'], 'weekly');
    expect(habits[0]['target'], 3);
    expect(habits[0]['archived'], 0);
    expect(habits[1]['name'], 'Walk');
    expect(habits[1]['archived'], 1);

    final completions =
        await target.db.query('habit_completions', orderBy: 'habit_id, day');
    expect(completions, hasLength(3));
    expect(completions.map((c) => c['day']).toList(),
        ['2026-11-02', '2026-11-04', '2026-11-08']);
    expect(completions.map((c) => c['habit_id']).toList(),
        [readId, readId, walkId],
        reason: 'completions must keep pointing at their habit');

    // The in-memory caches must reflect the restored rows.
    expect(target.habits, hasLength(2));
    expect(target.habitCompletions, hasLength(3));

    await source.db.close();
    await target.db.close();
  });

  test('a format-3 backup without habits still imports and clears local habits',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final target = await AppStore.open(prefs, path: otherDbPath);
    // Pre-existing local habit data that the import must replace.
    final staleId = await target.createHabit('Stale', 'daily', 1);
    await target.setHabitCompletion(staleId, DateTime(2026, 11, 8), true);

    final legacy = File(p.join(docs.path, 'legacy-format-3.json'));
    await legacy.writeAsString(jsonEncode({
      'format': 3,
      'app': 'compounder',
      'exportedAt': '2026-11-01T00:00:00.000',
      'workouts': <Object?>[],
      'workoutExercises': <Object?>[],
      'workoutSets': <Object?>[],
      'exercises': <Object?>[],
      'customExercises': <Object?>[],
      'meals': <Object?>[],
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

    await BackupService.import(target, legacy.path);

    expect(await target.db.query('habits'), isEmpty,
        reason: 'a file without habits must clear the local ones');
    expect(await target.db.query('habit_completions'), isEmpty);
    expect(target.habits, isEmpty);
    expect(target.habitCompletions, isEmpty);
    await target.db.close();
  });

  test('a format-2 backup without habits still imports', () async {
    final prefs = await SharedPreferences.getInstance();
    final target = await AppStore.open(prefs, path: otherDbPath);
    final staleId = await target.createHabit('Stale', 'daily', 1);
    await target.setHabitCompletion(staleId, DateTime(2026, 11, 8), true);

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
      'accounts': <Object?>[],
      'moods': <Object?>[],
      'meditations': <Object?>[],
      'thoughtRecords': <Object?>[],
      'healthRecords': <Object?>[],
      'healthDaily': <Object?>[],
      'healthSyncState': <Object?>[],
    }));

    await BackupService.import(target, legacy.path);
    expect(await target.db.query('habits'), isEmpty);
    expect(await target.db.query('habit_completions'), isEmpty);
    await target.db.close();
  });

  test('an orphan habit completion fails the import with a readable message',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final target = await AppStore.open(prefs, path: otherDbPath);
    final keepId = await target.createHabit('Keep', 'daily', 1);
    await target.setHabitCompletion(keepId, DateTime(2026, 11, 8), true);

    final orphan = File(p.join(docs.path, 'orphan-completion.json'));
    await orphan.writeAsString(jsonEncode({
      'format': 4,
      'app': 'compounder',
      'habits': [
        {
          'id': 1,
          'name': 'Read',
          'cadence': 'daily',
          'target': 1,
          'archived': 0,
          'created_at': 0,
        },
      ],
      'habitCompletions': [
        {
          'id': 1,
          'habit_id': 7,
          'day': '2026-11-08',
          'count': 1,
          'created_at': 0,
        },
      ],
    }));

    await expectLater(
        BackupService.import(target, orphan.path),
        throwsA(isA<BackupException>().having((e) => e.message, 'message',
            contains('references habit 7, which is not in the file'))));

    // The transaction rolled back: the local habit and its completion survive.
    expect(await target.db.query('habits'), hasLength(1));
    expect(await target.db.query('habit_completions'), hasLength(1));
    expect(target.habits.single.name, 'Keep');
    await target.db.close();
  });

  test('a backup from a newer format is refused', () async {
    final prefs = await SharedPreferences.getInstance();
    final target = await AppStore.open(prefs, path: otherDbPath);
    final future = File(p.join(docs.path, 'format-6.json'));
    await future.writeAsString(jsonEncode({
      'format': 6,
      'app': 'compounder',
      'habits': <Object?>[],
    }));

    await expectLater(
        BackupService.import(target, future.path), throwsA(isA<Exception>()));
    await target.db.close();
  });
}
