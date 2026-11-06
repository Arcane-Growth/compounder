import 'package:compounder/data/store.dart';
import 'package:compounder/health/analysis.dart';
import 'package:compounder/health/models.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// health-13.3.1 stamps every sleep stage of a night with the parent
/// SleepSessionRecord's metadata id, so all points of one night arrive with the
/// same uuid. This is the shape the Pixel 10 logcat showed for uuid
/// e9e18ce9-279d-352f-b82d-7b01eafa65a4: session 390 min, deep 81, light 199,
/// rem 101, awake 9.
const String _parentUuid = 'e9e18ce9-279d-352f-b82d-7b01eafa65a4';

DateTime _at(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 1, day, hour, minute);

HealthDataPoint _point(
  HealthDataType type,
  DateTime from,
  DateTime to, {
  String uuid = _parentUuid,
}) =>
    HealthDataPoint(
      uuid: uuid,
      // health-13.3.1 converts stage types to minutes but leaves SLEEP_SESSION
      // alone, so supply the interval length for every point here.
      value: NumericHealthValue(
          numericValue: to.difference(from).inMinutes.toDouble()),
      type: type,
      unit: HealthDataUnit.MINUTE,
      dateFrom: from,
      dateTo: to,
      sourcePlatform: HealthPlatformType.googleHealthConnect,
      sourceDeviceId: 'device',
      sourceId: 'com.google.android.apps.healthdata',
      sourceName: 'Health Connect',
    );

