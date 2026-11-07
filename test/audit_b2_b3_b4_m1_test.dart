import 'dart:convert';

import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/domain.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/mind.dart';
import 'package:compounder/ui/summary.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression tests for the four user-visible defects in
/// review/baseline-audit.md (task 2081aa70):
///
///  * B2 — `getNetWorthHistory` summed gross balances, so a Debt account
///    *increased* reported net worth.
///  * B3 — the thought-record Save button was evaluated once inside the
///    dialog builder and could never enable.
///  * B4 — a completed set with reps = 0 crashed the workout summary through
///    `epley`'s `reps must be at least 1` guard.
///  * M1 — a malformed `foods_json` row made `AppStore.open` throw, so the
///    app could not launch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dbPath;
  late AppStore store;

  // The store is opened here, outside the widget tests' fake-async zone:
  // sqflite_common_ffi does real I/O that a testWidgets body cannot await.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dbPath = '${await databaseFactory.getDatabasesPath()}/audit_b2_b3_b4_m1.db';
    await databaseFactory.deleteDatabase(dbPath);
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: dbPath);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  group('B2 net-worth history subtracts liabilities', () {
    test('a Debt account lowers the reported monthly net worth', () async {
      // 1000 asset + 400 debt: gross 1400, true net worth 600.
      await store.saveAccount(Account(
        id: 0,
        name: 'Savings',
        type: 'Bank',
        balance: 1000,
        updatedAt: 0,
      ));
      await store.saveAccount(Account(
        id: 0,
        name: 'Card',
        type: 'Debt',
        balance: 400,
        updatedAt: 0,
      ));

      final raw = await NetWorthHistoryTool(store).run(const {});
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      final points = (decoded['points'] as List).cast<Map<String, Object?>>();

      expect(points, isNotEmpty);
      expect(points.last['netWorth'], '600',
          reason: 'debt must be subtracted, not added to gross assets');
    });
  });

  group('B3 thought-record Save button', () {
    testWidgets('Save enables after typing a thought', (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: MaterialApp(
            theme: CompounderTheme.light(),
            home: ShellNav(
              openDrawer: () {},
              child: const Scaffold(body: MindTab()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The Mind tab is a long ListView; the button is below the fold and is
      // not built until scrolled into view.
      await tester.scrollUntilVisible(
        find.text('New thought record'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('New thought record'));
      await tester.pumpAndSettle();

      FilledButton saveButton() => tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));

      expect(saveButton().onPressed, isNull,
          reason: 'Save must start disabled with an empty thought field');

      await tester.enterText(
        find.widgetWithText(TextField, 'What did you tell yourself?'),
        'I always mess this up',
      );
      await tester.pump();

      expect(saveButton().onPressed, isNotNull,
          reason: 'Save must enable once the thought field has content');
    });
  });

  group('B4 zero-rep sets', () {
    test('e1rmMaxOf ignores zero-rep entries instead of throwing', () {
      expect(e1rmMaxOf([(100, 0)]), 0);
      expect(e1rmMaxOf([(100, 0), (80, 5)]), closeTo(93.33, 0.01));
    });

    test('sessionPoints drops zero-rep sets', () {
      final points = sessionPoints([
        (workoutId: 1, date: 100, weightKg: 100, reps: 0, isWarmup: false),
        (workoutId: 2, date: 200, weightKg: 80, reps: 5, isWarmup: false),
      ]);
      expect(points.length, 1);
      expect(points.single.workoutId, 2);
    });

    testWidgets('summary renders with a completed 0-rep set', (tester) async {
      // Seeding touches sqflite_common_ffi, which needs real async time; a
      // testWidgets body runs in a fake-async zone.
      late int workoutId;
      await tester.runAsync(() async {
        // workoutDetail() skips entries whose exercise row is missing, so the
        // exercise must exist for the summary to reach the e1RM math.
        final exerciseId = await store.db.insert('exercises', {
          'name': 'Back squat',
          'muscle_group': 'Legs',
          'equipment': 'Barbell',
          'is_custom': 0,
        });
        workoutId = await store.db.insert('workouts', {
          'name': 'Leg day',
          'started_at': 1000,
          'ended_at': 2000,
        });
        final entryId = await store.db.insert('workout_exercises', {
          'workout_id': workoutId,
          'exercise_id': exerciseId,
          'position': 0,
        });
        await store.db.insert('workout_sets', {
          'workout_exercise_id': entryId,
          'position': 0,
          'weight_kg': 100.0,
          'reps': 0,
          'completed_at': 1500,
          'is_warmup': 0,
        });
        await store.refreshAll();
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: MaterialApp(
            theme: CompounderTheme.light(),
            home: SummaryScreen(workoutId),
          ),
        ),
      );
      // The summary's FutureBuilder hits sqflite_common_ffi, which needs real
      // async time to complete.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'a 0-rep completed set must not crash the summary');
      expect(find.text('Best e1RM (kg)'), findsOneWidget);
      expect(find.text('Total reps'), findsOneWidget);
    });
  });

  group('M1 malformed foods_json', () {
    test('AppStore.open survives a malformed foods_json row', () async {
      await store.db.insert('meals', {
        'timestamp': 1000,
        'image_path': '',
        'dish': 'Toast',
        'calories': 200.0,
        'protein': 5.0,
        'carbs': 30.0,
        'fat': 4.0,
        'foods_json': 'not json at all',
        'is_auto': 0,
      });
      await store.db.close();

      // Before the fix this threw FormatException out of refreshAll().
      final reopened = await AppStore.open(
          await SharedPreferences.getInstance(),
          path: dbPath);
      // tearDown closes `store`, which is already closed here; reopen it so the
      // teardown has a live handle.
      store = reopened;

      expect(reopened.meals, hasLength(1));
      expect(reopened.meals.single.dish, 'Toast');
      expect(reopened.meals.single.foods, isEmpty,
          reason: 'an undecodable breakdown degrades to no foods');
    });
  });
}
