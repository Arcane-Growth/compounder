import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/macros.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature 2 widget proofs: the date controls actually move the day view, the
/// next-day/next-week controls are disabled at today/this week, the metric
/// switch changes the weekly numbers, and every bar has a semantic label that
/// states day, value and over/under.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  // No isolate: the widget test's fake-async zone cannot receive messages from
  // a background isolate, so DB futures would never complete.
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = await AppStore.open(prefs, path: inMemoryDatabasePath);
  });

  tearDown(() async {
    await store.db.close();
  });

  /// Tall viewport: the Macros tab is a lazy ListView, so the weekly card and
  /// the meal list are only built when they are on screen.
  Future<void> tallViewport(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget host(Widget child) => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(home: child),
      );

  Meal mealAt(DateTime at,
          {required String dish,
          double calories = 0,
          double protein = 0,
          double carbs = 0,
          double fat = 0}) =>
      Meal(
        id: 0,
        timestamp: at.millisecondsSinceEpoch,
        imagePath: '',
        dish: dish,
        calories: calories,
        protein: protein,
        carbs: carbs,
        fat: fat,
      );

  const longDays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday'
  ];

  testWidgets('previous/next day controls move the date and the totals',
      (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);

    await tester.runAsync(() async {
      await store.addMeal(mealAt(
          DateTime(today.year, today.month, today.day, 12),
          dish: 'Today bowl',
          calories: 500,
          protein: 200,
          carbs: 50,
          fat: 10));
      await store.addMeal(mealAt(
          DateTime(yesterday.year, yesterday.month, yesterday.day, 12),
          dish: 'Yesterday bowl',
          calories: 700,
          protein: 60,
          carbs: 70,
          fat: 20));
    });

    await tallViewport(tester);
    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();

    // Today: only today's meal, and the next-day control is disabled.
    expect(find.text('500 / 2000 kcal'), findsOneWidget);
    expect(find.text('Today bowl'), findsOneWidget);
    expect(find.text('Yesterday bowl'), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('macros-next-day')))
            .onPressed,
        isNull,
        reason: 'next-day must be disabled on today');

    await tester.tap(find.byKey(const ValueKey('macros-prev-day')));
    await tester.pumpAndSettle();

    // Yesterday: the header, the totals and the meal list all moved.
    expect(find.text(formatDate(yesterday.millisecondsSinceEpoch)),
        findsOneWidget);
    expect(find.text('700 / 2000 kcal'), findsOneWidget);
    expect(find.text('Yesterday bowl'), findsOneWidget);
    expect(find.text('Today bowl'), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('macros-next-day')))
            .onPressed,
        isNotNull,
        reason: 'next-day is enabled once a past day is selected');

    await tester.tap(find.byKey(const ValueKey('macros-next-day')));
    await tester.pumpAndSettle();
    expect(find.text('500 / 2000 kcal'), findsOneWidget);
    expect(find.text('Today bowl'), findsOneWidget);
  });

  testWidgets('week navigation stops at the current week and moves the day',
      (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastWeek = DateTime(now.year, now.month, now.day - 7);

    await tester.runAsync(() async {
      await store.addMeal(mealAt(
          DateTime(today.year, today.month, today.day, 12),
          dish: 'Today bowl',
          calories: 500));
      await store.addMeal(mealAt(
          DateTime(lastWeek.year, lastWeek.month, lastWeek.day, 12),
          dish: 'Last week bowl',
          calories: 900));
    });

    await tallViewport(tester);
    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('macros-next-week')))
            .onPressed,
        isNull,
        reason: 'next-week must be disabled on the current week');

    await tester.tap(find.byKey(const ValueKey('macros-prev-week')));
    await tester.pumpAndSettle();

    expect(
        find.text(formatDate(lastWeek.millisecondsSinceEpoch)), findsOneWidget);
    expect(find.text('900 / 2000 kcal'), findsOneWidget);
    expect(find.text('Last week bowl'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('macros-next-week')))
            .onPressed,
        isNotNull);
  });

  testWidgets(
      'metric switch changes the weekly numbers and every bar has a semantic '
      'label with day, value and over/under', (tester) async {
    final handle = tester.ensureSemantics();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    await tester.runAsync(() async {
      // 500 kcal is under the 2000 goal; 200 g protein is over the 150 goal.
      await store.addMeal(mealAt(
          DateTime(today.year, today.month, today.day, 12),
          dish: 'Today bowl',
          calories: 500,
          protein: 200));
    });

    await tallViewport(tester);
    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();

    expect(find.text('0 over · 1 under · 6 not logged'), findsOneWidget);
    expect(
        find.bySemanticsLabel('Weekly Calories chart, 7 days, '
            'goal 2000 kcal per day'),
        findsOneWidget);
    expect(
        find.bySemanticsLabel(
            '${longDays[today.weekday - 1]}: 500 kcal, 1500 under goal'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('macros-metric-protein')));
    await tester.pumpAndSettle();

    expect(find.text('1 over · 0 under · 6 not logged'), findsOneWidget);
    expect(
        find.bySemanticsLabel('Weekly Protein chart, 7 days, '
            'goal 150 g per day'),
        findsOneWidget);
    expect(
        find.bySemanticsLabel(
            '${longDays[today.weekday - 1]}: 200 g, 50 over goal'),
        findsOneWidget);

    handle.dispose();
  });
}
