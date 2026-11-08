import 'package:compounder/data/store.dart';
import 'package:compounder/ui/summary.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature 3 (owner request): past workout summaries must expose the sets and
/// reps behind an expand/collapse control, collapsed by default.
///
/// The seeded workout is deliberately awkward:
///  * set 1 — 100 kg x 5, completed, working set;
///  * set 2 — 60 kg x 8, completed, warm-up;
///  * set 3 — 0 kg x 0, never completed (a placeholder the user left behind).
///
/// The placeholder must be listed but never read as performed work, and the
/// zero-rep set must not crash the summary (audit B4).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dbPath;
  late AppStore store;
  late int workoutId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dbPath = '${await databaseFactory.getDatabasesPath()}/summary_expand.db';
    await databaseFactory.deleteDatabase(dbPath);
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: dbPath);

    final squatId = await store.db.insert('exercises', {
      'name': 'Back squat',
      'muscle_group': 'Legs',
      'equipment': 'Barbell',
      'is_custom': 0,
    });
    final benchId = await store.db.insert('exercises', {
      'name': 'Bench press',
      'muscle_group': 'Chest',
      'equipment': 'Barbell',
      'is_custom': 0,
    });
    workoutId = await store.db.insert('workouts', {
      'name': 'Leg day',
      'started_at': 1000,
      'ended_at': 2000,
    });
    final squatEntry = await store.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': squatId,
      'position': 0,
    });
    final benchEntry = await store.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': benchId,
      'position': 1,
    });
    await store.db.insert('workout_sets', {
      'workout_exercise_id': squatEntry,
      'position': 0,
      'weight_kg': 100.0,
      'reps': 5,
      'completed_at': 1500,
      'is_warmup': 0,
    });
    await store.db.insert('workout_sets', {
      'workout_exercise_id': squatEntry,
      'position': 1,
      'weight_kg': 60.0,
      'reps': 8,
      'completed_at': 1600,
      'is_warmup': 1,
    });
    await store.db.insert('workout_sets', {
      'workout_exercise_id': squatEntry,
      'position': 2,
      'weight_kg': 0.0,
      'reps': 0,
      'completed_at': null,
      'is_warmup': 0,
    });
    await store.db.insert('workout_sets', {
      'workout_exercise_id': benchEntry,
      'position': 0,
      'weight_kg': 80.0,
      'reps': 5,
      'completed_at': 1700,
      'is_warmup': 0,
    });
    await store.refreshAll();
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  Future<void> pumpSummary(WidgetTester tester) async {
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
  }

  testWidgets('sets are collapsed by default and expand on demand',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpSummary(tester);

    // Collapsed: no set rows, no warm-up marker.
    expect(find.text('100 kg × 5 reps'), findsNothing,
        reason: 'set detail must be hidden until the user expands it');
    expect(find.text('60 kg × 8 reps'), findsNothing);
    expect(find.text('Warm-up'), findsNothing);

    // The aggregate row and the totals are unchanged by this feature.
    expect(find.text('Legs · 1 sets · 5 reps'), findsOneWidget);
    expect(find.text('Total volume (kg)'), findsOneWidget);
    expect(find.text('Best e1RM (kg)'), findsOneWidget);
    expect(find.text('Working sets'), findsOneWidget);
    expect(find.text('Total reps'), findsOneWidget);
    expect(find.text('Delete workout'), findsOneWidget);

    // The expand control names the exercise and its state.
    final expand = find.bySemanticsLabel('Expand sets for Back squat');
    expect(expand, findsOneWidget,
        reason: 'the control needs a semantic label naming the exercise');
    await tester.ensureVisible(expand);
    await tester.pumpAndSettle();
    await tester.tap(expand);
    await tester.pumpAndSettle();

    // Expanded: every set is listed in position order with measured values.
    expect(find.text('100 kg × 5 reps'), findsOneWidget);
    expect(find.text('60 kg × 8 reps'), findsOneWidget);
    expect(find.text('Warm-up'), findsOneWidget,
        reason: 'the warm-up set must be marked');
    expect(find.text('Completed'), findsNWidgets(2),
        reason: 'both completed sets must be marked as performed');
    expect(find.text('Not completed'), findsOneWidget,
        reason: 'the 0 kg x 0 placeholder must not read as performed work');
    expect(find.text('0 kg × 0 reps'), findsOneWidget,
        reason: 'a zero-rep set is still listed (audit B4)');
    expect(tester.takeException(), isNull);

    // The control now reports the collapsed state.
    expect(find.bySemanticsLabel('Collapse sets for Back squat'), findsOneWidget);

    // Collapsing hides the rows again.
    await tester.tap(find.bySemanticsLabel('Collapse sets for Back squat'));
    await tester.pumpAndSettle();
    expect(find.text('100 kg × 5 reps'), findsNothing);

    semantics.dispose();
  });

  testWidgets('expansion survives a rebuild and is per exercise',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpSummary(tester);

    final expandSquat = find.bySemanticsLabel('Expand sets for Back squat');
    await tester.ensureVisible(expandSquat);
    await tester.pumpAndSettle();
    await tester.tap(expandSquat);
    await tester.pumpAndSettle();
    expect(find.text('100 kg × 5 reps'), findsOneWidget);

    // A store notification rebuilds the screen (the FutureBuilder re-emits).
    store.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('100 kg × 5 reps'), findsOneWidget,
        reason: 'expansion state must survive a rebuild');

    // Expanding a second exercise must not collapse the first.
    final expandBench = find.bySemanticsLabel('Expand sets for Bench press');
    await tester.ensureVisible(expandBench);
    await tester.pumpAndSettle();
    await tester.tap(expandBench);
    await tester.pumpAndSettle();
    expect(find.text('80 kg × 5 reps'), findsOneWidget);
    expect(find.text('100 kg × 5 reps'), findsOneWidget,
        reason: 'expanding another exercise must not reset the first');

    semantics.dispose();
  });
}
