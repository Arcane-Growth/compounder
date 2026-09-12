import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/store.dart';

/// Whole-database backup as one portable JSON file. Export writes a file and
/// hands it to the system share sheet; import replaces all local data.
class BackupService {
  static Future<String> export(AppStore store) async {
    final db = store.db;
    final data = {
      'format': 1,
      'app': 'compounder',
      'exportedAt': DateTime.now().toIso8601String(),
      'workouts': await db.query('workouts'),
      'workoutExercises': await db.query('workout_exercises'),
      'workoutSets': await db.query('workout_sets'),
      'customExercises': await db.query('exercises', where: 'is_custom = 1'),
      'meals': await db.query('meals'),
      'accounts': await db.query('accounts'),
      'moods': await db.query('moods'),
      'meditations': await db.query('meditations'),
      'thoughtRecords': await db.query('thought_records'),
    };
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'compounder-backup-${DateTime.now().millisecondsSinceEpoch}.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return file.path;
  }

  static Future<int> import(AppStore store, String path) async {
    final data = jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    if (data['app'] != 'compounder') throw Exception('Not a Compounder backup file');
    final db = store.db;

    List<Map<String, Object?>> rows(String key) =>
        ((data[key] as List?) ?? []).cast<Map<String, Object?>>();

    await db.transaction((txn) async {
      for (final table in [
        'workout_sets', 'workout_exercises', 'workouts',
        'meals', 'accounts', 'moods', 'meditations', 'thought_records',
      ]) {
        await txn.delete(table);
      }
      await txn.delete('exercises', where: 'is_custom = 1');
      for (final r in rows('customExercises')) {
        await txn.insert('exercises', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in rows('workouts')) {
        await txn.insert('workouts', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in rows('workoutExercises')) {
        await txn.insert('workout_exercises', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in rows('workoutSets')) {
        await txn.insert('workout_sets', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final key in ['meals', 'accounts', 'moods', 'meditations']) {
        for (final r in rows(key)) {
          await txn.insert(key, r, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      for (final r in rows('thoughtRecords')) {
        await txn.insert('thought_records', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    await store.refreshAll();
    return ((data['workouts'] as List?) ?? []).length;
  }
}
