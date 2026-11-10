import 'dart:io';

import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/domain.dart';
import 'package:compounder/services/rest_sounds.dart';
import 'package:compounder/ui/summary.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:compounder/ui/workout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Bodyweight (0 kg) personal records (owner request): a bodyweight exercise
/// has no weight to log, so its record is the rep count. 0 kg x 10 in one
/// session is a PR, and 0 kg x 12 in a later session is a new PR. Repeats and
/// lower reps are not. Weighted sets keep the e1RM rule untouched, and a 0 kg
/// set can never fake an e1RM PR because it is compared against bodyweight
/// history only.

double _e1rm(double weightKg, int reps) => formatE1rm(epley(weightKg, reps));

class _FakeWorkoutSounds implements WorkoutSounds {
  final List<WorkoutCue> played = [];

  @override
  Future<void> play(WorkoutCue cue) async {
    played.add(cue);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('assessPr bodyweight branch', () {
    test('0x10 as the first-ever bodyweight set is a baseline rep PR', () {
      final result = assessPr(
        weightKg: 0,
        reps: 10,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(result.isPr, isTrue);
      expect(result.prReps, 10);
      expect(result.e1rmKg, isNull,
          reason: 'a 0 kg set must never store an e1RM snapshot');
      expect(result.previousBestReps, 0);
    });

    test('0x12 beats a prior-session bodyweight best of 10 reps', () {
      final result = assessPr(
        weightKg: 0,
        reps: 12,
        isWarmup: false,
        priorBestKg: 0,
        priorBestReps: 10,
        earlierSets: const [],
      );
      expect(result.isPr, isTrue);
      expect(result.prReps, 12);
      expect(result.previousBestReps, 10);
    });

    test('repeating the prior-session best is not a PR', () {
      final result = assessPr(
        weightKg: 0,
        reps: 10,
        isWarmup: false,
        priorBestKg: 0,
        priorBestReps: 10,
        earlierSets: const [],
      );
      expect(result.isPr, isFalse,
          reason: 'a rep PR must strictly exceed the previous best');
      expect(result.prReps, isNull);
    });

    test('fewer reps than the prior-session best is not a PR', () {
      final result = assessPr(
        weightKg: 0,
        reps: 8,
        isWarmup: false,
        priorBestKg: 0,
        priorBestReps: 10,
        earlierSets: const [],
      );
      expect(result.isPr, isFalse);
    });

    test('a bodyweight warm-up never qualifies, however many reps', () {
      final result = assessPr(
        weightKg: 0,
        reps: 20,
        isWarmup: true,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(result.isPr, isFalse);
    });

    test('a zero-rep bodyweight set never qualifies', () {
      final result = assessPr(
        weightKg: 0,
        reps: 0,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(result.isPr, isFalse);
    });

    test('same-session bodyweight progression flags only the rep leader', () {
      final first = assessPr(
        weightKg: 0,
        reps: 10,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(first.isPr, isTrue);

      final second = assessPr(
        weightKg: 0,
        reps: 12,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [(0.0, 10)],
      );
      expect(second.isPr, isTrue, reason: '12 reps beats the earlier 10');

      final third = assessPr(
        weightKg: 0,
        reps: 10,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [(0.0, 10), (0.0, 12)],
      );
      expect(third.isPr, isFalse,
          reason: 'a set below the session rep best is not a PR');
    });

    test('weighted sets in the session do not set the bodyweight baseline', () {
      // A 100 kg x 5 set earlier in the session must not suppress a 0 kg x 10
      // rep PR: the two records are measured on different scales.
      final result = assessPr(
        weightKg: 0,
        reps: 10,
        isWarmup: false,
        priorBestKg: _e1rm(100, 5),
        earlierSets: const [(100.0, 5)],
      );
      expect(result.isPr, isTrue);
      expect(result.prReps, 10);
    });

    test('a 0 kg set never claims an e1RM PR', () {
      // Prior weighted history exists, but the bodyweight branch ignores it and
      // stores reps, never an e1RM.
      final result = assessPr(
        weightKg: 0,
        reps: 30,
        isWarmup: false,
        priorBestKg: _e1rm(200, 5),
        earlierSets: const [],
      );
      expect(result.isPr, isTrue);
      expect(result.e1rmKg, isNull);
      expect(result.prReps, 30);
    });

    test('weighted PR behaviour is unchanged', () {
      final result = assessPr(
        weightKg: 110,
        reps: 5,
        isWarmup: false,
        priorBestKg: _e1rm(100, 5),
        earlierSets: const [],
      );
      expect(result.isPr, isTrue);
      expect(result.e1rmKg, _e1rm(110, 5));
      expect(result.prReps, isNull,
          reason: 'a weighted PR carries an e1RM, not a rep snapshot');
    });
  });

  group('store bodyweight PR detection and persistence', () {
    late String path;
    late Directory tmp;
    late AppStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('compounder_bw_pr_store');
      path = p.join(tmp.path, 'bw_pr.db');
      databaseFactory = databaseFactoryFfi;
      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: path);
    });

    tearDown(() async {
      await store.db.close();
      await databaseFactory.deleteDatabase(path);
      await tmp.delete(recursive: true);
    });

    Future<int> seedExercise({
      double? priorWeightKg,
      int priorReps = 5,
      String name = 'Pull-up',
    }) async {
      final exerciseId = await store.db.insert('exercises', {
        'name': name,
        'muscle_group': 'Back',
        'equipment': 'Bodyweight',
        'is_custom': 0,
      });
      if (priorWeightKg != null) {
        final workoutId = await store.db.insert('workouts', {
          'name': 'Prior session',
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
          'weight_kg': priorWeightKg,
          'reps': priorReps,
          'completed_at': 1500,
          'is_warmup': 0,
        });
      }
      return exerciseId;
    }

    Future<({int workoutId, int entryId})> seedActive(int exerciseId) async {
      final workoutId = await store.db.insert('workouts', {
        'name': 'Session',
        'started_at': DateTime.now().millisecondsSinceEpoch,
        'ended_at': null,
      });
      final entryId = await store.db.insert('workout_exercises', {
        'workout_id': workoutId,
        'exercise_id': exerciseId,
        'position': 0,
      });
      return (workoutId: workoutId, entryId: entryId);
    }

    Future<WorkoutSet> setById(int id) async {
      final rows = await store.db
          .query('workout_sets', where: 'id = ?', whereArgs: [id]);
      return WorkoutSet.fromMap(rows.single);
    }

    test('0x10 as the first bodyweight set flags a rep PR', () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 0, 10);
      final set = await setById(setId);
      expect(set.isPr, isTrue);
      expect(set.prReps, 10);
      expect(set.prE1rmKg, isNull,
          reason: 'the rep PR must not store a 0 kg e1RM');
    });

    test('0x12 in a later session is a new PR', () async {
      final exerciseId = await seedExercise(priorWeightKg: 0, priorReps: 10);
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 0, 12);
      final set = await setById(setId);
      expect(set.isPr, isTrue);
      expect(set.prReps, 12);
      expect(set.prE1rmKg, isNull);
    });

    test('repeating 0x10 does not flag', () async {
      final exerciseId = await seedExercise(priorWeightKg: 0, priorReps: 10);
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 0, 10);
      final set = await setById(setId);
      expect(set.isPr, isFalse);
      expect(set.prReps, isNull);
    });

