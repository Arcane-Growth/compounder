import 'dart:convert';

import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/domain.dart';
import 'package:compounder/ui/summary.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression tests for review F3/F4 on c3d71cd (gate task 3d12239c):
///
///  * F3 — the coach's `addSet` tool passed the model's raw weightKg into the
///    store. A negative weight then reached `epley()` through SummaryScreen and
///    threw "weight must be non-negative" — the same user-visible crash class
///    audit B4 set out to fix.
///  * F4 — `volumeOf` accepted negative reps and produced negative totals.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dbPath;
  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dbPath =
        '${await databaseFactory.getDatabasesPath()}/coach_addset_clamp.db';
    await databaseFactory.deleteDatabase(dbPath);
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: dbPath);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  group('F3 coach addSet clamps negative weight and reps', () {
    test('stores clamped values instead of the model\'s raw numbers', () async {
      await store.db.insert('exercises', {
        'name': 'Back squat',
        'muscle_group': 'Legs',
        'equipment': 'Barbell',
        'is_custom': 0,
      });
      await store.refreshAll();

      final raw = await AddSetTool(store).run(const {
        'exerciseName': 'Back squat',
        'weightKg': -20,
        'reps': -5,
      });
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      expect(decoded['ok'], isTrue);
      expect(decoded['weightKg'], '0',
          reason: 'the tool must report the clamped weight it wrote');
      expect(decoded['reps'], 1,
          reason: 'the tool must report the clamped reps it wrote');

      final workoutId = decoded['workoutId'] as int;
      final detail = await store.workoutDetail(workoutId);
      final set = detail!.exercises.single.sets.single;
      expect(set.weightKg, 0.0,
          reason: 'a negative weight must never reach the store');
      expect(set.reps, 1,
          reason: 'a negative reps value must never reach the store');
      expect(set.completedAt, isNotNull);
    });

    testWidgets('summary renders after a negative-weight addSet',
        (tester) async {
      late int workoutId;
      await tester.runAsync(() async {
        await store.db.insert('exercises', {
          'name': 'Back squat',
          'muscle_group': 'Legs',
          'equipment': 'Barbell',
          'is_custom': 0,
        });
        await store.refreshAll();
        final raw = await AddSetTool(store).run(const {
          'exerciseName': 'Back squat',
          'weightKg': -20,
          'reps': 5,
        });
        workoutId =
            (jsonDecode(raw) as Map<String, Object?>)['workoutId'] as int;
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
          reason: 'a negative-weight set must not crash the summary');
      expect(find.text('Best e1RM (kg)'), findsOneWidget);

      StatCard card(String label) => tester.widget<StatCard>(
          find.byWidgetPredicate((w) => w is StatCard && w.label == label));
      expect(card('Total reps').value, '5');
      expect(card('Working sets').value, '1');
      expect(card('Best e1RM (kg)').value, '0',
          reason: 'a 0 kg set has no e1RM signal');
      expect(card('Total volume (kg)').value, '0');
    });
  });

  group('F3/F4 pure functions ignore negative weight and reps', () {
    test('e1rmMaxOf skips negative weights instead of throwing', () {
      expect(e1rmMaxOf([(-20, 5)]), 0);
      expect(e1rmMaxOf([(-20, 5), (80, 5)]), closeTo(93.33, 0.01),
          reason: 'the valid set must still be scored');
    });

    test('volumeOf skips negative reps and negative weights', () {
      final negativeReps =
          volumeOf([(weightKg: 100.0, reps: -5, isWarmup: false)]);
      expect(negativeReps.totalKg, 0.0);
      expect(negativeReps.reps, 0);
      expect(negativeReps.sets, 0);

      final negativeWeight =
          volumeOf([(weightKg: -20.0, reps: 5, isWarmup: false)]);
      expect(negativeWeight.totalKg, 0.0);
      expect(negativeWeight.reps, 5);
      expect(negativeWeight.sets, 1);

      final mixed = volumeOf([
        (weightKg: 100.0, reps: 5, isWarmup: false),
        (weightKg: 100.0, reps: -5, isWarmup: false),
        (weightKg: 40.0, reps: 8, isWarmup: true),
      ]);
      expect(mixed.totalKg, 500.0);
      expect(mixed.reps, 5);
      expect(mixed.sets, 1);
    });
  });
}
