import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/store.dart';

/// A backup file the app cannot import, with a message safe to show the user.
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);

  @override
  String toString() => message;
}

/// Whole-database backup as one portable JSON file. Export writes a file and
/// hands it to the system share sheet; import replaces all local data.
class BackupService {
  /// Current backup format. 3 adds `balanceSnapshots` and `reminders`; 4 adds
  /// `habits` and `habitCompletions`. An older file simply lacks the newer keys
  /// and still imports (restoring everything it does carry); a newer file is
  /// refused rather than silently truncated.
  static const int format = 4;

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
      'habits': await db.query('habits'),
      'habitCompletions': await db.query('habit_completions'),
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

  /// Replaces all local data with the contents of [path].
  ///
  /// Caller responsibility: rescheduling reminder notifications after an
  /// import is not done here — the caller must call
  /// `notify.rescheduleReminders(store)` once this returns.
  static Future<int> import(AppStore store, String path) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await File(path).readAsString());
    } catch (e) {
      throw const BackupException(
          'That file is not valid JSON — is it a Compounder backup?');
    }
    if (decoded is! Map) {
      throw const BackupException(
          'That file is not a Compounder backup (expected a JSON object).');
    }
    final data = decoded.cast<String, Object?>();
    if (data['app'] != 'compounder') {
      throw const BackupException('Not a Compounder backup file');
    }
    // Format 2 files predate balanceSnapshots/reminders and are still accepted:
    // the missing keys read as empty lists, so the import restores everything
    // the file does carry. A newer format is refused rather than silently
    // dropping fields this build does not understand.
    final fileFormat = data['format'];
    if (fileFormat is int && fileFormat > format) {
      throw BackupException(
          'Backup format $fileFormat is newer than this app supports ($format)');
    }
    final db = store.db;

    /// Reads one table's rows. A key that is present but not a list is a
    /// malformed file, not an empty table: say so instead of letting a raw
    /// `TypeError` reach the UI (audit backup NIT-3).
    List<Map<String, Object?>> rows(String key) {
      final value = data[key];
      if (value == null) return const [];
      if (value is! List) {
        throw BackupException(
            'Backup file is malformed: "$key" should be a list.');
      }
      final out = <Map<String, Object?>>[];
      for (final row in value) {
        if (row is! Map) {
          throw BackupException(
              'Backup file is malformed: "$key" contains a non-object row.');
        }
        out.add(row.cast<String, Object?>());
      }
      return out;
    }

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
        'habit_completions',
        'habits',
        'health_records',
        'health_daily',
        'health_sync_state',
      ]) {
        await txn.delete(table);
      }
      await txn.delete('exercises', where: 'is_custom = 1');

      /// Columns the target schema actually has. A backup written by a newer
      /// build can carry columns this build does not know; inserting them
      /// verbatim makes SQLite reject the statement and roll back the WHOLE
      /// import, so one unknown column would make the file unimportable. The
      /// format-3 promise is that an older build still imports a newer file,
      /// dropping only the fields it cannot represent.
      final tableColumns = <String, Set<String>>{};
      Future<Set<String>> columnsOf(String table) async {
        final cached = tableColumns[table];
        if (cached != null) return cached;
        final info = await txn.rawQuery('PRAGMA table_info($table)');
        final columns = <String>{
          for (final r in info)
            if (r['name'] is String) r['name'] as String,
        };
        tableColumns[table] = columns;
        return columns;
      }

      /// Inserts one file row into `table`, keeping only the columns the target
      /// schema has. `transform` rewrites device-local ids first. Returns the
      /// new row id, or null when nothing was left to insert.
      Future<int?> insertRow(String table, Map<String, Object?> source,
          {Map<String, Object?> Function(Map<String, Object?>)? transform})
          async {
        final columns = await columnsOf(table);
        final row = transform == null
            ? Map<String, Object?>.from(source)
            : transform(source);
        row.removeWhere((key, _) => !columns.contains(key));
        if (row.isEmpty) return null;
        return txn.insert(table, row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // Exercise ids are device-local. The built-in catalog is seeded in a
      // different order on a different install, so a custom exercise's id on
      // the source can collide with a built-in's id on the target. Inserting
      // the file's rows by their original ids would overwrite that built-in
      // and silently repoint every workout entry that referenced it. Resolve
      // exercises by identity instead, let SQLite assign fresh ids, and rewrite
      // the workout references through the resulting map.
      final sourceExercises = <Map<String, Object?>>[];
      final seenExerciseIds = <Object?>{};
      // `exercises` carries the whole catalog (format 3 files written by this
      // build); older files only carry `customExercises`, in which case
      // built-in references keep their original ids as before.
      for (final r in [...rows('exercises'), ...rows('customExercises')]) {
        if (seenExerciseIds.add(r['id'])) sourceExercises.add(r);
      }
      final targetByKey = <String, int>{};
      for (final r in await txn.query('exercises', orderBy: 'id')) {
        final id = r['id'];
        if (id is! int) continue;
        targetByKey.putIfAbsent(_exerciseKey(r), () => id);
      }
      final exerciseIdMap = <int, int>{};
      for (final r in sourceExercises) {
        final oldId = r['id'];
        if (oldId is! int) continue;
        final key = _exerciseKey(r);
        var newId = targetByKey[key];
        if (newId == null) {
          // Not on this device yet: insert without the id so SQLite assigns a
          // fresh one, then remember it for the reference rewrite.
          newId = await insertRow('exercises', r,
              transform: (row) => Map<String, Object?>.from(row)..remove('id'));
          if (newId == null) continue;
          targetByKey[key] = newId;
        }
        exerciseIdMap[oldId] = newId;
      }
      for (final r in rows('workouts')) {
        await insertRow('workouts', r);
      }
      for (final r in rows('workoutExercises')) {
        await insertRow('workout_exercises', r, transform: (row) {
          final copy = Map<String, Object?>.from(row);
          final oldId = copy['exercise_id'];
          if (oldId is int) {
            final newId = exerciseIdMap[oldId];
            if (newId != null) copy['exercise_id'] = newId;
          }
          return copy;
        });
      }
      for (final r in rows('workoutSets')) {
        await insertRow('workout_sets', r);
      }
      for (final key in ['meals', 'accounts', 'moods', 'meditations']) {
        for (final r in rows(key)) {
          await insertRow(key, r);
        }
      }
      // Accounts are inserted before their snapshots so the rows are
      // referentially consistent. `balance_snapshots` currently declares no
      // foreign key, so this ordering is defensive rather than required.
      for (final r in rows('balanceSnapshots')) {
        await insertRow('balance_snapshots', r);
      }
      for (final r in rows('reminders')) {
        await insertRow('reminders', r);
      }
      for (final r in rows('thoughtRecords')) {
        await insertRow('thought_records', r);
      }
      // Habits are inserted before their completions so the rows are
      // referentially consistent under `PRAGMA foreign_keys = ON`. Habit ids
      // are inserted verbatim: every habit row was deleted above, so there is
      // nothing on this device for them to collide with, and the completions
      // keep pointing at the same habit.
      for (final r in rows('habits')) {
        await insertRow('habits', r);
      }
      for (final r in rows('habitCompletions')) {
        await insertRow('habit_completions', r);
      }
      for (final entry in {
        'healthRecords': 'health_records',
        'healthDaily': 'health_daily',
        'healthSyncState': 'health_sync_state',
      }.entries) {
        for (final r in rows(entry.key)) {
          await insertRow(entry.value, r);
        }
      }
    });
    await store.refreshAll();
    // Count from the validated helper, not `data['workouts']`: a non-list
    // value would throw a TypeError here, after the transaction has already
    // committed, and the caller would report a failed import that succeeded
    // (audit backup NIT-1).
    return rows('workouts').length;
  }

  /// Identity of an exercise across devices. Ids are device-local and must
  /// never be used to match rows between two installs.
  ///
  /// Built-ins are matched by name alone: the catalog is unique by name (the
  /// seeder dedupes on it), and a built-in's descriptive columns may change
  /// between app versions — keying on them would duplicate the row on import
  /// instead of reusing the target's catalog entry.
  ///
  /// Custom exercises are matched on name *plus* muscle group and equipment.
  /// `AppStore.createExercise` has no uniqueness constraint, so a user can
  /// create two different "Curl" rows (Dumbbell and Barbell); a name-only key
  /// would collapse them into one row, silently losing the second one's
  /// metadata and repointing its workout entries at the first. Two customs that
  /// agree on all four fields are genuinely indistinguishable, so merging those
  /// is correct.
  static String _exerciseKey(Map<String, Object?> row) {
    final name = (row['name'] as String? ?? '').trim().toLowerCase();
    if (row['is_custom'] != 1) return '$name|builtin';
    final muscleGroup =
        (row['muscle_group'] as String? ?? '').trim().toLowerCase();
    final equipment = (row['equipment'] as String? ?? '').trim().toLowerCase();
    return '$name|custom|$muscleGroup|$equipment';
  }
}
