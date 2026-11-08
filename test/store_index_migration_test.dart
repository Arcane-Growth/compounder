import 'dart:io';

import 'package:compounder/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Baseline audit m1: every non-health table was created without indexes, so
/// workout detail, the meal list, the net-worth series and due reminders were
/// full table scans. Schema v8 adds the five indexes; schema v9 replaces the
/// balance_snapshots shape with one that actually serves the net-worth query.
/// These tests pin the upgrade path (existing data survives, indexes appear)
/// and the query plans (no full scans, and no temp B-tree where the index can
/// satisfy the ORDER BY).

/// Index name -> the table it must be created on. The table is load-bearing:
/// a name-only check would pass an index that was created on the wrong table.
const _indexes = <String, String>{
  'idx_workout_sets_workout_exercise_id': 'workout_sets',
  'idx_workout_exercises_workout': 'workout_exercises',
  'idx_meals_timestamp': 'meals',
  'idx_balance_snapshots_taken': 'balance_snapshots',
  'idx_balance_snapshots_account_taken': 'balance_snapshots',
  'idx_reminders_due_at': 'reminders',
};

/// The v8 index set, as shipped in e84c232: the workout_sets index carried the
/// old name. v8 and v9 have identical tables, so a database with these indexes
/// and `user_version = 8` is exactly what an existing v8 install looks like.
const _v8OnlyIndexes = <String, String>{
  'idx_workout_sets_exercise': 'workout_sets',
  'idx_workout_exercises_workout': 'workout_exercises',
  'idx_meals_timestamp': 'meals',
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
      ORDER BY s.taken_at, s.account_id, s.balance, s.id''',
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

/// The table an index is actually defined on, or null when it does not exist.
Future<String?> _indexTable(Database db, String index) async {
  final rows = await db.rawQuery(
      "SELECT tbl_name FROM sqlite_master WHERE type = 'index' AND name = ?",
      [index]);
  return rows.isEmpty ? null : rows.single['tbl_name'] as String;
}

/// The indexed columns in index order, as reported by SQLite itself.
Future<List<String>> _indexColumns(Database db, String index) async {
  final rows = await db.rawQuery('PRAGMA index_info($index)');
  return rows.map((r) => r['name'] as String).toList();
}

/// Asserts every index in [expected] exists and is defined on the table it is
/// declared for, so a name-only match cannot hide a misplaced index.
Future<void> _expectIndexesOnTables(
    Database db, Map<String, String> expected) async {
  for (final entry in expected.entries) {
    expect(await _indexTable(db, entry.key), entry.value,
        reason: '${entry.key} must be an index on ${entry.value}');
  }
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
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // A unique directory per test: a fixed shared path made concurrent
    // `flutter test` processes collide (one run failed with a UNIQUE
    // constraint while seeding reminders; review test-hygiene item 14).
    tmp = await Directory.systemTemp.createTemp('compounder_index_migration');
    path = p.join(tmp.path, 'index_migration.db');
  });

  tearDown(() async {
    await databaseFactory.deleteDatabase(path);
    await tmp.delete(recursive: true);
  });

  test('fresh install creates the v8/v9 indexes and drops the old name',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 10);

    await _expectIndexesOnTables(store.db, _indexes);
    expect(await _indexTable(store.db, 'idx_workout_sets_exercise'), isNull,
        reason: 'the v8 index name must be gone after the v9 rename');
    expect(await _indexColumns(store.db, 'idx_balance_snapshots_taken'),
        ['taken_at', 'account_id', 'balance'],
        reason: 'the net-worth index must be covering, in this column order');
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
    expect(await store.db.getVersion(), 10);

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

    await _expectIndexesOnTables(store.db, _indexes);
    expect(await _indexTable(store.db, 'idx_workout_sets_exercise'), isNull);
    await store.db.close();
  });

  test('upgrade 8 -> 9 replaces the index shapes on a real v8 database',
      () async {
    final prefs = await SharedPreferences.getInstance();

    // Build a genuine v8 database: the v8 index set (old workout_sets name, no
    // covering balance_snapshots index) with `user_version = 8`. This is the
    // exact state every existing install is in, so this test drives the
    // production `oldVersion == 8` path that the 4->9 and 7->9 tests skip.
    var store = await AppStore.open(prefs, path: path);
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
      'weight_kg': 80.0,
      'reps': 8,
      'completed_at': 1500,
      'is_warmup': 0,
    });
    await store.db.insert('meals', {
      'timestamp': 3000,
      'dish': 'Rice',
      'calories': 500.0,
      'protein': 25.0,
      'carbs': 60.0,
      'fat': 10.0,
    });
    final accountId = await store.db.insert('accounts', {
      'name': 'Savings',
      'type': 'Cash',
      'balance': 2500.0,
      'updated_at': 4000,
    });
    for (var i = 0; i < 3; i++) {
      await store.db.insert('balance_snapshots', {
        'account_id': accountId,
        'balance': 2500.0 + i,
        'taken_at': 4000 + i,
      });
    }
    await store.db.insert('reminders', {
      'text': 'Log weight',
      'due_at': 5000,
      'created_at': 4500,
    });
    await store.db.insert('moods', {
      'timestamp': 6000,
      'mood': 4,
      'note': 'ok',
    });
    await store.db.insert('thought_records', {
      'timestamp': 7000,
      'situation': 's',
      'thought': 't',
      'reframe': 'r',
    });

    // Rewind to the v8 index set.
    await store.db.execute('DROP INDEX IF EXISTS idx_balance_snapshots_taken');
    await store.db
        .execute('DROP INDEX IF EXISTS idx_workout_sets_workout_exercise_id');
    await store.db.execute(
        'CREATE INDEX IF NOT EXISTS idx_workout_sets_exercise ON workout_sets(workout_exercise_id)');
    await store.db.setVersion(8);
    expect(await store.db.getVersion(), 8);

    // The database really is v8-shaped before the upgrade runs.
    await _expectIndexesOnTables(store.db, _v8OnlyIndexes);
    expect(await _indexTable(store.db, 'idx_balance_snapshots_taken'), isNull,
        reason: 'a v8 database has no covering balance_snapshots index');
    await store.db.close();

    store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 10);

    // The v9 step must have replaced both index shapes.
    expect(await _indexTable(store.db, 'idx_balance_snapshots_taken'),
        'balance_snapshots',
        reason: 'v9 must add the covering balance_snapshots index');
    expect(await _indexColumns(store.db, 'idx_balance_snapshots_taken'),
        ['taken_at', 'account_id', 'balance'],
        reason: 'the net-worth index must be covering, in this column order');
    expect(await _indexTable(store.db, 'idx_workout_sets_exercise'), isNull,
        reason: 'v9 must drop the v8 workout_sets index name');
    expect(await _indexTable(store.db, 'idx_workout_sets_workout_exercise_id'),
        'workout_sets',
        reason: 'v9 must create the renamed workout_sets index');
    // The v8 indexes that v9 does not touch must survive the upgrade.
    await _expectIndexesOnTables(store.db, {
      for (final entry in _v8OnlyIndexes.entries)
        if (entry.key != 'idx_workout_sets_exercise') entry.key: entry.value,
    });

    // No data loss: every seeded row is still there, with its values intact.
    expect(await store.db.query('workouts'), hasLength(1));
    expect(await store.db.query('workout_exercises'), hasLength(1));
    expect(await store.db.query('workout_sets'), hasLength(1));
    expect(await store.db.query('meals'), hasLength(1));
    expect(await store.db.query('accounts'), hasLength(1));
    expect(await store.db.query('balance_snapshots'), hasLength(3));
    expect(await store.db.query('reminders'), hasLength(1));
    expect(await store.db.query('moods'), hasLength(1));
    expect(await store.db.query('thought_records'), hasLength(1));
    final set = (await store.db.query('workout_sets')).single;
    expect(set['weight_kg'], 80.0);
    expect(set['reps'], 8);
    final snapshots =
        await store.db.query('balance_snapshots', orderBy: 'taken_at');
    expect(
        snapshots.map((r) => r['balance']).toList(), [2500.0, 2501.0, 2502.0]);
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
    expect(await store.db.getVersion(), 10);
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
    // The net-worth query has no account_id predicate, so the only plan that
    // avoids a temp B-tree is a *covering* scan of the taken_at-leading index.
    // Pinning the name alone accepts a non-covering
    // `CREATE INDEX ... ON balance_snapshots(taken_at)`, which still sorts.
    final netWorthPlan =
        await _plan(store.db, _plans['balance_snapshots join']!.sql);
    expect(netWorthPlan,
        contains('USING COVERING INDEX idx_balance_snapshots_taken'),
        reason:
            'the net-worth index must be covering, plan was:\n$netWorthPlan');
    expect(await _indexColumns(store.db, 'idx_balance_snapshots_taken'),
        ['taken_at', 'account_id', 'balance'],
        reason: 'the net-worth index must cover exactly the queried columns');
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
