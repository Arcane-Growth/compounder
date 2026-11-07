import 'package:compounder/data/store.dart';
import 'package:compounder/services/notify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// End-to-end guards for the digest (notify.dart) across DST boundaries.
///
/// Two defects are pinned here, both through the real
/// [NotifyService.buildDigest] and a real [AppStore]:
///
/// 1. MINOR-1 from the M3 gate: "You have not lifted in N days" used
///    `difference().inDays`, i.e. elapsed hours truncated to days. Across a
///    spring-forward a 7-calendar-day gap is 166 hours, which truncates to 6.
///    (A fall-back gap cannot under-report — elapsed time is longer than the
///    calendar span — so the discriminating case is spring-forward only.)
/// 2. The 7-day window start must be local midnight six calendar days back, not
///    midnight minus 144 hours, which lands on 23:00/01:00.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() {
    // Precondition, not a test: every assertion below builds ambient-zone
    // DateTimes, so without a real transition in the process zone the
    // Duration-based pre-fix implementation passes too. Proved: reverting
    // digestWindowStart to the Duration form and running this file under
    // TZ=UTC gave "+4: All tests passed!" — a green pass on broken code
    // (audit m3-dst MINOR-1).
    expect(DateTime(2026, 3, 8, 1).timeZoneOffset,
        isNot(DateTime(2026, 3, 8, 4).timeZoneOffset),
        reason: 'ambient zone has no 2026-03-08 DST transition; '
            'run with TZ=America/New_York');
    expect(DateTime(2026, 11, 1, 0).timeZoneOffset,
        isNot(DateTime(2026, 11, 1, 12).timeZoneOffset),
        reason: 'ambient zone has no 2026-11-01 DST transition; '
            'run with TZ=America/New_York');
  });

  late String dbPath;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final base = await databaseFactory.getDatabasesPath();
    dbPath = p.join(base, 'compounder_digest_dst_test.db');
    await databaseFactory.deleteDatabase(dbPath);
  });

  tearDown(() async {
    await databaseFactory.deleteDatabase(dbPath);
  });

  Future<AppStore> storeWithWorkoutAt(int startedAt) async {
    final prefs = await SharedPreferences.getInstance();
    final store = await AppStore.open(prefs, path: dbPath);
    await store.db.insert('workouts', {
      'name': 'Leg day',
      'started_at': startedAt,
      'ended_at': startedAt + 3600000,
    });
    await store.refreshAll();
    return store;
  }

  test('digest reports 7 days, not 6, across the spring-forward boundary',
      () async {
    // 2026-03-04 01:30 -> 2026-03-11 00:30 is 7 calendar days but only 166
    // elapsed hours, so the pre-fix `difference().inDays` reported 6.
    final workout = DateTime(2026, 3, 4, 1, 30);
    final now = DateTime(2026, 3, 11, 0, 30);
    expect(now.difference(workout).inDays, 6,
        reason: 'pre-fix elapsed-hours truncation under-reports by a day');

    final store = await storeWithWorkoutAt(workout.millisecondsSinceEpoch);
    final digest = NotifyService.buildDigest(store, now: now);
    expect(digest, contains('You have not lifted in 7 days'),
        reason: 'digest must count calendar days across a DST boundary');
    expect(digest, isNot(contains('in 6 days')));
  });

  test('the 7-day window start is local midnight, not 144 hours back',
      () async {
    // Anchor 2026-11-04: the calendar window starts 2026-10-29 00:00. The
    // pre-fix Duration form started 2026-10-29 01:00, so a workout at 00:30 was
    // silently dropped from the digest.
    final now = DateTime(2026, 11, 4, 0, 30);
    final workout = DateTime(2026, 10, 29, 0, 30);
    final store = await storeWithWorkoutAt(workout.millisecondsSinceEpoch);
    final digest = NotifyService.buildDigest(store, now: now);
    expect(digest, contains('1 workout this week'),
        reason: 'a workout at 00:30 on the window start day must be counted');
    expect(digest, isNot(contains('You have not lifted')));
  });

  test('the same window start holds on the spring-forward side', () async {
    // Anchor 2026-03-09: the calendar window starts 2026-03-03 00:00. The
    // pre-fix Duration form started 2026-03-02 23:00, so a workout at 2026-03-02
    // 23:30 was wrongly counted.
    final now = DateTime(2026, 3, 9, 12);
    final workout = DateTime(2026, 3, 2, 23, 30);
    final store = await storeWithWorkoutAt(workout.millisecondsSinceEpoch);
    final digest = NotifyService.buildDigest(store, now: now);
    expect(digest, isNot(contains('1 workout this week')),
        reason: 'the 23:30 workout is outside the calendar 7-day window');
    expect(digest, contains('You have not lifted in 7 days'));
  });

  test('a workout inside the window still takes the weekly branch', () async {
    final now = DateTime(2026, 3, 11, 12);
    final store = await storeWithWorkoutAt(
        DateTime(2026, 3, 9, 0, 30).millisecondsSinceEpoch);
    final digest = NotifyService.buildDigest(store, now: now);
    expect(digest, contains('1 workout this week'));
    expect(digest, isNot(contains('You have not lifted')));
  });
}
