import 'package:compounder/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Baseline audit m1: every non-health table was created without indexes, so
/// workout detail, the meal list, the net-worth series and due reminders were
/// full table scans. Schema v8 adds the five indexes; schema v9 replaces the
/// balance_snapshots shape with one that actually serves the net-worth query.
/// These tests pin the upgrade path (existing data survives, indexes appear)
/// and the query plans (no full scans, and no temp B-tree where the index can
/// satisfy the ORDER BY).
const _indexes = <String, String>{
  'idx_workout_sets_workout_exercise_id': 'workout_sets',
  'idx_workout_exercises_workout': 'workout_exercises',
  'idx_meals_timestamp': 'meals',
  'idx_balance_snapshots_taken': 'balance_snapshots',
  'idx_balance_snapshots_account_taken': 'balance_snapshots',
  'idx_reminders_due_at': 'reminders',
};

/// The hot-path queries from lib/data/store.dart, in the same shape the app
/// issues them. `avoidsTempBTree` is true only where the shipped index can
/// satisfy the ORDER BY; workout_sets/workout_exercises still sort, because
/// their indexes do not carry `position`.
const _plans = <String, ({String sql, bool avoidsTempBTree})>{
  'workout_sets by workout_exercise_id': (
    sql: 'SELECT * FROM workout_sets WHERE workout_exercise_id = 1 '
        'ORDER BY position',
    avoidsTempBTree: false,
  ),
  'workout_exercises by workout_id': (
    sql: 'SELECT * FROM workout_exercises WHERE workout_id = 1 '
        'ORDER BY position',
    avoidsTempBTree: false,
  ),
  'meals by timestamp': (
    sql: 'SELECT * FROM meals ORDER BY timestamp DESC',
    avoidsTempBTree: true,
  ),
  'balance_snapshots join': (
    sql: '''
      SELECT s.account_id, s.balance, s.taken_at, a.type
      FROM balance_snapshots s JOIN accounts a ON a.id = s.account_id
      ORDER BY s.taken_at''',
    avoidsTempBTree: true,
  ),
  'reminders due_at': (
    sql: 'SELECT * FROM reminders WHERE due_at > 0 ORDER BY due_at',
    avoidsTempBTree: true,
  ),
};

Future<String> _plan(Database db, String sql) async {
  final rows = await db.rawQuery('EXPLAIN QUERY PLAN $sql');
  return rows.map((r) => r['detail'] as String).join('\n');
}

/// True when [line] names an index, covering or otherwise. A covering index
/// scan is the best plan available for the net-worth query, so it must count.
bool _usesIndex(String line) =>
    line.contains('USING INDEX') || line.contains('USING COVERING INDEX');