    test('0x8 does not flag', () async {
      final exerciseId = await seedExercise(priorWeightKg: 0, priorReps: 10);
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 0, 8);
      expect((await setById(setId)).isPr, isFalse);
    });

    test('a 0x20 warm-up does not flag', () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 0, 20, warmup: true);
      final set = await setById(setId);
      expect(set.isPr, isFalse);
      expect(set.prReps, isNull);
    });

    test('weighted PRs still store an e1RM and no rep snapshot', () async {
      final exerciseId =
          await seedExercise(priorWeightKg: 100, name: 'Back squat');
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 110, 5);
      final set = await setById(setId);
      expect(set.isPr, isTrue);
      expect(set.prE1rmKg, _e1rm(110, 5));
      expect(set.prReps, isNull);
    });

    test('editing a bodyweight set re-derives the later flags', () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final first = await store.addSet(active.entryId, 0, 10);
      final second = await store.addSet(active.entryId, 0, 12);
      expect((await setById(first)).isPr, isTrue);
      expect((await setById(second)).isPr, isTrue);

      // Raising the first set above the second must demote the second.
      await store.updateSet(first, reps: 15);
      final firstAfter = await setById(first);
      final secondAfter = await setById(second);
      expect(firstAfter.isPr, isTrue);
      expect(firstAfter.prReps, 15);
      expect(secondAfter.isPr, isFalse,
          reason: '12 reps no longer beats the earlier 15');
      expect(secondAfter.prReps, isNull);
    });

    test('deleting a bodyweight set re-derives the remaining flags', () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final first = await store.addSet(active.entryId, 0, 10);
      final second = await store.addSet(active.entryId, 0, 12);
      expect((await setById(second)).isPr, isTrue);

      await store.deleteSetRow(first);
      final secondAfter = await setById(second);
      expect(secondAfter.isPr, isTrue,
          reason: '12 reps is now the session leader and beats no prior best');
      expect(secondAfter.prReps, 12);
    });

    test('the same exercise twice in one session shares one rep baseline',
        () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final first = await store.addSet(active.entryId, 0, 10);
      final secondEntry = await store.db.insert('workout_exercises', {
        'workout_id': active.workoutId,
        'exercise_id': exerciseId,
        'position': 1,
      });
      final repeat = await store.addSet(secondEntry, 0, 10);
      expect((await setById(first)).isPr, isTrue);
      expect((await setById(repeat)).isPr, isFalse,
          reason: '10 reps was already performed earlier in the session');

      await store.finishWorkout(active.workoutId);
      final row =
          store.history.firstWhere((r) => r.workoutId == active.workoutId);
      expect(row.prCount, 1,
          reason: 'the duplicate entry must not inflate the PR count');
    });

    test('prSummary reports a bodyweight PR as reps', () async {
      final exerciseId = await seedExercise(priorWeightKg: 0, priorReps: 10);
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 0, 12);

      final prs = await store.prSummary(active.workoutId);
      expect(prs, hasLength(1));
      expect(prs.single.exerciseName, 'Pull-up');
      expect(prs.single.isRepBased, isTrue);
      expect(prs.single.previousBestReps, 10);
      expect(prs.single.newBestReps, 12);
      expect(prs.single.deltaReps, 2);
      expect(prs.single.isBaseline, isFalse);
      expect(prs.single.newBestKg, 0, reason: 'a rep PR carries no e1RM value');
    });

    test('prSummary marks a first bodyweight session as a baseline', () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 0, 10);
      final prs = await store.prSummary(active.workoutId);
      expect(prs, hasLength(1));
      expect(prs.single.isRepBased, isTrue);
      expect(prs.single.isBaseline, isTrue);
      expect(prs.single.previousBestReps, 0);
      expect(prs.single.newBestReps, 10);
    });

    test('prSummary keeps weighted PRs on the e1RM shape', () async {
      final exerciseId =
          await seedExercise(priorWeightKg: 90, name: 'Back squat');
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 110, 5);
      final prs = await store.prSummary(active.workoutId);
      expect(prs, hasLength(1));
      expect(prs.single.isRepBased, isFalse);
      expect(prs.single.previousBestKg, _e1rm(90, 5));
      expect(prs.single.newBestKg, _e1rm(110, 5));
    });

    test('progressFor drops bodyweight-only sessions from the e1RM chart',
        () async {
      final exerciseId = await seedExercise();
      // Two finished bodyweight-only sessions: no e1RM signal at all.
      for (final reps in [10, 12]) {
        final session = await seedActive(exerciseId);
        await store.addSet(session.entryId, 0, reps);
        await store.finishWorkout(session.workoutId);
      }
      expect(await store.progressFor(exerciseId), isEmpty,
          reason: 'a flat 0 kg e1RM line must not be plotted');

      // A weighted session does produce a point, and the bodyweight-only
      // sessions stay out of the series.
      final weighted = await seedActive(exerciseId);
      await store.addSet(weighted.entryId, 20, 5);
      await store.finishWorkout(weighted.workoutId);
      final points = await store.progressFor(exerciseId);
      expect(points, hasLength(1));
      expect(points.single.valueKg, _e1rm(20, 5));
    });

    test('migration 13 -> 14 adds pr_reps without false PRs', () async {
      final exerciseId =
          await seedExercise(priorWeightKg: 100, name: 'Back squat');
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 120, 5);
      // A bodyweight set in the same session: v13 never flagged these.
      final bwEntry = await store.db.insert('workout_exercises', {
        'workout_id': active.workoutId,
        'exercise_id': exerciseId,
        'position': 1,
      });
      await store.addSet(bwEntry, 0, 10);
      await store.finishWorkout(active.workoutId);

      // Rewind to a genuine v13 shape: no pr_reps column, and the bodyweight
      // row unflagged exactly as v13 left it.
      await store.db.execute('ALTER TABLE workout_sets DROP COLUMN pr_reps');
      await store.db
          .execute('UPDATE workout_sets SET is_pr = 0 WHERE weight_kg = 0');
      await store.db.setVersion(13);
      await store.db.close();

      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: path);
      expect(await store.db.getVersion(), 14);

      final sets = await store.db.query('workout_sets');
      expect(sets, hasLength(3), reason: 'every set must survive the upgrade');
      for (final set in sets) {
        expect(set['pr_reps'], isNull,
            reason: 'a migrated row must never gain a rep snapshot');
      }
      final weighted = sets.firstWhere((s) => s['weight_kg'] == 120.0);
      expect(weighted['is_pr'], 1,
          reason: 'the existing weighted PR flag must be preserved');
      expect(weighted['pr_e1rm_kg'], _e1rm(120, 5));
      final bodyweight = sets.firstWhere((s) => s['weight_kg'] == 0.0);
      expect(bodyweight['is_pr'], 0,
          reason: 'the migration must not retro-flag bodyweight history');
      expect(bodyweight['reps'], 10);

      // Idempotent: re-running the 13 -> 14 step on a database that already
      // has the column must not throw or change anything.
      await store.db.setVersion(13);
      await store.db.close();
      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: path);
      expect(await store.db.getVersion(), 14);
      final again = await store.db.query('workout_sets');
      expect(again, hasLength(3));
      expect(again.firstWhere((s) => s['weight_kg'] == 120.0)['is_pr'], 1);
      expect(again.firstWhere((s) => s['weight_kg'] == 0.0)['is_pr'], 0);
    });
  });

  group('e1RM chart points', () {
    test('sessionPoints drops sessions whose best e1RM is 0', () {
      final points = sessionPoints([
        (workoutId: 1, date: 100, weightKg: 0, reps: 10, isWarmup: false),
        (workoutId: 2, date: 200, weightKg: 0, reps: 12, isWarmup: false),
        (workoutId: 3, date: 300, weightKg: 20, reps: 5, isWarmup: false),
      ]);
      expect(points, hasLength(1));
      expect(points.single.workoutId, 3);
    });
  });

  group('summary surface: bodyweight PRs render as reps', () {
    late AppStore store;
    late int workoutId;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'unit': 'kg'});
      databaseFactory = databaseFactoryFfiNoIsolate;
      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: inMemoryDatabasePath);
    });

    tearDown(() async {
      await store.db.close();
    });

    Future<void> seedSession({
      required int priorReps,
      required int newReps,
      bool withPrior = true,
    }) async {
      final exerciseId = await store.db.insert('exercises', {
        'name': 'Pull-up',
        'muscle_group': 'Back',
        'equipment': 'Bodyweight',
        'is_custom': 0,
      });
      if (withPrior) {
        final priorWorkout = await store.db.insert('workouts', {
          'name': 'Prior session',
          'started_at': 1000,
          'ended_at': 2000,
        });
        final priorEntry = await store.db.insert('workout_exercises', {
          'workout_id': priorWorkout,
          'exercise_id': exerciseId,
          'position': 0,
        });
        await store.db.insert('workout_sets', {
          'workout_exercise_id': priorEntry,
          'position': 0,
          'weight_kg': 0.0,
          'reps': priorReps,
          'completed_at': 1500,
          'is_warmup': 0,
        });
      }
      workoutId = await store.db.insert('workouts', {
        'name': 'Session',
        'started_at': 3000,
        'ended_at': 4000,
      });
      final entryId = await store.db.insert('workout_exercises', {
        'workout_id': workoutId,
        'exercise_id': exerciseId,
        'position': 0,
      });
      await store.addSet(entryId, 0, newReps);
      await store.refreshAll();
    }

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
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    testWidgets('the summary lists a bodyweight PR as reps', (tester) async {
      await seedSession(priorReps: 10, newReps: 12);
      await pumpSummary(tester);

      expect(find.text('PERSONAL RECORDS'), findsOneWidget);
      expect(find.text('Previous best 10 reps → new best 12 reps (+2 reps)'),
          findsOneWidget);
    });

    testWidgets('a first bodyweight PR reads as a first PR in reps',
        (tester) async {
      await seedSession(priorReps: 0, newReps: 10, withPrior: false);
      await pumpSummary(tester);

      expect(find.text('First PR · 10 reps'), findsOneWidget);
    });

    testWidgets('the expanded set row names the rep record', (tester) async {
      await seedSession(priorReps: 10, newReps: 12);
      await pumpSummary(tester);

      final expand = find.bySemanticsLabel('Expand sets for Pull-up');
      await tester.ensureVisible(expand);
      await tester.pumpAndSettle();
      await tester.tap(expand);
      await tester.pumpAndSettle();

      expect(find.text('PR'), findsOneWidget);
      expect(
          find.bySemanticsLabel(
              'Set 1, 0 kg × 12 reps, personal record at 12 reps, completed'),
          findsOneWidget);
    });
  });

  group('workout screen: bodyweight PR badge and celebration tone', () {
    late AppStore store;
    late int workoutId;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'unit': 'kg',
        'restSeconds': 120,
        'restSoundsEnabled': true,
      });
      databaseFactory = databaseFactoryFfiNoIsolate;
      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: inMemoryDatabasePath);
      final exerciseId = await store.db.insert('exercises', {
        'name': 'Pull-up',
        'muscle_group': 'Back',
        'equipment': 'Bodyweight',
        'is_custom': 0,
      });
      // A prior finished session at 0 kg x 10 reps, so 12 reps is a new PR.
      final priorWorkout = await store.db.insert('workouts', {
        'name': 'Prior session',
        'started_at': 1000,
        'ended_at': 2000,
      });
      final priorEntry = await store.db.insert('workout_exercises', {
        'workout_id': priorWorkout,
        'exercise_id': exerciseId,
        'position': 0,
      });
      await store.db.insert('workout_sets', {
        'workout_exercise_id': priorEntry,
        'position': 0,
        'weight_kg': 0.0,
        'reps': 10,
        'completed_at': 1500,
        'is_warmup': 0,
      });
      workoutId = await store.db.insert('workouts', {
        'name': 'Session',
        'started_at': DateTime.now().millisecondsSinceEpoch,
        'ended_at': null,
      });
      final entryId = await store.db.insert('workout_exercises', {
        'workout_id': workoutId,
        'exercise_id': exerciseId,
        'position': 0,
      });
      await store.db.insert('workout_sets', {
        'workout_exercise_id': entryId,
        'position': 0,
        'weight_kg': 0.0,
        'reps': 12,
        'completed_at': null,
        'is_warmup': 0,
      });
      await store.refreshAll();
    });

    tearDown(() async {
      await store.db.close();
    });

    testWidgets(
        'completing a bodyweight PR shows the rep badge and plays the '
        'celebration tone', (tester) async {
      final sounds = _FakeWorkoutSounds();
      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.dark(),
          home: WorkoutScreen(workoutId: workoutId, sounds: sounds),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      await tester.pump();
      expect(find.text('Pull-up'), findsOneWidget);
      expect(find.textContaining('PR ·'), findsNothing);

      final checkbox = find.descendant(
          of: find.byTooltip('Mark set complete').first,
          matching: find.byType(Checkbox));
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump();
      await tester.pump();

      expect(sounds.played, contains(WorkoutCue.personalRecord),
          reason: 'a bodyweight rep PR must fire the celebration cue');
      expect(find.text('PR · 12 reps'), findsOneWidget,
          reason: 'the badge must show reps, not a 0 kg e1RM');
    });
  });
}
