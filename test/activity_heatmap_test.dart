import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/activity.dart';
import 'package:compounder/domain/domain.dart';
import 'package:compounder/domain/plan.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/health.dart';
import 'package:compounder/ui/heatmap.dart';
import 'package:compounder/ui/history.dart';
import 'package:compounder/ui/home.dart';
import 'package:compounder/ui/planner.dart';
import 'package:compounder/ui/progress.dart';
import 'package:compounder/ui/settings.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:compounder/ui/workout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart' hide WorkoutSummary;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Health plugin stub: the home quick links open Settings and the Fitness
/// screen, both of which read [HealthService]; the stub keeps them off the
/// platform channels.
class _StubHealthSource implements HealthSource {
  @override
  Future<void> configure() async {}

  @override
  Future<HealthConnectSdkStatus?> sdkStatus() async =>
      HealthConnectSdkStatus.sdkAvailable;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> install() async {}

  @override
  bool isTypeAvailable(HealthDataType type) => true;

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types) async => true;

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types) async => true;

  @override
  Future<bool> isHistoryAvailable() async => true;

  @override
  Future<bool> isHistoryAuthorized() async => false;

  @override
  Future<bool> requestHistoryAuthorization() async => true;

  @override
  Future<List<HealthDataPoint>> fetch({
    required HealthDataType type,
    required DateTime start,
    required DateTime end,
  }) async =>
      const [];

  @override
  Future<void> revokePermissions() async {}
}

/// A store stand-in that counts the aggregate queries HomeTab issues.
///
/// It implements only the members HomeTab reads; anything else is forwarded to
/// [noSuchMethod] (and throws if actually used), so the fake cannot silently
/// diverge from the real store's surface.
class _CountingStore extends ChangeNotifier implements AppStore {
  int activityQueries = 0;
  int activeWorkoutQueries = 0;
  bool fail = false;
  Map<String, PillarDay> days = const {};
  Workout? active;

  @override
  Future<Map<String, PillarDay>> dailyPillarActivity(
      DateTime from, DateTime to) async {
    activityQueries++;
    if (fail) throw Exception('database_closed: the database is closed');
    return days;
  }

  @override
  Future<Workout?> activeWorkout() async {
    activeWorkoutQueries++;
    return active;
  }

  @override
  Future<List<PlanBlock>> planBlocksForDay(DateTime day) async => plan;

  List<PlanBlock> plan = const [];

  @override
  List<WorkoutSummary> history = const [];

