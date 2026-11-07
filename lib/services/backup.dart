import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/store.dart';

/// Whole-database backup as one portable JSON file. Export writes a file and
/// hands it to the system share sheet; import replaces all local data.
class BackupService {
  /// Current backup format. 3 adds `balanceSnapshots` and `reminders`; a
  /// format-2 file simply lacks those keys and still imports (restoring
  /// everything it does carry).
  static const int format = 3;

  static Future<String> export(AppStore store) async {
    final db = store.db;
    final data = {
      'format': format,
      'app': 'compounder',
      'exportedAt': DateTime.now().toIso8601String(),
      'workouts': await db.query('workouts'),
      'workoutExercises': await db.query('workout_exercises'),
      'workoutSets': await db.query('workout_sets'),
      // The full catalog, not just the custom rows: import has to resolve
      // every `workout_exercises.exercise_id` by NAME, and a workout may
      // reference a built-in whose id differs on the target device.
      'exercises': await db.query('exercises'),
      'customExercises': await db.query('exercises', where: 'is_custom = 1'),
      'meals': await db.query('meals'),
      'accounts': await db.query('accounts'),
      'balanceSnapshots': await db.query('balance_snapshots'),
      'reminders': await db.query('reminders'),
      'moods': await db.query('moods'),
      'meditations': await db.query('meditations'),
      'thoughtRecords': await db.query('thought_records'),
      'healthRecords': await db.query('health_records'),
      'healthDaily': await db.query('health_daily'),
      'healthSyncState': await db.query('health_sync_state'),
    };
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path,
        'compounder-backup-${DateTime.now().millisecondsSinceEpoch}.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return file.path;
  }

  static Future<int> import(AppStore store, String path) async {
    final data =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    if (data['app'] != 'compounder') {
      throw Exception('Not a Compounder backup file');
    }
    // Format 2 files predate balanceSnapshots/reminders and are still accepted:
    // the missing keys read as empty lists, so the import restores everything
    // the file does carry. A newer format is refused rather than silently
    // dropping fields this build does not understand.
    final fileFormat = data['format'];
    if (fileFormat is int && fileFormat > format) {
      throw Exception(
          'Backup format $fileFormat is newer than this app supports ($format)');
    }
    final db = store.db;

    List<Map<String, Object?>> rows(String key) =>
        ((data[key] as List?) ?? []).cast<Map<String, Object?>>();

    await db.transaction((txn) async {
      for (final table in [
        'workout_sets',
        'workout_exercises',
        'workouts',
        'meals',
        'balance_snapshots',
        'accounts',
        'reminders',
        'moods',
        'meditations',
        'thought_records',
        'health_records',
        'health_daily',
        'health_sync_state',
      ]) {
        await txn.delete(table);
      }
      await txn.delete('exercises', where: 'is_custom = 1');
      // Exercise ids are device-local. The built-in catalog is seeded in a
      // different order on a different install, so a custom exercise's id on
      // the source can collide with a built-in's id on the target. Inserting
      // the file's rows by their original ids would overwrite that built-in
      // and silently repoint every workout entry that referenced it. Resolve
      // exercises by NAME instead, let SQLite assign fresh ids, and rewrite
      // the workout references through the resulting map.
      final sourceExercises = <Map<String, Object?>>[];
      final seenExerciseIds = <Object?>{};
      // `exercises` carries the whole catalog (format 3 files written by this
      // build); older files only carry `customExercises`, in which case
      // built-in references keep their original ids as before.
      for (final r in [...rows('exercises'), ...rows('customExercises')]) {
        if (seenExerciseIds.add(r['id'])) sourceExercises.add(r);
      }
      final targetByName = <String, int>{};
      for (final r in await txn.query('exercises', orderBy: 'id')) {
        final id = r['id'];
        if (id is! int) continue;
        targetByName.putIfAbsent(_exerciseKey(r), () => id);
      }
      final exerciseIdMap = <int, int>{};
      for (final r in sourceExercises) {
        final oldId = r['id'];
        if (oldId is! int) continue;
        final key = _exerciseKey(r);
        var newId = targetByName[key];
        if (newId == null) {
          // Not on this device yet: insert without the id so SQLite assigns a
          // fresh one, then remember it for the reference rewrite.
          final row = Map<String, Object?>.from(r)..remove('id');
          newId = await txn.insert('exercises', row);
          targetByName[key] = newId;
        }
        exerciseIdMap[oldId] = newId;
      }
      for (final r in rows('workouts')) {
        await txn.insert('workouts', r,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in rows('workoutExercises')) {
        final row = Map<String, Object?>.from(r);
        final oldId = row['exercise_id'];
        if (oldId is int) {
          final newId = exerciseIdMap[oldId];
          if (newId != null) row['exercise_id'] = newId;
        }
        await txn.insert('workout_exercises', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in rows('workoutSets')) {
        await txn.insert('workout_sets', r,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final key in ['meals', 'accounts', 'moods', 'meditations']) {
        for (final r in rows(key)) {
          await txn.insert(key, r,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      // Accounts must be inserted before their snapshots so the rows stay
      // referentially consistent if foreign keys are ever enforced on
      // balance_snapshots.
      for (final r in rows('balanceSnapshots')) {
        await txn.insert('balance_snapshots', r,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in rows('reminders')) {
        await txn.insert('reminders', r,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in rows('thoughtRecords')) {
        await txn.insert('thought_records', r,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final entry in {
        'healthRecords': 'health_records',
        'healthDaily': 'health_daily',
        'healthSyncState': 'health_sync_state',
      }.entries) {
        for (final r in rows(entry.key)) {
          await txn.insert(entry.value, r,
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
    await store.refreshAll();
    return ((data['workouts'] as List?) ?? []).length;
  }

  /// Identity of an exercise across devices: the name (case-insensitive) plus
  /// whether it is user-created. Ids are device-local and must never be used
  /// to match rows between two installs.
  static String _exerciseKey(Map<String, Object?> row) {
    final name = (row['name'] as String? ?? '').trim().toLowerCase();
    final isCustom = row['is_custom'] == 1 ? 'custom' : 'builtin';
    return '$name|$isCustom';
  }
}
