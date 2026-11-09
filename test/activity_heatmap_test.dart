import 'package:compounder/data/store.dart';
import 'package:compounder/domain/activity.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/health.dart';
import 'package:compounder/ui/heatmap.dart';
import 'package:compounder/ui/history.dart';
import 'package:compounder/ui/home.dart';
import 'package:compounder/ui/progress.dart';
import 'package:compounder/ui/settings.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:compounder/ui/workout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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

/// Activity heatmap + gamified home: intensity mapping, streak and perfect-day
/// math (including a gap, a single day and a DST transition), the aggregate
/// store query against a seeded database, and the heatmap widget itself.

PillarDay day(String key,
        {int workout = 0,
        int nutrition = 0,
        int mind = 0,
        int habits = 0}) =>
    PillarDay(
      day: key,
      workoutCount: workout,
      nutritionCount: nutrition,
      mindCount: mind,
      habitCount: habits,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUpAll(tzdata.initializeTimeZones);

  group('intensity mapping', () {
    test('0-4 distinct pillars map to intensity 0-4', () {
      expect(day('2026-11-09').intensity, 0);
      expect(day('2026-11-09', workout: 1).intensity, 1);
      expect(day('2026-11-09', workout: 1, nutrition: 1).intensity, 2);
      expect(day('2026-11-09', workout: 1, nutrition: 1, mind: 1).intensity, 3);
      expect(
          day('2026-11-09',
                  workout: 1, nutrition: 1, mind: 1, habits: 1)
              .intensity,
          4);
    });

    test('several rows in one pillar still count as one pillar', () {
      final many = day('2026-11-09', workout: 5, nutrition: 3);
      expect(many.intensity, 2,
          reason: 'intensity is distinct pillars, not row count');
      expect(many.mask, pillarWorkout | pillarNutrition);
    });

    test('perfect requires all four pillars', () {
      expect(day('2026-11-09', workout: 1, nutrition: 1, mind: 1).perfect,
          isFalse);
      expect(
          day('2026-11-09',
                  workout: 1, nutrition: 1, mind: 1, habits: 1)
              .perfect,
          isTrue);
      expect(day('2026-11-09').perfect, isFalse);
    });

    test('countFor reports the per-pillar row count', () {
      final d = day('2026-11-09', workout: 2, mind: 3);
      expect(d.countFor(pillarWorkout), 2);
      expect(d.countFor(pillarMind), 3);
      expect(d.countFor(pillarNutrition), 0);
      expect(d.hasPillar(pillarHabits), isFalse);
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

    test('a DST transition day is one day, not zero or two', () {
      final ny = tz.getLocation('America/New_York');
      final before = tz.TZDateTime(ny, 2026, 3, 7, 12);
      final dst = tz.TZDateTime(ny, 2026, 3, 8, 12);
      final after = tz.TZDateTime(ny, 2026, 3, 9, 12);
      // Fail loudly if the zone data ever stops having the transition: the
      // test would otherwise pass without exercising DST at all.
      expect(dst.timeZoneOffset, isNot(before.timeZoneOffset),
          reason: 'America/New_York must spring forward on 2026-03-08');
      expect(localDayKey(before), '2026-03-07');
      expect(localDayKey(dst), '2026-03-08');
      expect(localDayKey(after), '2026-03-09');
      final days = {
        for (final d in [before, dst, after])
          localDayKey(d): day(localDayKey(d), workout: 1),
      };
      expect(currentStreak(days, after), 3,
          reason: 'calendar-day arithmetic must not skip the 23-hour day');
      expect(longestStreak(days), 3);
      expect(previousDayKey('2026-03-09'), '2026-03-08');
      expect(previousDayKey('2026-03-08'), '2026-03-07');
    });
  });

  group('perfect-day counting', () {
    test('counts only 4/4 days inside the requested month', () {
      final days = {
        '2026-11-01': day('2026-11-01',
            workout: 1, nutrition: 1, mind: 1, habits: 1),
        '2026-11-02': day('2026-11-02', workout: 1, nutrition: 1, mind: 1),
        '2026-11-15': day('2026-11-15',
            workout: 1, nutrition: 1, mind: 1, habits: 1),
        '2026-10-31': day('2026-10-31',
            workout: 1, nutrition: 1, mind: 1, habits: 1),
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
      // 2026-11-02: all four pillars.
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
      expect(perfect.intensity, 4);
      expect(perfect.workoutCount, 1);
      expect(perfect.nutritionCount, 1);
      expect(perfect.mindCount, 1);
      expect(perfect.habitCount, 1);

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

    Widget host({ValueChanged<int>? selectTab}) => MultiProvider(
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
              child: const HomeTab(),
            ),
          ),
        );

    testWidgets('shows the four-pillar checklist and opens the heatmap',
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

      for (final label in ['Workout', 'Nutrition', 'Mood & Mind', 'Habits']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Logged today'), findsOneWidget,
          reason: 'the seeded workout marks the Workout pillar done');
      expect(find.text('Not yet — tap to log'), findsNWidgets(3));
      expect(find.text('1-day streak'), findsOneWidget);

      await tester.tap(find.text('Nutrition'));
      expect(selected, 1, reason: 'Nutrition taps through to the Macros tab');

      await tester.scrollUntilVisible(find.text('Last 12 weeks'), 200);
      await tester.pump();
      expect(find.byType(ActivityHeatmap), findsOneWidget);
      await tester.tap(find.text('Last 12 weeks'));
      await tester.pumpAndSettle();
      expect(find.byType(HeatmapScreen), findsOneWidget);
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
      expect(selected, 4, reason: 'Coach selects the Coach tab');

      await tapLink('Wealth');
      expect(selected, 2, reason: 'Wealth selects the Wealth tab');

      await tapLink('Health');
      expect(find.byType(HealthDataScreen, skipOffstage: false), findsOneWidget);
      await popRoute();

      await tapLink('Settings');
      expect(find.byType(SettingsScreen, skipOffstage: false), findsOneWidget);
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
                    workout: 1, nutrition: 1, mind: 1, habits: 1),
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
      expect(tester.widget<HeatmapCell>(cell).intensity, 4);
      await tester.tap(cell);
      expect(tapped, DateTime(2026, 1, 15));
    });

    testWidgets('intensity 0 and 4 use different colours', (tester) async {
      late Color empty;
      late Color full;
      await tester.pumpWidget(MaterialApp(
        theme: CompounderTheme.light(),
        home: Builder(builder: (context) {
          empty = heatmapColor(context, 0);
          full = heatmapColor(context, 4);
          return const SizedBox();
        }),
      ));
      expect(empty, isNot(full));
    });
  });
}