  @override
  WeightUnit get unit => WeightUnit.kg;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Activity heatmap + gamified home: intensity mapping, streak and perfect-day
/// math (including a gap and a single day), the aggregate store query against a
/// seeded database, and the heatmap widget itself. The DST guard lives in
/// `activity_heatmap_dst_test.dart`, which pins the ambient zone.

PillarDay day(String key,
        {int workout = 0,
        int nutrition = 0,
        int mind = 0,
        int habits = 0,
        int plan = 0}) =>
    PillarDay(
      day: key,
      workoutCount: workout,
      nutritionCount: nutrition,
      mindCount: mind,
      habitCount: habits,
      planCount: plan,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('intensity mapping', () {
    test('0-5 distinct pillars map to intensity 0-5', () {
      expect(day('2026-11-09').intensity, 0);
      expect(day('2026-11-09', workout: 1).intensity, 1);
      expect(day('2026-11-09', workout: 1, nutrition: 1).intensity, 2);
      expect(day('2026-11-09', workout: 1, nutrition: 1, mind: 1).intensity, 3);
      expect(
          day('2026-11-09', workout: 1, nutrition: 1, mind: 1, habits: 1)
              .intensity,
          4);
      expect(
          day('2026-11-09',
                  workout: 1, nutrition: 1, mind: 1, habits: 1, plan: 1)
              .intensity,
          5);
    });

    test('several rows in one pillar still count as one pillar', () {
      final many = day('2026-11-09', workout: 5, nutrition: 3);
      expect(many.intensity, 2,
          reason: 'intensity is distinct pillars, not row count');
      expect(many.mask, pillarWorkout | pillarNutrition);
    });

    test('perfect requires all five pillars', () {
      expect(day('2026-11-09', workout: 1, nutrition: 1, mind: 1).perfect,
          isFalse);
      expect(
          day('2026-11-09', workout: 1, nutrition: 1, mind: 1, habits: 1)
              .perfect,
          isFalse,
          reason: 'four of five pillars is not a perfect day');
      expect(
          day('2026-11-09',
                  workout: 1, nutrition: 1, mind: 1, habits: 1, plan: 1)
              .perfect,
          isTrue);
      expect(day('2026-11-09').perfect, isFalse);
      expect(allPillarsMask, 31);
    });

    test('countFor reports the per-pillar row count', () {
      final d = day('2026-11-09', workout: 2, mind: 3, plan: 4);
      expect(d.countFor(pillarWorkout), 2);
      expect(d.countFor(pillarMind), 3);
      expect(d.countFor(pillarPlan), 4);
      expect(d.countFor(pillarNutrition), 0);
      expect(d.hasPillar(pillarHabits), isFalse);
      expect(d.hasPillar(pillarPlan), isTrue);
    });
  });

  group('streak computation', () {
    final today = DateTime(2026, 11, 9);

    test('a gap ends the streak', () {
      final days = {
        '2026-11-09': day('2026-11-09', workout: 1),
        '2026-11-08': day('2026-11-08', nutrition: 1),
        '2026-11-06': day('2026-11-06', mind: 1),
      };
      expect(currentStreak(days, today), 2);
      expect(longestStreak(days), 2);
    });

    test('a single logged day is a streak of one', () {
      final days = {'2026-11-09': day('2026-11-09', habits: 1)};
      expect(currentStreak(days, today), 1);
      expect(longestStreak(days), 1);
    });

    test('an unfinished today does not zero a streak', () {
      final days = {
        '2026-11-08': day('2026-11-08', workout: 1),
        '2026-11-07': day('2026-11-07', workout: 1),
      };
      expect(currentStreak(days, today), 2,
          reason: 'the streak is measured up to yesterday when today is empty');
    });

    test('an empty map has no streak', () {
      expect(currentStreak({}, today), 0);
      expect(longestStreak({}), 0);
    });

    test('longest streak finds the best historical run', () {
      final days = {
        '2026-10-01': day('2026-10-01', workout: 1),
        '2026-10-02': day('2026-10-02', workout: 1),
        '2026-10-03': day('2026-10-03', workout: 1),
        '2026-10-04': day('2026-10-04', workout: 1),
        '2026-11-09': day('2026-11-09', workout: 1),
      };
      expect(longestStreak(days), 4);
      expect(currentStreak(days, today), 1);
    });
  });

  group('perfect-day counting', () {
    test('counts only 5/5 days inside the requested month', () {
      final days = {
        '2026-11-01': day('2026-11-01',
            workout: 1, nutrition: 1, mind: 1, habits: 1, plan: 1),
        '2026-11-02': day('2026-11-02', workout: 1, nutrition: 1, mind: 1),
        '2026-11-15': day('2026-11-15',
            workout: 1, nutrition: 1, mind: 1, habits: 1, plan: 1),
        '2026-10-31': day('2026-10-31',
            workout: 1, nutrition: 1, mind: 1, habits: 1, plan: 1),
      };
      expect(perfectDaysInMonth(days, 2026, 11), 2);
      expect(perfectDaysInMonth(days, 2026, 10), 1);
      expect(perfectDaysInMonth(days, 2026, 12), 0);
    });
  });

  group('aggregate store query', () {
    late AppStore store;
    late String path;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      path = '${await databaseFactory.getDatabasesPath()}/'
          'compounder_activity_test.db';
      await databaseFactory.deleteDatabase(path);
      store = await AppStore.open(prefs, path: path);
    });

    tearDown(() async {
      await store.db.close();
      await databaseFactory.deleteDatabase(path);
    });

    Future<void> seed() async {
      // 2026-11-02: all five pillars.
      await store.db.insert('workouts', {
        'name': 'Legs',
        'started_at': DateTime(2026, 11, 2, 6).millisecondsSinceEpoch,
      });
      await store.db.insert('meals', {
        'timestamp': DateTime(2026, 11, 2, 12).millisecondsSinceEpoch,
        'dish': 'Oats',
        'calories': 400,
        'protein': 20,
        'carbs': 50,
        'fat': 10,
      });
      await store.db.insert('moods', {
        'timestamp': DateTime(2026, 11, 2, 20).millisecondsSinceEpoch,
        'mood': 4,
      });
      final habitId = await store.db.insert('habits', {
        'name': 'Read',
        'cadence': 'daily',
        'target': 1,
        'created_at': 0,
      });
      await store.db.insert('habit_completions', {
        'habit_id': habitId,
        'day': '2026-11-02',
        'count': 1,
        'created_at': 0,
      });
      await store.db.insert('plan_blocks', {
        'day': '2026-11-02',
        'title': 'Deep work',
        'start_min': 540,
        'end_min': 600,
        'done': 0,
        'created_at': 0,
        'position': 0,
      });
      // 2026-11-03: nutrition only.
      await store.db.insert('meals', {
        'timestamp': DateTime(2026, 11, 3, 8).millisecondsSinceEpoch,
        'dish': 'Toast',
        'calories': 200,
        'protein': 5,
        'carbs': 30,
        'fat': 4,
      });
      // 2026-11-04: nothing.
      // 2026-11-05: mind only, two rows.
      await store.db.insert('meditations', {
        'timestamp': DateTime(2026, 11, 5, 7).millisecondsSinceEpoch,
        'minutes': 10,
      });
      await store.db.insert('thought_records', {
        'timestamp': DateTime(2026, 11, 5, 21).millisecondsSinceEpoch,
        'situation': 'Meeting',
        'thought': 'I will fail',
      });
      // Day-boundary rows: 23:59 belongs to 11-06, 00:00 to 11-07.
      await store.db.insert('workouts', {
        'name': 'Late',
        'started_at': DateTime(2026, 11, 6, 23, 59).millisecondsSinceEpoch,
      });
      await store.db.insert('meals', {
        'timestamp': DateTime(2026, 11, 7, 0, 0).millisecondsSinceEpoch,
        'dish': 'Midnight',
        'calories': 100,
        'protein': 1,
        'carbs': 1,
        'fat': 1,
      });
      // A zero-count completion must not count as a logged habit.
      await store.db.insert('habit_completions', {
        'habit_id': habitId,
        'day': '2026-11-08',
        'count': 0,
        'created_at': 0,
      });
    }

    test('returns correct per-day masks for a seeded range', () async {
      await seed();
      final days = await store.dailyPillarActivity(
          DateTime(2026, 11, 2), DateTime(2026, 11, 9));

      final perfect = days['2026-11-02']!;
      expect(perfect.mask, allPillarsMask);
      expect(perfect.intensity, 5);
      expect(perfect.workoutCount, 1);
      expect(perfect.nutritionCount, 1);
      expect(perfect.mindCount, 1);
      expect(perfect.habitCount, 1);
      expect(perfect.planCount, 1);

      final nutritionOnly = days['2026-11-03']!;
      expect(nutritionOnly.mask, pillarNutrition);
      expect(nutritionOnly.intensity, 1);

      expect(days.containsKey('2026-11-04'), isFalse,
          reason: 'a day with no rows is absent, i.e. intensity 0');

      final mindOnly = days['2026-11-05']!;
      expect(mindOnly.mask, pillarMind);
      expect(mindOnly.mindCount, 2,
          reason: 'meditation and thought record both count as mind rows');

      expect(days['2026-11-06']!.mask, pillarWorkout,
          reason: '23:59 local belongs to that day');
      expect(days['2026-11-07']!.mask, pillarNutrition,
          reason: '00:00 local belongs to the next day');
      expect(days.containsKey('2026-11-08'), isFalse,
          reason: 'a count <= 0 completion is not a logged habit');
    });

    test('a plan block alone counts as the planning pillar', () async {
      await store.db.insert('plan_blocks', {
        'day': '2026-11-09',
        'title': 'Plan the week',
        'start_min': 480,
        'end_min': 510,
        'done': 0,
        'created_at': 0,
        'position': 0,
      });
      final days = await store.dailyPillarActivity(
          DateTime(2026, 11, 9), DateTime(2026, 11, 10));
      final planned = days['2026-11-09']!;
      expect(planned.mask, pillarPlan);
      expect(planned.planCount, 1);
      expect(planned.intensity, 1,
          reason: 'planning the day is a pillar, not a bonus');
      expect(planned.perfect, isFalse);
    });

    test('the range is half-open: rows at the end boundary are excluded',
        () async {
      // An in-range row on 11-04 proves the query still returns data.
      await store.db.insert('workouts', {
        'name': 'In range',
        'started_at': DateTime(2026, 11, 4, 12).millisecondsSinceEpoch,
      });
      // Boundary rows at exactly the exclusive end: local midnight 11-05.
      await store.db.insert('workouts', {
        'name': 'Boundary workout',
        'started_at': DateTime(2026, 11, 5).millisecondsSinceEpoch,
      });
      final habitId = await store.db.insert('habits', {
        'name': 'Boundary habit',
        'cadence': 'daily',
        'target': 1,
        'created_at': 0,
      });
      await store.db.insert('habit_completions', {
        'habit_id': habitId,
        'day': '2026-11-05',
        'count': 1,
        'created_at': 0,
      });

      final days = await store.dailyPillarActivity(
          DateTime(2026, 11, 2), DateTime(2026, 11, 5));
      expect(days.keys, unorderedEquals(['2026-11-04']));
      expect(days.containsKey('2026-11-05'), isFalse,
          reason: 'a workout at midnight 11-05 and a habit on 11-05 are '
              'outside the half-open range');
    });

    test('an empty range returns an empty map', () async {
      await seed();
      expect(
          await store.dailyPillarActivity(
              DateTime(2026, 11, 9), DateTime(2026, 11, 9)),
          isEmpty);
    });

    test('rows outside the range are not counted', () async {
      await seed();
      final days = await store.dailyPillarActivity(
          DateTime(2026, 11, 3), DateTime(2026, 11, 4));
      expect(days.keys, unorderedEquals(['2026-11-03']));
    });
  });

  group('home screen', () {
    late AppStore store;
    late HealthService health;
    late String path;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      path = '${await databaseFactory.getDatabasesPath()}/'
          'compounder_home_test.db';
      await databaseFactory.deleteDatabase(path);
      store = await AppStore.open(prefs, path: path);
      health = HealthService(
        store: store,
        repository: HealthRepository(store.db),
        source: _StubHealthSource(),
      );
    });

    tearDown(() async {
      await store.db.close();
      await databaseFactory.deleteDatabase(path);
    });

    Widget host({
      ValueChanged<int>? selectTab,
      bool visible = true,
      DateTime Function()? now,
    }) =>
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppStore>.value(value: store),
            ChangeNotifierProvider<HealthService>.value(value: health),
            Provider<NotifyService>.value(value: NotifyService()),
          ],
          child: MaterialApp(
            theme: CompounderTheme.light(),
            home: ShellNav(
              openDrawer: () {},
              selectTab: selectTab,
              visible: visible,
              child: HomeTab(now: now),
            ),
          ),
        );

    testWidgets('shows the five-pillar checklist and opens the heatmap',
        (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await tester.runAsync(() async {
        await store.db.insert('workouts', {
          'name': 'Morning',
          'started_at': DateTime(today.year, today.month, today.day, 7)
              .millisecondsSinceEpoch,
          'ended_at': DateTime(today.year, today.month, today.day, 8)
              .millisecondsSinceEpoch,
        });
        await store.refreshAll();
      });

      int? selected;
      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: ShellNav(
            openDrawer: () {},
            selectTab: (i) => selected = i,
            child: const HomeTab(),
          ),
        ),
      ));
      // Let the store queries (real sqflite ffi work) complete.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      for (final label in [
        'Workout',
        'Nutrition',
        'Mood & Mind',
        'Habits',
        'Day plan'
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Logged today'), findsOneWidget,
          reason: 'the seeded workout marks the Workout pillar done');
      expect(find.text('Not yet — tap to log'), findsNWidgets(3));
      expect(find.text('Not planned yet — tap to plan'), findsOneWidget);
      expect(find.text('1 of 5 pillars logged today'), findsOneWidget);
      expect(find.text('Plan your day'), findsOneWidget,
          reason: 'an unplanned today must put the planner first on Home');
      expect(find.text('1-day streak'), findsOneWidget);

      await tester.tap(find.text('Nutrition'));
      expect(selected, tabMacros,
          reason: 'Nutrition taps through to the Macros tab');

      await tester.scrollUntilVisible(find.text('Last 12 weeks'), 200);
      await tester.pump();
      expect(find.byType(ActivityHeatmap), findsOneWidget);
      await tester.tap(find.text('Last 12 weeks'));
      await tester.pumpAndSettle();
      expect(find.byType(HeatmapScreen), findsOneWidget);
    });

    testWidgets('the plan card shows the next block and opens the planner',
        (tester) async {
      final now = DateTime(2026, 11, 9, 12);
      await tester.runAsync(() async {
        await store.createPlanBlock(
            day: DateTime(2026, 11, 9),
            title: 'Deep work',
            startMin: 13 * 60,
            endMin: 14 * 60);
        await store.refreshAll();
      });

      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: ShellNav(
            openDrawer: () {},
            selectTab: (_) {},
            child: HomeTab(now: () => now),
          ),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(find.text('Next: Deep work'), findsOneWidget,
          reason: 'a planned day reports the next block instead of a prompt');
      expect(find.text('13:00–14:00 · 0 of 1 done'), findsOneWidget);
      expect(find.text('Not planned yet — tap to plan'), findsNothing);
      expect(find.text('1 of 5 pillars logged today'), findsOneWidget,
          reason: 'a plan block alone logs the planning pillar');

      await tester.tap(find.text('Next: Deep work'));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.byType(PlannerScreen), findsOneWidget);
      expect(find.text('Deep work'), findsOneWidget);
    });

    testWidgets('the Day plan pillar tile opens the planner', (tester) async {
      final now = DateTime(2026, 11, 9, 12);
      await tester.pumpWidget(host(now: () => now));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      // The checklist tile, not the plan card: this exercises _openPillar's
      // pillarPlan branch, which the plan-card test never reaches.
      await tester.ensureVisible(find.text('Day plan'));
      await tester.pump();
      await tester.tap(find.text('Day plan'));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      expect(find.byType(PlannerScreen), findsOneWidget,
          reason: 'the Day plan pillar tile must open the planner');
    });

    testWidgets('shows the active-workout resume card and opens the workout',
        (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await tester.runAsync(() async {
        await store.db.insert('workouts', {
          'name': 'Leg day',
          'started_at': DateTime(today.year, today.month, today.day, 7)
              .millisecondsSinceEpoch,
          // No ended_at: the workout is still in progress.
        });
        await store.refreshAll();
      });

      await tester.pumpWidget(host());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      expect(find.text('Leg day'), findsOneWidget);
      expect(find.textContaining('In progress since'), findsOneWidget,
          reason: 'an unfinished workout must surface the resume card');

      await tester.tap(find.textContaining('In progress since'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Let WorkoutScreen's detail query finish while the database is open;
      // otherwise it completes after teardown and throws database_closed.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.byType(WorkoutScreen), findsOneWidget,
          reason: 'tapping the resume card opens the workout');
    });

    testWidgets('every quick link opens its screen or selects its tab',
        (tester) async {
      int? selected;
      await tester.pumpWidget(host(selectTab: (i) => selected = i));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      const labels = [
        'History',
        'Progress',
        'Coach',
        'Health',
        'Wealth',
        'Settings'
      ];
      await tester.scrollUntilVisible(find.text('History'), 200);
      await tester.pump();
      for (final label in labels) {
        await tester.ensureVisible(find.text(label));
        await tester.pump();
        expect(find.text(label), findsOneWidget,
            reason: '$label must be reachable from home');
      }

      Future<void> tapLink(String label) async {
        await tester.ensureVisible(find.text(label));
        await tester.pump();
        await tester.tap(find.text(label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // A second frame lets the Navigator finalize the route transition.
        await tester.pump();
      }

      Future<void> popRoute() async {
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        // Settle the pop transition so the home route is back onstage before
        // the next tap; the pushed screens here have no perpetual animation.
        await tester.pumpAndSettle();
      }

      await tapLink('History');
      expect(find.byType(HistoryScreen, skipOffstage: false), findsOneWidget);
      await popRoute();

      await tapLink('Progress');
      expect(find.byType(ProgressScreen, skipOffstage: false), findsOneWidget);
      await popRoute();

      await tapLink('Coach');
      expect(selected, tabCoach, reason: 'Coach selects the Coach tab');

      await tapLink('Wealth');
      expect(selected, tabWealth, reason: 'Wealth selects the Wealth tab');

      await tapLink('Health');
      expect(
          find.byType(HealthDataScreen, skipOffstage: false), findsOneWidget);
      await popRoute();

      await tapLink('Settings');
      expect(find.byType(SettingsScreen, skipOffstage: false), findsOneWidget);
    });

    testWidgets('home does not query the store while off-screen',
        (tester) async {
      final fake = _CountingStore();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStore>.value(value: fake),
          ChangeNotifierProvider<HealthService>.value(value: health),
          Provider<NotifyService>.value(value: NotifyService()),
        ],
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: ShellNav(
            openDrawer: () {},
            visible: false,
            child: const HomeTab(),
          ),
        ),
      ));
      await tester.pump();
      expect(fake.activityQueries, 0,
          reason: 'an off-screen tab must not run the aggregate query');
      expect(fake.activeWorkoutQueries, 0);

      // A store notification while off-screen must not query either.
      fake.notifyListeners();
      await tester.pump(const Duration(milliseconds: 200));
      expect(fake.activityQueries, 0,
          reason: 'a mutation on another tab must not reload this one');
      expect(fake.activeWorkoutQueries, 0);
    });

    testWidgets('home catches up when it becomes visible', (tester) async {
      final fake = _CountingStore();
      Widget build(bool visible) => MultiProvider(
            providers: [
              ChangeNotifierProvider<AppStore>.value(value: fake),
              ChangeNotifierProvider<HealthService>.value(value: health),
              Provider<NotifyService>.value(value: NotifyService()),
            ],
            child: MaterialApp(
              theme: CompounderTheme.light(),
              home: ShellNav(
                openDrawer: () {},
                visible: visible,
                child: const HomeTab(),
              ),
            ),
          );

      await tester.pumpWidget(build(false));
      await tester.pump();
      expect(fake.activityQueries, 0);

      await tester.pumpWidget(build(true));
      await tester.pump();
      expect(fake.activityQueries, 1,
          reason: 'becoming visible must catch up on the missed data');
    });

    testWidgets('home refreshes today when the app resumes', (tester) async {
      var now = DateTime(2026, 11, 9, 23, 30);
      await tester.pumpWidget(host(now: () => now));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(
          find.text(formatDate(DateTime(2026, 11, 9).millisecondsSinceEpoch)),
          findsOneWidget);

      // The app was backgrounded across midnight; resuming must follow the
      // clock instead of waiting for the next store notification.
      now = DateTime(2026, 11, 10, 0, 5);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(
          find.text(formatDate(DateTime(2026, 11, 10).millisecondsSinceEpoch)),
          findsOneWidget,
          reason: 'a resumed app must not keep showing yesterday');
    });

    testWidgets('activity screen refreshes when the store changes',
        (tester) async {
      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: const HeatmapScreen(),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(find.text('0-day streak'), findsNothing);
      expect(find.text('0'), findsWidgets,
          reason: 'the summary renders the empty store');

      // A log made while the screen is open must be reflected without a
      // manual refresh.
      await tester.runAsync(() async {
        await store.db.insert('workouts', {
          'name': 'Evening',
          'started_at': DateTime.now().millisecondsSinceEpoch,
        });
        await store.refreshAll();
        // The screen debounces store notifications; let the timer fire and the
        // aggregate query complete inside the real-async zone.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(find.text('1'), findsWidgets,
          reason: 'the current streak must update after a store change');
    });

    testWidgets('activity screen shows a human error, not raw SQLite text',
        (tester) async {
      final fake = _CountingStore()..fail = true;
      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: fake,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: const HeatmapScreen(),
        ),
      ));
      await tester.pump();
      expect(find.text('Could not load activity'), findsOneWidget);
      expect(find.textContaining('database_closed'), findsNothing,
          reason: 'the raw exception belongs in the log, not the UI');
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('activity screen offers a per-day list with tappable rows',
        (tester) async {
      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: const HeatmapScreen(),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(find.byType(ListView), findsOneWidget,
          reason: 'the activity screen must render its scrollable body');
      expect(find.text('RECENT DAYS'), findsOneWidget,
          reason: 'the per-day list is reachable without scrolling');

      // Scroll so the whole per-day list is on screen, then check every row.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(7),
          reason: 'the per-day list is the 48dp touch-target path');

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      expect(find.text('Nothing logged'), findsWidgets,
          reason: 'tapping a day row opens the same detail sheet');
    });

    testWidgets('activity screen opens on the newest week, not 52 weeks ago',
        (tester) async {
      final now = DateTime(2026, 11, 9, 12);
      await tester.runAsync(() async {
        await store.db.insert('workouts', {
          'name': 'Today',
          'started_at': DateTime(2026, 11, 9, 7).millisecondsSinceEpoch,
          'ended_at': DateTime(2026, 11, 9, 8).millisecondsSinceEpoch,
        });
        await store.refreshAll();
      });

      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: HeatmapScreen(now: () => now),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump();

      final todayCell = find.byWidgetPredicate(
          (w) => w is HeatmapCell && localDayKey(w.day) == '2026-11-09');
      expect(todayCell, findsOneWidget, reason: 'the grid must contain today');
      final rect = tester.getRect(todayCell);
      // Bound by the grid's own viewport, not the screen: the card padding
      // sits between the two, so a screen-width bound would still pass with
      // the newest cell hidden under the padding.
      final grid = tester.getRect(find.byType(ActivityHeatmap));
      expect(rect.left, greaterThanOrEqualTo(grid.left));
      expect(rect.right, lessThanOrEqualTo(grid.right),
          reason: 'the newest week must be on screen when the screen opens; '
              'without the auto-scroll it sits ~900dp to the right');
    });

    testWidgets('activity screen re-pins the newest week after a failed load',
        (tester) async {
      // The error branch replaces the grid with a retry column, destroying its
      // ScrollPosition. "Try again" rebuilds the grid at offset 0, so the pin
      // flag must be reset for the new position or the screen shows the oldest
      // week again — the exact defect the auto-scroll fixes.
      final now = DateTime(2026, 11, 9, 12);
      final fake = _CountingStore()..fail = true;
      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: fake,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: HeatmapScreen(now: () => now),
        ),
      ));
      await tester.pump();
      expect(find.text('Could not load activity'), findsOneWidget,
          reason: 'the first load must fail so the grid is torn down');

      fake.fail = false;
      await tester.tap(find.text('Try again'));
      // Let the retry load, the grid build, and the post-frame pin run.
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      final todayCell = find.byWidgetPredicate(
          (w) => w is HeatmapCell && localDayKey(w.day) == '2026-11-09');
      expect(todayCell, findsOneWidget,
          reason: 'the retry must rebuild the grid');
      final rect = tester.getRect(todayCell);
      final grid = tester.getRect(find.byType(ActivityHeatmap));
      expect(rect.right, lessThanOrEqualTo(grid.right),
          reason: 'after a failed load and retry the newest week must be '
              'pinned again, not left at the oldest week');
    });

    testWidgets('activity screen re-pins the newest week after a resize',
        (tester) async {
      final now = DateTime(2026, 11, 9, 12);
      await tester.runAsync(() async {
        await store.db.insert('workouts', {
          'name': 'Today',
          'started_at': DateTime(2026, 11, 9, 7).millisecondsSinceEpoch,
          'ended_at': DateTime(2026, 11, 9, 8).millisecondsSinceEpoch,
        });
        await store.refreshAll();
      });

      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: HeatmapScreen(now: () => now),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump();

      // Rotate to a narrow portrait window: the grid's viewport shrinks, so
      // the pinned offset must be recomputed or the newest week scrolls back
      // out of view.
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pump();
      await tester.pump();

      final todayCell = find.byWidgetPredicate(
          (w) => w is HeatmapCell && localDayKey(w.day) == '2026-11-09');
      expect(todayCell, findsOneWidget);
      final rect = tester.getRect(todayCell);
      expect(rect.right, lessThanOrEqualTo(400.0),
          reason: 'a resize must keep the newest week on screen');
    });

    testWidgets('home and legend do not overflow at 320x640/textScaler 2.0',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppStore>.value(value: store),
            ChangeNotifierProvider<HealthService>.value(value: health),
            Provider<NotifyService>.value(value: NotifyService()),
          ],
          child: ShellNav(
            openDrawer: () {},
            selectTab: (_) {},
            child: const HomeTab(),
          ),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'home must not overflow at 320dp/2.0');

      // Scroll through the whole home so every section is laid out.
      for (var i = 0; i < 10; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'home must not overflow at 320dp/2.0 (scroll $i)');
      }

      // The legend lives inside the Activity card: 320 - 40 (page padding) -
      // 32 (card padding) = 248dp of usable width.
      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: const Scaffold(
          body: SizedBox(width: 248, child: HeatmapLegend()),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'the heatmap legend must not overflow at 248dp/2.0');
    });
  });

  group('heatmap widget', () {
    testWidgets('renders one cell per in-range day and the legend',
        (tester) async {
      final start = DateTime(2026, 1, 1);
      final end = DateTime(2026, 3, 31);
      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ActivityHeatmap(
              days: const {},
              start: start,
              end: end,
              showLegend: true,
              scrollable: false,
            ),
          ),
        ),
      ));
      // Jan 1 .. Mar 31 2026 = 31 + 28 + 31 days.
      expect(find.byType(HeatmapCell), findsNWidgets(90));
      expect(find.text('Less'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
      expect(find.text('Jan'), findsOneWidget);
      expect(find.text('Mar'), findsOneWidget);
    });

    testWidgets('month labels align with their grid columns', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ActivityHeatmap(
              days: const {},
              start: DateTime(2026, 1, 1),
              end: DateTime(2026, 3, 31),
              scrollable: false,
            ),
          ),
        ),
      ));
      final labelX = tester.getTopLeft(find.text('Jan')).dx;
      final cell = find.byWidgetPredicate(
          (w) => w is HeatmapCell && w.day == DateTime(2026, 1, 1));
      expect(cell, findsOneWidget);
      final cellX = tester.getTopLeft(cell).dx;
      expect((labelX - cellX).abs(), lessThan(0.5),
          reason: 'the Jan label must sit over the Jan 1 column, not the '
              'weekday-label gutter');
    });

    testWidgets('month labels stay inside the requested range', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ActivityHeatmap(
              days: const {},
              start: DateTime(2026, 12, 28),
              end: DateTime(2026, 12, 31),
              scrollable: false,
            ),
          ),
        ),
      ));
      expect(find.text('Dec'), findsOneWidget);
      expect(find.text('Jan'), findsNothing,
          reason: 'the grid is padded to whole weeks; January starts after '
              'the requested range and must not be labelled');
    });

    testWidgets('a cell tap reports its own day', (tester) async {
      DateTime? tapped;
      final start = DateTime(2026, 1, 1);
      final end = DateTime(2026, 1, 31);
      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ActivityHeatmap(
              days: {
                '2026-01-15': day('2026-01-15',
                    workout: 1, nutrition: 1, mind: 1, habits: 1, plan: 1),
              },
              start: start,
              end: end,
              scrollable: false,
              onDayTap: (d) => tapped = d,
            ),
          ),
        ),
      ));
      expect(find.byType(HeatmapCell), findsNWidgets(31));
      final cell = find.byWidgetPredicate(
          (w) => w is HeatmapCell && w.day == DateTime(2026, 1, 15));
      expect(cell, findsOneWidget);
      expect(tester.widget<HeatmapCell>(cell).intensity, 5);
      await tester.tap(cell);
      expect(tapped, DateTime(2026, 1, 15));
    });

    testWidgets('intensity 0 and 5 use different colours', (tester) async {
      late Color empty;
      late Color full;
      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.light(),
        home: Builder(builder: (context) {
          empty = heatmapColor(context, 0);
          full = heatmapColor(context, 5);
          return const SizedBox();
        }),
      ));
      expect(empty, isNot(full));
    });
  });

  group('day detail sheet', () {
    testWidgets('five pillar rows scroll instead of overflowing at 320dp/2.0',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const full = PillarDay(
        day: '2026-11-09',
        workoutCount: 1,
        nutritionCount: 1,
        mindCount: 1,
        habitCount: 1,
        planCount: 1,
      );

      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    showDayDetail(context, DateTime(2026, 11, 9), full),
                child: const Text('Open day'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open day'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'the five-pillar sheet must scroll, not overflow, at '
              '320dp / 2.0');
      expect(find.text('5 of 5 pillars logged'), findsOneWidget);
      expect(find.text(pillarLabel(pillarPlan)), findsOneWidget);
    });
  });
}
