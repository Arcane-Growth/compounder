import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/domain.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/fitness.dart';
import 'package:compounder/ui/shell.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:compounder/ui/workout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart' hide WorkoutSummary;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Health plugin stub: the shell's post-frame `syncIfDue()` must not touch
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

/// A store stand-in that counts the queries FitnessTab issues. Anything not
/// implemented is forwarded to [noSuchMethod] so the fake cannot silently
/// diverge from the real store's surface.
class _CountingStore extends ChangeNotifier implements AppStore {
  int activeWorkoutQueries = 0;
  Workout? active;

  @override
  Future<Workout?> activeWorkout() async {
    activeWorkoutQueries++;
    return active;
  }

  @override
  List<WorkoutSummary> history = const [];

  @override
  WeightUnit get unit => WeightUnit.kg;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;
  late HealthService health;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final path = '${await databaseFactory.getDatabasesPath()}/fitness_nav.db';
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
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: health),
          Provider.value(value: NotifyService()),
        ],
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: const ShellScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder barText(String label) => find.descendant(
        of: find.byType(ShellBottomBar),
        matching: find.text(label),
      );

  group('bottom bar', () {
    testWidgets('shows Home, Fitness, Macros, Wealth and Coach, never Mind',
        (tester) async {
      await pumpShell(tester);

      expect(find.byType(ShellBottomBar), findsOneWidget);
      for (final label in ['Home', 'Fitness', 'Macros', 'Wealth', 'Coach']) {
        expect(barText(label), findsOneWidget,
            reason: '$label must be a bottom-bar destination');
      }
      expect(barText('Mind'), findsNothing,
          reason: 'Mind is drawer-only and must not appear in the bottom bar');
      expect(ShellBottomBar.destinations.length, 5);

      // excludeSemantics drops the InkWell's semantics, so the destination
      // must declare its own tap action or TalkBack cannot activate it.
      final homeSemantics = tester
          .widgetList<Semantics>(find.descendant(
              of: find.byType(ShellBottomBar),
              matching: find.byType(Semantics)))
          .firstWhere((s) => s.properties.label == 'Home');
      expect(homeSemantics.properties.onTap, isNotNull,
          reason: 'a bottom-bar destination must expose a tap action');
      expect(homeSemantics.properties.selected, isTrue);

      final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
      expect(stack.index, tabHome);
      expect(stack.children.length, shellTabCount,
          reason: 'Mind stays mounted at its own index');
    });

    testWidgets('drawer still reaches Mind and clears the bar selection',
        (tester) async {
      await pumpShell(tester);

      await tester.tap(find.byIcon(Icons.menu).first);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AppDrawer),
        matching: find.text('Mind'),
      ));
      await tester.pumpAndSettle();

      final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
      expect(stack.index, tabMind, reason: 'the drawer must select Mind');
      expect(find.byType(Drawer), findsNothing,
          reason: 'the drawer must close after selecting a tab');
      expect(
        tester
            .widget<ShellBottomBar>(find.byType(ShellBottomBar))
            .selectedIndex,
        -1,
        reason: 'a drawer-only tab must not light up a bottom-bar destination',
      );
    });
  });

  group('fitness tab', () {
    testWidgets('renders the hub and resumes an in-progress workout',
        (tester) async {
      await tester.runAsync(() async {
        await store.db.insert('workouts', {
          'name': 'Leg day',
          'started_at': DateTime.now().millisecondsSinceEpoch,
          // No ended_at: the workout is still in progress.
        });
        await store.refreshAll();
      });

      await pumpShell(tester);
      await tester.tap(barText('Fitness'));
      await tester.pumpAndSettle();
      // The hub was mounted off-screen, so it queries the store when it
      // becomes visible; let the real sqflite work finish.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
          tabFitness);
      final hub = find.byType(FitnessTab);
      expect(hub, findsOneWidget);
      expect(find.descendant(of: hub, matching: find.text('Leg day')),
          findsOneWidget,
          reason: 'the hub must surface the in-progress workout');
      expect(
          find.descendant(
              of: hub, matching: find.textContaining('In progress since')),
          findsOneWidget);
      for (final label in ['History', 'Progress', 'Exercises']) {
        expect(find.descendant(of: hub, matching: find.text(label)),
            findsOneWidget,
            reason: '$label must be reachable from the fitness hub');
      }

      await tester.tap(find.descendant(
          of: hub, matching: find.textContaining('In progress since')));
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

    testWidgets('does not query while off-screen and catches up when visible',
        (tester) async {
      final fake = _CountingStore();
      Widget build(bool visible) => ChangeNotifierProvider<AppStore>.value(
            value: fake,
            child: MaterialApp(
              theme: CompounderTheme.light(),
              home: ShellNav(
                openDrawer: () {},
                visible: visible,
                child: const FitnessTab(),
              ),
            ),
          );

      await tester.pumpWidget(build(false));
      await tester.pump();
      expect(fake.activeWorkoutQueries, 0,
          reason: 'an off-screen tab must not query the store');

      await tester.pumpWidget(build(true));
      await tester.pump();
      expect(fake.activeWorkoutQueries, 1,
          reason: 'becoming visible must catch up on the missed state');
    });
  });
}
