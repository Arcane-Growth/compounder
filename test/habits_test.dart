import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/habits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Feature 4 proofs: cadence period-boundary math (daily/weekly/monthly, DST
/// safe), strict date parsing, progress/streak math, store CRUD + completion
/// toggling, and the v9 -> v10 migration on a real v9 database.

HabitCompletion completion(int habitId, DateTime day, {int count = 1}) =>
    HabitCompletion(
      id: 0,
      habitId: habitId,
      day: habitDayKey(day),
      count: count,
      createdAt: 0,
    );

Habit habit({
  int id = 1,
  String name = 'Read',
  String cadence = 'daily',
  int target = 1,
  bool archived = false,
}) =>
    Habit(
      id: id,
      name: name,
      cadence: cadence,
      target: target,
      archived: archived,
      createdAt: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUpAll(tzdata.initializeTimeZones);

  tz.Location ny() => tz.getLocation('America/New_York');

  group('cadence period boundaries', () {
    test('daily period is exactly the requested calendar day', () {
      final period = habitPeriodFor(HabitCadence.daily, DateTime(2026, 11, 8));
      expect(habitDayKey(period.start), '2026-11-08');
      expect(habitDayKey(period.end), '2026-11-09');
      expect(period.contains(DateTime(2026, 11, 8)), isTrue);
      expect(period.contains(DateTime(2026, 11, 9)), isFalse);
    });

    test('weekly period starts on Monday and spans seven days', () {
      // 2026-11-08 is a Sunday: its ISO week starts Monday 2026-11-02.
      final period = habitPeriodFor(HabitCadence.weekly, DateTime(2026, 11, 8));
      expect(period.start.weekday, DateTime.monday);
      expect(habitDayKey(period.start), '2026-11-02');
      expect(habitDayKey(period.end), '2026-11-09');
      expect(period.contains(DateTime(2026, 11, 2)), isTrue);
      expect(period.contains(DateTime(2026, 11, 8)), isTrue);
      expect(period.contains(DateTime(2026, 11, 9)), isFalse);
    });

    test('monthly period is the calendar month', () {
      final period =
          habitPeriodFor(HabitCadence.monthly, DateTime(2026, 11, 8));
      expect(habitDayKey(period.start), '2026-11-01');
      expect(habitDayKey(period.end), '2026-12-01');
      expect(period.contains(DateTime(2026, 11, 30)), isTrue);
      expect(period.contains(DateTime(2026, 12, 1)), isFalse);
    });

    test('weekly boundary is DST-safe at the 2026-03-08 spring-forward', () {
      // 2026-03-08 02:00 EST -> 03:00 EDT in America/New_York. A 24-hour step
      // from Monday 2026-03-02 lands on 01:00, which is not a day key.
      final monday = tz.TZDateTime(ny(), 2026, 3, 2);
      final viaDuration = monday.add(const Duration(days: 7));
      expect(viaDuration.day, 9);
      expect(viaDuration.hour, 1,
          reason: 'Duration stepping is the bug this math must avoid');

      final period =
          habitPeriodFor(HabitCadence.weekly, tz.TZDateTime(ny(), 2026, 3, 8));
      expect(habitDayKey(period.start), '2026-03-02');
      expect(habitDayKey(period.end), '2026-03-09');
      expect(period.end.hour, 0, reason: 'period end must stay a day key');
      expect(period.contains(DateTime(2026, 3, 8)), isTrue);
      expect(period.contains(DateTime(2026, 3, 9)), isFalse);
    });

    test('monthly boundary is DST-safe at the 2026-11-01 fall-back', () {
      final period = habitPeriodFor(
          HabitCadence.monthly, tz.TZDateTime(ny(), 2026, 11, 1));
      expect(habitDayKey(period.start), '2026-11-01');
      expect(habitDayKey(period.end), '2026-12-01');
      expect(period.start.hour, 0);
      expect(period.end.hour, 0);
      expect(period.contains(DateTime(2026, 11, 30)), isTrue);
    });

    test('previous period walks back one calendar period across DST', () {
      final weekly = habitPeriodFor(HabitCadence.weekly, DateTime(2026, 3, 8));
      final previous = previousHabitPeriod(HabitCadence.weekly, weekly);
      expect(habitDayKey(previous.start), '2026-02-23');
      expect(habitDayKey(previous.end), '2026-03-02');
      final monthly =
          habitPeriodFor(HabitCadence.monthly, DateTime(2026, 11, 8));
      final previousMonth = previousHabitPeriod(HabitCadence.monthly, monthly);
      expect(habitDayKey(previousMonth.start), '2026-10-01');
      expect(habitDayKey(previousMonth.end), '2026-11-01');
    });
  });

  group('strict date parsing', () {
    test('accepts a real YYYY-MM-DD date', () {
      final parsed = parseHabitDay('2026-11-08');
      expect(parsed, isNotNull);
      expect(habitDayKey(parsed!), '2026-11-08');
    });

    test('rejects malformed and impossible dates', () {
      for (final raw in <Object?>[
        null,
        20261108,
        '',
        '2026-11-8',
        '2026-1-08',
        '08/11/2026',
        '2026-13-01',
        '2026-02-30',
        '2026-11-08T12:00',
        'tomorrow',
      ]) {
        expect(parseHabitDay(raw), isNull, reason: 'must reject $raw');
      }
    });
  });

  group('progress and streak math', () {
    final today = DateTime(2026, 11, 8);

    test('daily progress counts only the current day', () {
      final completions = [
        completion(1, DateTime(2026, 11, 7)),
        completion(1, DateTime(2026, 11, 8)),
      ];
      final progress = habitProgress(habit(), completions, today: today);
      expect(progress.completedDays, 1);
      expect(progress.met, isTrue);
    });

    test('weekly progress counts distinct days inside the ISO week', () {
      final completions = [
        completion(1, DateTime(2026, 11, 2)),
        completion(1, DateTime(2026, 11, 4)),
        completion(1, DateTime(2026, 11, 8)),
        // Previous week: must not count toward this week's target.
        completion(1, DateTime(2026, 11, 1)),
      ];
      final progress = habitProgress(
          habit(cadence: 'weekly', target: 3), completions,
          today: today);
      expect(progress.completedDays, 3);
      expect(progress.met, isTrue);
    });

    test('a zero-count or malformed completion does not satisfy a target', () {
      final completions = [
        completion(1, DateTime(2026, 11, 8), count: 0),
        const HabitCompletion(
            id: 0, habitId: 1, day: 'not-a-date', count: 1, createdAt: 0),
      ];
      final progress = habitProgress(habit(), completions, today: today);
      expect(progress.completedDays, 0);
      expect(progress.met, isFalse);
    });

    test('daily streak counts consecutive completed days ending today', () {
      final completions = [
        completion(1, DateTime(2026, 11, 6)),
        completion(1, DateTime(2026, 11, 7)),
        completion(1, DateTime(2026, 11, 8)),
      ];
      expect(habitStreak(HabitCadence.daily, 1, completions, today: today), 3);
    });

    test('a missed day breaks the streak', () {
      final completions = [
        completion(1, DateTime(2026, 11, 4)),
        completion(1, DateTime(2026, 11, 7)),
        completion(1, DateTime(2026, 11, 8)),
      ];
      expect(habitStreak(HabitCadence.daily, 1, completions, today: today), 2);
    });

    test('an unfinished current period keeps the streak up to the last one',
        () {
      // One day done this week against a target of 3: the week is not met yet,
      // so the streak is measured from the previous (completed) week.
      final completions = [
        completion(1, DateTime(2026, 10, 26)),
        completion(1, DateTime(2026, 10, 28)),
        completion(1, DateTime(2026, 11, 2)),
      ];
      expect(habitStreak(HabitCadence.weekly, 2, completions, today: today), 1);
    });

    test('monthly streak counts consecutive met months', () {
      final completions = [
        completion(1, DateTime(2026, 9, 3)),
        completion(1, DateTime(2026, 9, 20)),
        completion(1, DateTime(2026, 10, 5)),
        completion(1, DateTime(2026, 10, 25)),
        completion(1, DateTime(2026, 11, 2)),
      ];
      expect(
          habitStreak(HabitCadence.monthly, 2, completions, today: today), 2);
    });

    test('no completions means no streak', () {
      expect(habitStreak(HabitCadence.daily, 1, const [], today: today), 0);
    });
  });

  group('store CRUD and completion toggling', () {
    late AppStore store;
    late String path;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      path = '${await databaseFactory.getDatabasesPath()}/'
          'compounder_habits_test.db';
      await databaseFactory.deleteDatabase(path);
      store = await AppStore.open(prefs, path: path);
    });

    tearDown(() async {
      await store.db.close();
      await databaseFactory.deleteDatabase(path);
    });

    test('create, read, update, archive and delete a habit', () async {
      final id = await store.createHabit('Read', 'weekly', 3);
      expect(store.habits, hasLength(1));
      expect(store.habits.single.name, 'Read');
      expect(store.habits.single.cadence, 'weekly');
      expect(store.habits.single.target, 3);
      expect(store.habits.single.archived, isFalse);

      await store.updateHabit(id,
          name: 'Read books', cadence: 'monthly', target: 4);
      final updated = store.habits.single;
      expect(updated.name, 'Read books');
      expect(updated.cadence, 'monthly');
      expect(updated.target, 4);

      await store.updateHabit(id, archived: true);
      expect(store.habits.single.archived, isTrue);
      await store.updateHabit(id, archived: false);
      expect(store.habits.single.archived, isFalse);

      await store.setHabitCompletion(id, DateTime(2026, 11, 8), true);
      expect(store.habitCompletions, hasLength(1));
      await store.deleteHabit(id);
      expect(store.habits, isEmpty);
      expect(store.habitCompletions, isEmpty,
          reason: 'history must go with the habit');
      expect(await store.db.query('habit_completions'), isEmpty);
    });

    test('invalid input is rejected with a StoreException', () async {
      await expectLater(
          store.createHabit('  ', 'daily', 1), throwsA(isA<StoreException>()));
      await expectLater(store.createHabit('Read', 'yearly', 1),
          throwsA(isA<StoreException>()));
      await expectLater(store.createHabit('Read', 'daily', 0),
          throwsA(isA<StoreException>()));
      expect(store.habits, isEmpty);

      final id = await store.createHabit('Read', 'daily', 1);
      await expectLater(store.updateHabit(id, cadence: 'hourly'),
          throwsA(isA<StoreException>()));
      await expectLater(
          store.updateHabit(id, target: -2), throwsA(isA<StoreException>()));
      await expectLater(
          store.updateHabit(id, name: ' '), throwsA(isA<StoreException>()));
      expect(store.habits.single.name, 'Read');
      expect(store.habits.single.cadence, 'daily');
      expect(store.habits.single.target, 1);
    });

    test('completion toggle is idempotent and reversible', () async {
      final id = await store.createHabit('Walk', 'daily', 1);
      final day = DateTime(2026, 11, 8);
      expect(await store.toggleHabitCompletion(id, day), isTrue);
      expect(store.habitCompletions, hasLength(1));
      expect(store.habitCompletions.single.day, '2026-11-08');
      // Checking the same day again must not duplicate the row.
      await store.setHabitCompletion(id, day, true);
      expect(store.habitCompletions, hasLength(1));
      expect(await store.toggleHabitCompletion(id, day), isFalse);
      expect(store.habitCompletions, isEmpty);
      // Unchecking an unchecked day is a no-op.
      await store.setHabitCompletion(id, day, false);
      expect(store.habitCompletions, isEmpty);
    });

    test('completion for an unknown habit is rejected', () async {
      await expectLater(
          store.setHabitCompletion(99, DateTime(2026, 11, 8), true),
          throwsA(isA<StoreException>()));
      expect(store.habitCompletions, isEmpty);
    });

    test('range queries return only the requested days', () async {
      final id = await store.createHabit('Walk', 'weekly', 2);
      for (final day in [
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 2),
        DateTime(2026, 11, 8),
      ]) {
        await store.setHabitCompletion(id, day, true);
      }
      final week = await store.habitCompletionsFor(id,
          from: DateTime(2026, 11, 2), to: DateTime(2026, 11, 9));
      expect(week.map((c) => c.day).toList(), ['2026-11-02', '2026-11-08']);
      final grouped = await store.habitCompletionsInRange(
          DateTime(2026, 11, 1), DateTime(2026, 11, 9));
      expect(grouped[id], hasLength(3),
          reason: 'the range is inclusive of its start day');
    });
  });

  group('schema v10 migration', () {
    late String path;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      path = '${await databaseFactory.getDatabasesPath()}/'
          'compounder_habits_migration_test.db';
      await databaseFactory.deleteDatabase(path);
    });

    tearDown(() async {
      await databaseFactory.deleteDatabase(path);
    });

    Future<Set<String>> tables(AppStore store) async {
      final rows = await store.db
          .rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
      return {for (final r in rows) r['name'] as String};
    }

    test('fresh install creates the habit tables at the current version',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final store = await AppStore.open(prefs, path: path);
      expect(await store.db.getVersion(), 11);
      expect(await tables(store), containsAll(['habits', 'habit_completions']));
      await store.db.close();
    });

    test('a real v9 database upgrades without losing data', () async {
      final prefs = await SharedPreferences.getInstance();
      var store = await AppStore.open(prefs, path: path);
      await store.db.insert('meals', {
        'timestamp': 3000,
        'dish': 'Oats',
        'calories': 400.0,
        'protein': 20.0,
        'carbs': 50.0,
        'fat': 8.0,
      });
      await store.db.insert('workouts', {
        'name': 'Leg day',
        'started_at': 1000,
        'ended_at': 2000,
      });
      await store.db.insert('moods', {
        'timestamp': 6000,
        'mood': 4,
        'note': 'ok',
      });

      // Rewind to a genuine v9 shape: the habit tables did not exist and
      // user_version was 9. This drives the production 9 -> 11 path.
      await store.db.execute('DROP TABLE IF EXISTS habit_completions');
      await store.db.execute('DROP TABLE IF EXISTS habits');
      await store.db.setVersion(9);
      expect(await store.db.getVersion(), 9);
      expect(await tables(store), isNot(contains('habits')));
      await store.db.close();

      store = await AppStore.open(prefs, path: path);
      expect(await store.db.getVersion(), 11);
      expect(await tables(store), containsAll(['habits', 'habit_completions']));

      // No data loss in the pre-existing tables.
      expect(await store.db.query('meals'), hasLength(1));
      expect(await store.db.query('workouts'), hasLength(1));
      expect(await store.db.query('moods'), hasLength(1));
      expect((await store.db.query('meals')).single['dish'], 'Oats');

      // The new tables are usable straight after the migration.
      final id = await store.createHabit('Read', 'daily', 1);
      await store.setHabitCompletion(id, DateTime(2026, 11, 8), true);
      expect(store.habits, hasLength(1));
      expect(store.habitCompletions, hasLength(1));
      await store.db.close();
    });

    test('the v10 step is safe to re-run on a partially applied migration',
        () async {
      final prefs = await SharedPreferences.getInstance();
      var store = await AppStore.open(prefs, path: path);
      final id = await store.createHabit('Read', 'daily', 1);
      await store.setHabitCompletion(id, DateTime(2026, 11, 8), true);
      // Tables already exist; rewind only the version so the step runs again.
      await store.db.setVersion(9);
      await store.db.close();

      store = await AppStore.open(prefs, path: path);
      expect(await store.db.getVersion(), 11);
      expect(store.habits, hasLength(1));
      expect(store.habitCompletions, hasLength(1),
          reason: 'IF NOT EXISTS must not drop the existing rows');
      await store.db.close();
    });
  });
}