/// Seeds enough rows that the planner has realistic cardinalities to work
/// with. Plans on an empty table are identical to plans on a populated one for
/// these queries, but seeding keeps the test honest if that ever changes.
Future<void> _seedHotPathTables(Database db) async {
  for (var i = 0; i < 300; i++) {
    await db.insert('workouts', {
      'name': 'w$i',
      'started_at': i * 1000,
      'ended_at': i * 1000 + 500,
    });
    await db.insert('workout_exercises', {
      'workout_id': (i % 300) + 1,
      'exercise_id': (i % 20) + 1,
      'position': i % 5,
    });
    await db.insert('workout_sets', {
      'workout_exercise_id': (i % 300) + 1,
      'position': i % 5,
      'weight_kg': 50.0 + i,
      'reps': 5 + (i % 10),
      'completed_at': i * 1000,
      'is_warmup': 0,
    });
    await db.insert('meals', {
      'timestamp': i * 60000,
      'dish': 'd$i',
      'calories': 400.0,
      'protein': 20.0,
      'carbs': 50.0,
      'fat': 8.0,
    });
    await db.insert('reminders', {
      'text': 'r$i',
      'due_at': i * 60000,
      'created_at': i * 1000,
    });
  }
  for (var i = 0; i < 40; i++) {
    await db.insert('accounts', {
      'name': 'a$i',
      'type': i % 5 == 0 ? 'Debt' : 'Cash',
      'balance': 1000.0 * i,
      'updated_at': i * 1000,
    });
  }
  for (var i = 0; i < 300; i++) {
    await db.insert('balance_snapshots', {
      'account_id': (i % 40) + 1,
      'balance': 1000.0 * (i % 40),
      'taken_at': i * 60000,
    });
  }
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

  test('fresh install creates the v8/v9 indexes and drops the old name',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 9);

    final rows = await store.db
        .rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'");
    final names = rows.map((r) => r['name'] as String).toSet();
    for (final index in _indexes.keys) {
      expect(names, contains(index), reason: '$index must exist');
    }
    expect(names, isNot(contains('idx_workout_sets_exercise')),
        reason: 'the v8 index name must be gone after the v9 rename');
    await store.db.close();
  });

  test('upgrade 4 -> 9 keeps every row, purges stale sleep data, adds indexes',
      () async {
    final prefs = await SharedPreferences.getInstance();

    // Build a current-schema database, seed rows, then rewind the version to 4
    // and drop the indexes so the next open runs the real 4->9 migration
    // against populated tables. Rewinding to 4 (not 7) is deliberate: the
    // v5/v6/v7 steps are the only destructive part of _upgradeSchema, and they
    // are skipped entirely if the version is already 7.
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

    // Health rows: the v5/v6/v7 steps are the only destructive part of
    // _upgradeSchema, so seed both sleep and non-sleep data to prove the purge
    // is scoped correctly.
    for (final row in [
      ('uuid-steps-1', 'STEPS', 1000),
      ('uuid-steps-2', 'STEPS', 2000),
      ('uuid-hr-1', 'HEART_RATE', 3000),
      ('uuid-sleep-1', 'SLEEP_SESSION', 4000),
      ('uuid-sleep-2', 'SLEEP_DEEP', 4100),
      ('uuid-sleep-3', 'SLEEP_REM', 4200),
    ]) {
      await store.db.insert('health_records', {
        'uuid': row.$1,
        'type': row.$2,
        'value': 1.0,
        'date_from': row.$3,
        'date_to': row.$3 + 100,
        'synced_at': 9000,
      });
    }
    for (final metric in ['__all__', 'STEPS', 'HEART_RATE', 'SLEEP_SESSION']) {
      await store.db.insert('health_sync_state', {
        'metric': metric,
        'last_synced_at': 9000,
        'last_success_at': 9000,
      });
    }

    for (final index in _indexes.keys) {
      await store.db.execute('DROP INDEX IF EXISTS $index');
    }
    await store.db.execute('DROP INDEX IF EXISTS idx_workout_sets_exercise');
    await store.db.setVersion(4);
    await store.db.close();

    store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 9);

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

    // The destructive steps must purge sleep rows only.
    final sleepRows =
        await store.db.query('health_records', where: "type LIKE 'SLEEP%'");
    expect(sleepRows, isEmpty, reason: 'stale sleep rows must be purged');
    final surviving = await store.db.query('health_records');
    expect(surviving, hasLength(3),
        reason: 'STEPS and HEART_RATE rows must survive the upgrade');
    expect(surviving.map((r) => r['type']).toSet(), {'STEPS', 'HEART_RATE'});
    expect(surviving.map((r) => r['uuid']).toSet(),
        {'uuid-steps-1', 'uuid-steps-2', 'uuid-hr-1'});

    // The aggregate and sleep stamps must clear so the next sync re-fetches;
    // the non-sleep stamps must survive.
    final stamps = await store.db.query('health_sync_state');
    expect(stamps.map((r) => r['metric']).toSet(), {'STEPS', 'HEART_RATE'});

    final rows = await store.db
        .rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'");
    final names = rows.map((r) => r['name'] as String).toSet();
    for (final index in _indexes.keys) {
      expect(names, contains(index), reason: '$index must be added by v8/v9');
    }
    expect(names, isNot(contains('idx_workout_sets_exercise')));
    await store.db.close();
  });

  test('the 7 -> 9 step is safe to re-run (IF NOT EXISTS)', () async {
    final prefs = await SharedPreferences.getInstance();
    var store = await AppStore.open(prefs, path: path);
    // Simulate a partially applied migration: version already 9, indexes
    // present, then force the upgrade path again by rewinding the version.
    await store.db.setVersion(7);
    await store.db.close();

    store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 9);
    await store.db.close();
  });

  test('the hot-path scans become index lookups with no temp B-tree', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await AppStore.open(prefs, path: path);
    await _seedHotPathTables(store.db);

    for (final entry in _plans.entries) {
      final plan = await _plan(store.db, entry.value.sql);
      expect(_usesIndex(plan), isTrue,
          reason: '${entry.key} must use an index, plan was:\n$plan');
      // A bare `SCAN <table>` is a full table scan. `SCAN <alias> USING INDEX`
      // or `USING COVERING INDEX` is an index scan and is fine (the net-worth
      // query has no WHERE clause, so an index scan ordered by taken_at is the
      // best plan available).
      for (final line in plan.split('\n')) {
        if (line.contains('SCAN')) {
          expect(_usesIndex(line), isTrue,
              reason: '${entry.key} still full-scans a table: $line');
        }
      }
      if (entry.value.avoidsTempBTree) {
        // The audit's m1 goal was to remove the temp B-tree, not merely to
        // swap SCAN for an index scan. Asserting only `USING INDEX` accepts
        // `SCAN ... USING INDEX` + `USE TEMP B-TREE FOR ORDER BY`, which is
        // exactly the defect this test must catch.
        expect(plan, isNot(contains('TEMP B-TREE FOR ORDER BY')),
            reason: '${entry.key} still sorts in a temp B-tree, plan was:\n'
                '$plan');
      }
    }

    // Pin the exact index each plan must pick, so a dropped index fails loudly.
    expect(
        await _plan(
            store.db, _plans['workout_sets by workout_exercise_id']!.sql),
        contains('idx_workout_sets_workout_exercise_id'));
    expect(
        await _plan(store.db, _plans['workout_exercises by workout_id']!.sql),
        contains('idx_workout_exercises_workout'));
    expect(await _plan(store.db, _plans['meals by timestamp']!.sql),
        contains('idx_meals_timestamp'));
    expect(await _plan(store.db, _plans['balance_snapshots join']!.sql),
        contains('idx_balance_snapshots_taken'));
    expect(await _plan(store.db, _plans['reminders due_at']!.sql),
        contains('idx_reminders_due_at'));

    // deleteAccount filters on account_id alone; the account_id-leading index
    // must keep that a seek rather than a full scan.
    expect(
        await _plan(
            store.db, 'DELETE FROM balance_snapshots WHERE account_id = 7'),
        contains('idx_balance_snapshots_account_taken'));

    await store.db.close();
  });
}
