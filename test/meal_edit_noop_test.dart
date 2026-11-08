import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/ui/macros.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression guards for the edit-mode data-loss blocker (review BLOCKER-1 on
/// the three-feature batch): opening a saved meal and saving it untouched must
/// leave the stored row byte-identical, including a coach-logged estimate whose
/// macros do not explain its calories.
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

  /// Seeds one saved meal and returns it with its real row id.
  Future<Meal> seed(WidgetTester tester, Meal meal) async {
    await tester.runAsync(() => store.addMeal(meal));
    return store.meals.single;
  }

  Meal coachMeal() => Meal(
        id: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        imagePath: '',
        dish: 'Coach lunch',
        calories: 600,
        protein: 0,
        carbs: 0,
        fat: 0,
        isAuto: true,
      );

  testWidgets(
      'a no-op save keeps a coach-logged 600 kcal / 0-0-0 meal intact',
      (tester) async {
    final stored = await seed(tester, coachMeal());
    expect(stored.calories, 600);

    await tester.pumpWidget(host(ReviewScreen.edit(stored)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    // One row, not a duplicate, and the stored nutrition is untouched.
    expect(store.meals, hasLength(1));
    final meal = store.meals.single;
    expect(meal.id, stored.id);
    expect(meal.calories, 600);
    expect(meal.protein, 0);
    expect(meal.carbs, 0);
    expect(meal.fat, 0);
    expect(meal.dish, 'Coach lunch');
  });

  testWidgets(
      'the stored-vs-computed disclosure renders for the 600 kcal / 0 macros '
      'case and says the stored figure survives', (tester) async {
    final stored = await seed(tester, coachMeal());

    await tester.pumpWidget(host(ReviewScreen.edit(stored)));
    await tester.pumpAndSettle();

    // 0/0/0 macros imply 0 kcal; the stored 600 kcal is disclosed next to it.
    expect(find.text('0 kcal'), findsOneWidget);
    expect(find.text('stored 600 kcal · 4/4/9 gives 0 kcal'), findsOneWidget);
    expect(
        find.text('Macros unchanged — saving keeps the stored 600 kcal.'),
        findsOneWidget);
  });

  testWidgets(
      'a no-op save preserves fractional macros and the stored estimate '
      'exactly', (tester) async {
    final stored = await seed(
        tester,
        Meal(
          id: 0,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          imagePath: '',
          dish: 'Weighed bowl',
          calories: 620.4,
          protein: 32.4,
          carbs: 12.6,
          fat: 8.2,
          isAuto: true,
        ));

    await tester.pumpWidget(host(ReviewScreen.edit(stored)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final meal = store.meals.single;
    // 32.4 g used to be pre-filled as "32" and saved back as 32.
    expect(meal.protein, 32.4);
    expect(meal.carbs, 12.6);
    expect(meal.fat, 8.2);
    expect(meal.calories, 620.4);
  });

  testWidgets(
      'editing a macro does recompute calories from the edited macros',
      (tester) async {
    final stored = await seed(tester, coachMeal());

    await tester.pumpWidget(host(ReviewScreen.edit(stored)));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), '30');
    await tester.pump();
    // 30*4 = 120 kcal, and the "keeps the stored" line is gone because the
    // macros were edited.
    expect(find.text('120 kcal'), findsOneWidget);
    expect(
        find.text('Macros unchanged — saving keeps the stored 600 kcal.'),
        findsNothing);

    await tester.ensureVisible(find.text('Save changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final meal = store.meals.single;
    expect(meal.calories, 120);
    expect(meal.protein, 30);
    expect(meal.carbs, 0);
    expect(meal.fat, 0);
  });
}
