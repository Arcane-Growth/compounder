import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/macros.dart';
import 'package:compounder/ui/meal_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature 1: manual meal logging and the macro→calorie calculator.
///
/// These are widget-level proofs: the manual path must work with no AI
/// endpoint configured, the calorie readout must track the macros live, and
/// edit mode must show a stored estimate next to the computed value instead of
/// silently replacing it.
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

  Widget host(Widget child) => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(home: child),
      );

  testWidgets(
      'the Log meal sheet offers manual entry and it opens with AI unconfigured',
      (tester) async {
    // No endpoint is configured: the manual path must not depend on it.
    expect(store.ai.configured, isFalse);

    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Log meal'));
    await tester.pumpAndSettle();

    expect(find.text('Take a photo'), findsOneWidget);
    expect(find.text('Choose from gallery'), findsOneWidget);
    expect(find.text('Enter manually'), findsOneWidget);

    await tester.tap(find.text('Enter manually'));
    await tester.pumpAndSettle();

    expect(find.text('Log meal manually'), findsOneWidget);
    expect(find.byType(ManualMealScreen), findsOneWidget);
  });

  testWidgets(
      'typing macros updates the derived calories and saves a photo-less meal',
      (tester) async {
    await tester.pumpWidget(host(Builder(
        builder: (context) => Scaffold(
            body: Center(
                child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ManualMealScreen())),
                    child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Dish'), 'Chicken bowl');
    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), '40');
    await tester.enterText(find.widgetWithText(TextField, 'Carbs g'), '50');
    await tester.enterText(find.widgetWithText(TextField, 'Fat g'), '20');
    await tester.pump();

    // 40*4 + 50*4 + 20*9 = 540
    expect(find.text('540 kcal'), findsOneWidget);

    // Changing one macro recomputes the display: 60*4 + 50*4 + 20*9 = 620.
    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), '60');
    await tester.pump();
    expect(find.text('620 kcal'), findsOneWidget);

    await tester.ensureVisible(find.text('Save meal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save meal'));
    await tester.pumpAndSettle();

    expect(store.meals, hasLength(1));
    final meal = store.meals.single;
    expect(meal.dish, 'Chicken bowl');
    expect(meal.imagePath, '');
    expect(meal.isAuto, isFalse);
    expect(meal.protein, 60);
    expect(meal.carbs, 50);
    expect(meal.fat, 20);
    expect(meal.calories, 620);

    // It lands in today's list, which is the filter MacrosTab applies.
    final now = DateTime.now();
    final startOfDay =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    expect(meal.timestamp >= startOfDay, isTrue);

    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();
    expect(find.text('Chicken bowl'), findsOneWidget);
  });

  testWidgets('a non-numeric macro field does not throw and reads as zero',
      (tester) async {
    await tester.pumpWidget(host(Builder(
        builder: (context) => Scaffold(
            body: Center(
                child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ManualMealScreen())),
                    child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), 'abc');
    await tester.enterText(find.widgetWithText(TextField, 'Carbs g'), '50');
    await tester.enterText(find.widgetWithText(TextField, 'Fat g'), '20');
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 0 + 50*4 + 20*9 = 380
    expect(find.text('380 kcal'), findsOneWidget);
  });

  testWidgets(
      'edit mode shows stored and computed calories, hides the photo block, '
      'and saves the computed value without duplicating the row',
      (tester) async {
    // Real sqflite work must run outside the widget test's fake-async zone.
    await tester.runAsync(() async {
      await store.addMeal(Meal(
        id: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        imagePath: '',
        dish: 'Pizza',
        calories: 620,
        protein: 48,
        carbs: 61,
        fat: 18,
        isAuto: true,
      ));
    });
    final stored = store.meals.single;

    await tester.pumpWidget(host(ReviewScreen.edit(stored)));
    await tester.pumpAndSettle();

    // 48*4 + 61*4 + 18*9 = 598, which disagrees with the stored 620.
    expect(find.text('598 kcal'), findsOneWidget);
    expect(find.text('stored 620 kcal · 4/4/9 gives 598 kcal'), findsOneWidget);

    // Calories are not an editable field any more.
    expect(find.widgetWithText(TextField, 'kcal'), findsNothing);

    // A manual meal has no photo, so the 240px placeholder block is gone.
    expect(find.byType(MealPhoto), findsNothing);

    // Editing a macro recomputes live: 50*4 + 61*4 + 18*9 = 606.
    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), '50');
    await tester.pump();
    expect(find.text('606 kcal'), findsOneWidget);
    expect(find.text('stored 620 kcal · 4/4/9 gives 606 kcal'), findsOneWidget);

    await tester.ensureVisible(find.text('Save changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(store.meals, hasLength(1));
    expect(store.meals.single.calories, 606);
    expect(store.meals.single.protein, 50);
  });
}
