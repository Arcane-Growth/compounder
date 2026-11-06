import 'package:compounder/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Baseline audit m1: every non-health table was created without indexes, so
/// workout detail, the meal list, the net-worth series and due reminders were
/// full table scans. Schema v8 adds the five indexes; these tests pin both the
/// upgrade path (existing data survives, indexes appear) and the query plans
/// (the scans become index lookups).
const _indexes = <String, String>{
  'idx_workout_sets_exercise': 'workout_sets',
  'idx_workout_exercises_workout': 'workout_exercises',
  'idx_meals_timestamp': 'meals',
  'idx_balance_snapshots_account_taken': 'balance_snapshots',
  'idx_reminders_due_at': 'reminders',
};

/// The hot-path queries from lib/data/store.dart, in the same shape the app
/// issues them.
const _plans = <String, String>{
  'workout_sets by workout_exercise_id':
      'SELECT * FROM workout_sets WHERE workout_exercise_id = 1 ORDER BY position',
  'workout_exercises by workout_id':
      'SELECT * FROM workout_exercises WHERE workout_id = 1 ORDER BY position',
  'meals by timestamp': 'SELECT * FROM meals ORDER BY timestamp DESC',
  'balance_snapshots join': '''
      SELECT s.account_id, s.balance, s.taken_at, a.type
      FROM balance_snapshots s JOIN accounts a ON a.id = s.account_id
      ORDER BY s.taken_at''',
  'reminders due_at':
      'SELECT * FROM reminders WHERE due_at > 0 ORDER BY due_at',
};

Future<String> _plan(Database db, String sql) async {
  final rows = await db.rawQuery('EXPLAIN QUERY PLAN $sql');
  return rows.map((r) => r['detail'] as String).join('\n');
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String path;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    path = '${await databaseFactory.getDatabasesPath()}/'
        'compounder_index_migration_test.db';
    await databaseFactory.deleteDatabase(path);
  });

  tearDown(() async {
    await databaseFactory.deleteDatabase(path);
  });

  test('fresh install creates the five v8 indexes', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 8);

    final rows = await store.db
        .rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'");
    final names = rows.map((r) => r['name'] as String).toSet();
    for (final index in _indexes.keys) {
      expect(names, contains(index), reason: '$index must exist');
    }
    await store.db.close();
  });

  test('upgrade 7 -> 8 keeps every row and adds the indexes', () async {
    final prefs = await SharedPreferences.getInstance();

    // Build a current-schema database, seed one row per affected table, then
    // rewind the version to 7 and drop the v8 indexes so the next open runs the
    // real 7->8 migration against populated tables.
    var store = await AppStore.open(prefs, path: path);
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
      'due_at': 5000,
      'created_at': 4500,
    });

    for (final index in _indexes.keys) {
      await store.db.execute('DROP INDEX IF EXISTS $index');
    }
    await store.db.setVersion(7);
    await store.db.close();

    store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 8);

    // No data loss: the seeded rows are all still there.
    expect(await store.db.query('workouts'), hasLength(1));
    expect(await store.db.query('workout_exercises'), hasLength(1));
    expect(await store.db.query('workout_sets'), hasLength(1));
    expect(await store.db.query('meals'), hasLength(1));
    expect(await store.db.query('accounts'), hasLength(1));
    expect(await store.db.query('balance_snapshots'), hasLength(1));
    expect(await store.db.query('reminders'), hasLength(1));
    final meal = (await store.db.query('meals')).single;
    expect(meal['dish'], 'Oats');
    expect(meal['calories'], 400.0);
    final set = (await store.db.query('workout_sets')).single;
    expect(set['weight_kg'], 100.0);
    expect(set['reps'], 5);

    final rows = await store.db
        .rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'");
    final names = rows.map((r) => r['name'] as String).toSet();
    for (final index in _indexes.keys) {
      expect(names, contains(index), reason: '$index must be added by v8');
    }
    await store.db.close();
  });

  test('the 7 -> 8 step is safe to re-run (IF NOT EXISTS)', () async {
    final prefs = await SharedPreferences.getInstance();
    var store = await AppStore.open(prefs, path: path);
    // Simulate a partially applied migration: version already 8, indexes
    // present, then force the upgrade path again by rewinding the version.
    await store.db.setVersion(7);
    await store.db.close();

    store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 8);
    await store.db.close();
  });

  test('the five hot-path scans become index lookups', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await AppStore.open(prefs, path: path);

    for (final entry in _plans.entries) {
      final plan = await _plan(store.db, entry.value);
      expect(plan, contains('USING INDEX'),
          reason: '${entry.key} must use an index, plan was:\n$plan');
      // A bare `SCAN <table>` is a full table scan. `SCAN <alias> USING INDEX`
      // is an index scan and is fine (the net-worth query has no WHERE clause,
      // so an index scan ordered by taken_at is the best plan available).
      for (final line in plan.split('\n')) {
        if (line.contains('SCAN')) {
          expect(line, contains('USING INDEX'),
              reason: '${entry.key} still full-scans a table: $line');
        }
      }
    }

    // Pin the exact index each plan must pick, so a dropped index fails loudly.
    expect(
        await _plan(store.db, _plans['workout_sets by workout_exercise_id']!),
        contains('idx_workout_sets_exercise'));
    expect(await _plan(store.db, _plans['workout_exercises by workout_id']!),
        contains('idx_workout_exercises_workout'));
    expect(await _plan(store.db, _plans['meals by timestamp']!),
        contains('idx_meals_timestamp'));
    expect(await _plan(store.db, _plans['balance_snapshots join']!),
        contains('idx_balance_snapshots_account_taken'));
    expect(await _plan(store.db, _plans['reminders due_at']!),
        contains('idx_reminders_due_at'));

    await store.db.close();
  });
}