/// A fully staged night: 8h session, deep 60 + light 240 + rem 90 = 390 asleep,
/// awake 90. Every point carries the same parent uuid, exactly as the plugin
/// delivers it.
List<HealthDataPoint> _stagedNightPoints() => [
      _point(HealthDataType.SLEEP_SESSION, _at(1, 23), _at(2, 7)),
      _point(HealthDataType.SLEEP_DEEP, _at(1, 23), _at(2, 0)),
      _point(HealthDataType.SLEEP_LIGHT, _at(2, 0), _at(2, 4)),
      _point(HealthDataType.SLEEP_REM, _at(2, 4), _at(2, 5, 30)),
      _point(HealthDataType.SLEEP_AWAKE, _at(2, 5, 30), _at(2, 7)),
    ];

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final syncedAt = DateTime(2026, 1, 2, 9);

  group('sleep record uuid', () {
    test('stages of one night get distinct, deterministic uuids', () {
      final records =
          _stagedNightPoints().map((p) => healthRecordFromPoint(p, syncedAt));
      final uuids = records.map((r) => r.uuid).toList();
      expect(uuids.toSet(), hasLength(5),
          reason: 'every stage must key separately');
      // Deterministic: the same point maps to the same uuid, so a re-sync
      // replaces the row instead of duplicating it.
      final again = _stagedNightPoints()
          .map((p) => healthRecordFromPoint(p, syncedAt.add(
              const Duration(hours: 1))))
          .map((r) => r.uuid);
      expect(again.toList(), uuids);
      // The parent uuid is still recoverable from the composite key.
      for (final uuid in uuids) {
        expect(uuid, startsWith(_parentUuid));
      }
    });

    test('non-sleep records keep the plugin uuid untouched', () {
      final p = _point(HealthDataType.HEART_RATE, _at(2, 9), _at(2, 9, 1),
          uuid: 'hr-uuid');
      expect(healthRecordFromPoint(p, syncedAt).uuid, 'hr-uuid');
    });
  });

  group('sleep persistence', () {
    late Database db;
    late HealthRepository repo;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('''CREATE TABLE health_records(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL,
        value REAL,
        unit TEXT NOT NULL DEFAULT '',
        date_from INTEGER NOT NULL,
        date_to INTEGER NOT NULL,
        source_id TEXT NOT NULL DEFAULT '',
        source_name TEXT NOT NULL DEFAULT '',
        platform TEXT NOT NULL DEFAULT '',
        recording_method INTEGER NOT NULL DEFAULT 0,
        raw_json TEXT NOT NULL DEFAULT '',
        synced_at INTEGER NOT NULL)''');
      repo = HealthRepository(db);
    });

    tearDown(() async => db.close());

    test('a staged night persists as separate rows for every stage', () async {
      final records = _stagedNightPoints()
          .map((p) => healthRecordFromPoint(p, syncedAt))
          .toList();
      await repo.upsertRecords(records);

      final stored = await repo.records(
        from: _at(1, 0).millisecondsSinceEpoch,
        to: _at(3, 0).millisecondsSinceEpoch,
      );
      final byType = <String, List<HealthRecord>>{};
      for (final r in stored) {
        byType.putIfAbsent(r.type, () => []).add(r);
      }
      expect(stored, hasLength(5));
      for (final type in const [
        'SLEEP_SESSION',
        'SLEEP_DEEP',
        'SLEEP_LIGHT',
        'SLEEP_REM',
        'SLEEP_AWAKE',
      ]) {
        expect(byType[type], hasLength(1), reason: '$type must survive');
      }
      // The session row is what the analysis needs to know the night's real
      // length; before the fix it was always overwritten by a stage.
      expect(byType['SLEEP_SESSION']!.single.value, 480);
    });

    test('re-syncing the same night replaces rows instead of duplicating',
        () async {
      final first = _stagedNightPoints()
          .map((p) => healthRecordFromPoint(p, syncedAt))
          .toList();
      await repo.upsertRecords(first);
      final second = _stagedNightPoints()
          .map((p) => healthRecordFromPoint(
              p, syncedAt.add(const Duration(hours: 2))))
          .toList();
      await repo.upsertRecords(second);
      final stored = await repo.records(
        from: _at(1, 0).millisecondsSinceEpoch,
        to: _at(3, 0).millisecondsSinceEpoch,
      );
      expect(stored, hasLength(5));
      expect(stored.map((r) => r.uuid).toSet(), hasLength(5));
    });

    test('the persisted night aggregates to the real asleep total', () async {
      final records = _stagedNightPoints()
          .map((p) => healthRecordFromPoint(p, syncedAt))
          .toList();
      await repo.upsertRecords(records);

      final stored = await repo.records(
        from: _at(1, 0).millisecondsSinceEpoch,
        to: _at(3, 0).millisecondsSinceEpoch,
      );
      final sessions = buildSleepSessions(sleepSegmentsFromRecords(stored));
      expect(sessions, hasLength(1));
      final night = sessions.single;
      // deep 60 + light 240 + rem 90 = 390 minutes asleep, not the 90 minutes
      // of the last surviving stage and not the 7 minutes the user saw.
      expect(night.asleepMinutes, 390);
      expect(night.awakeMinutes, 90);
      expect(night.inBedMinutes, 480);
      expect(night.stages['SLEEP_DEEP'], 60);
      expect(night.stages['SLEEP_LIGHT'], 240);
      expect(night.stages['SLEEP_REM'], 90);
    });

    test('a single surviving stage would have reported only its own minutes',
        () async {
      // Guard against a regression that silently drops stages again: with the
      // pre-fix behaviour only the last stage of the night would be stored, so
      // the night could never report more than one stage's minutes.
      final records = _stagedNightPoints()
          .map((p) => healthRecordFromPoint(p, syncedAt))
          .toList();
      await repo.upsertRecords(records);
      final stored = await repo.records(
        from: _at(1, 0).millisecondsSinceEpoch,
        to: _at(3, 0).millisecondsSinceEpoch,
      );
      final sessions = buildSleepSessions(sleepSegmentsFromRecords(stored));
      expect(sessions.single.asleepMinutes, greaterThan(90),
          reason: 'the night must exceed any single stage length');
    });
  });

  group('schema upgrade 4 -> 5', () {
    test('purges stale SLEEP_* rows and sleep sync state, keeps other data',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final path = '${await databaseFactory.getDatabasesPath()}/'
          'compounder_migration_test.db';
      await databaseFactory.deleteDatabase(path);

      // Build a v5 database, then rewind it to v4 and plant the stale rows the
      // buggy sync produced: one surviving sleep row per night plus a sleep
      // sync stamp, alongside data that must survive the migration.
      var store = await AppStore.open(prefs, path: path);
      await store.db.delete('health_records');
      await store.db.delete('health_sync_state');
      await store.db.insert('health_records', {
        'uuid': _parentUuid,
        'type': 'SLEEP_REM',
        'value': 7.0,
        'unit': 'MINUTE',
        'date_from': _at(2, 6, 19).millisecondsSinceEpoch,
        'date_to': _at(2, 6, 26).millisecondsSinceEpoch,
        'synced_at': syncedAt.millisecondsSinceEpoch,
      });
      await store.db.insert('health_records', {
        'uuid': 'hr-1',
        'type': 'HEART_RATE',
        'value': 61.0,
        'unit': 'BEATS_PER_MINUTE',
        'date_from': _at(2, 9).millisecondsSinceEpoch,
        'date_to': _at(2, 9, 1).millisecondsSinceEpoch,
        'synced_at': syncedAt.millisecondsSinceEpoch,
      });
      await store.db.insert('health_sync_state', {
        'metric': 'SLEEP_REM',
        'last_synced_at': syncedAt.millisecondsSinceEpoch,
        'last_success_at': syncedAt.millisecondsSinceEpoch,
      });
      await store.db.insert('health_sync_state', {
        'metric': 'HEART_RATE',
        'last_synced_at': syncedAt.millisecondsSinceEpoch,
        'last_success_at': syncedAt.millisecondsSinceEpoch,
      });
      await store.db.setVersion(4);
      await store.db.close();

      store = await AppStore.open(prefs, path: path);
      final sleepRows = await store.db
          .query('health_records', where: "type LIKE 'SLEEP%'");
      expect(sleepRows, isEmpty, reason: 'stale sleep rows must be purged');
      final heartRows = await store.db
          .query('health_records', where: "type = 'HEART_RATE'");
      expect(heartRows, hasLength(1), reason: 'other metrics must survive');
      final sleepState = await store.db
          .query('health_sync_state', where: "metric LIKE 'SLEEP%'");
      expect(sleepState, isEmpty,
          reason: 'sleep stamps must clear so the next sync re-fetches');
      final heartState = await store.db
          .query('health_sync_state', where: "metric = 'HEART_RATE'");
      expect(heartState, hasLength(1));
      expect(await store.db.getVersion(), 7);
      await store.db.close();
      await databaseFactory.deleteDatabase(path);
    });
  });

  group('schema upgrade 5 -> 7', () {
    test('clears the __all__ and sleep stamps so the next sync re-fetches',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final path = '${await databaseFactory.getDatabasesPath()}/'
          'compounder_migration_v7_test.db';
      await databaseFactory.deleteDatabase(path);

      // Build a current-schema database, then rewind it to v5 and plant the
      // exact state the 4->5 migration left on the Pixel 10: the sleep rows it
      // purged are gone, one night has been re-synced since, and the aggregate
      // `__all__` stamp survived so the window stayed narrow.
      var store = await AppStore.open(prefs, path: path);
      await store.db.delete('health_records');
      await store.db.delete('health_sync_state');

      final night = _stagedNightPoints()
          .map((p) => healthRecordFromPoint(p, syncedAt))
          .toList();
      for (final r in night) {
        await store.db.insert('health_records', r.toMap());
      }
      await store.db.insert('health_records', {
        'uuid': 'hr-1',
        'type': 'HEART_RATE',
        'value': 61.0,
        'unit': 'BEATS_PER_MINUTE',
        'date_from': _at(2, 9).millisecondsSinceEpoch,
        'date_to': _at(2, 9, 1).millisecondsSinceEpoch,
        'synced_at': syncedAt.millisecondsSinceEpoch,
      });
      await store.db.insert('health_records', {
        'uuid': 'steps-1',
        'type': 'STEPS',
        'value': 4200.0,
        'unit': 'COUNT',
        'date_from': _at(2, 0).millisecondsSinceEpoch,
        'date_to': _at(3, 0).millisecondsSinceEpoch,
        'synced_at': syncedAt.millisecondsSinceEpoch,
      });

      final stamp = syncedAt.millisecondsSinceEpoch;
      for (final metric in const [
        '__all__',
        'SLEEP_SESSION',
        'SLEEP_DEEP',
        'HEART_RATE',
        'STEPS',
      ]) {
        await store.db.insert('health_sync_state', {
          'metric': metric,
          'last_synced_at': stamp,
          'last_success_at': stamp,
        });
      }
      await store.db.setVersion(5);
      await store.db.close();

      store = await AppStore.open(prefs, path: path);
      expect(await store.db.getVersion(), 7);

      final allRows = await store.db.query('health_sync_state',
          where: "metric = '__all__'");
      expect(allRows, isEmpty,
          reason: 'the aggregate stamp must clear so lastSync() returns null');
      expect(await HealthRepository(store.db).lastSync(), isNull,
          reason: 'a null lastSync() is what widens the next sync window');

      // runChunkedSync resumes from per-metric stamps too, so the SLEEP_* ones
      // must clear as well or the sleep window stays narrow.
      final sleepState = await store.db
          .query('health_sync_state', where: "metric LIKE 'SLEEP%'");
      expect(sleepState, isEmpty,
          reason: 'sleep stamps must clear so the sleep window widens');

      // Every other metric keeps its stamp, values untouched.
      for (final metric in const ['HEART_RATE', 'STEPS']) {
        final rows = await store.db.query('health_sync_state',
            where: 'metric = ?', whereArgs: [metric]);
        expect(rows, hasLength(1), reason: '$metric stamp must survive');
        expect(rows.single['last_success_at'], stamp);
        expect(rows.single['last_synced_at'], stamp);
      }

      // The 5->7 steps are additive: they must not purge anything.
      final sleepRows = await store.db
          .query('health_records', where: "type LIKE 'SLEEP%'");
      expect(sleepRows, hasLength(5),
          reason: 'the surviving sleep night must not be purged again');
      final otherRows = await store.db.query('health_records',
          where: "type IN ('HEART_RATE', 'STEPS')");
      expect(otherRows, hasLength(2),
          reason: 'non-sleep health rows must survive');

      await store.db.close();
      await databaseFactory.deleteDatabase(path);
    });
  });

  group('schema upgrade 6 -> 7', () {
    test('a device already on 6 loses the re-created sleep stamps', () async {
      // The Pixel 10 reached schema 6 with the 5->6 step applied, then the
      // launch sync re-stamped `__all__` and every SLEEP_* metric at the recent
      // end of the window. The 6->7 step must clear those again.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final path = '${await databaseFactory.getDatabasesPath()}/'
          'compounder_migration_v6_to_v7_test.db';
      await databaseFactory.deleteDatabase(path);

      var store = await AppStore.open(prefs, path: path);
      await store.db.delete('health_records');
      await store.db.delete('health_sync_state');

      final night = _stagedNightPoints()
          .map((p) => healthRecordFromPoint(p, syncedAt))
          .toList();
      for (final r in night) {
        await store.db.insert('health_records', r.toMap());
      }
      await store.db.insert('health_records', {
        'uuid': 'hr-1',
        'type': 'HEART_RATE',
        'value': 61.0,
        'unit': 'BEATS_PER_MINUTE',
        'date_from': _at(2, 9).millisecondsSinceEpoch,
        'date_to': _at(2, 9, 1).millisecondsSinceEpoch,
        'synced_at': syncedAt.millisecondsSinceEpoch,
      });

      final stamp = syncedAt.millisecondsSinceEpoch;
      for (final metric in const [
        '__all__',
        'SLEEP_SESSION',
        'SLEEP_REM',
        'HEART_RATE',
      ]) {
        await store.db.insert('health_sync_state', {
          'metric': metric,
          'last_synced_at': stamp,
          'last_success_at': stamp,
        });
      }
      await store.db.setVersion(6);
      await store.db.close();

      store = await AppStore.open(prefs, path: path);
      expect(await store.db.getVersion(), 7);
      expect(
          await store.db
              .query('health_sync_state', where: "metric = '__all__'"),
          isEmpty);
      expect(
          await store.db
              .query('health_sync_state', where: "metric LIKE 'SLEEP%'"),
          isEmpty);
      final heartState = await store.db.query('health_sync_state',
          where: "metric = 'HEART_RATE'");
      expect(heartState, hasLength(1));
      expect(heartState.single['last_success_at'], stamp);
      expect(
          await store.db
              .query('health_records', where: "type LIKE 'SLEEP%'"),
          hasLength(5));
      expect(
          await store.db
              .query('health_records', where: "type = 'HEART_RATE'"),
          hasLength(1));

      await store.db.close();
      await databaseFactory.deleteDatabase(path);
    });
  });
}
