import 'dart:convert';
import 'dart:io';

import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/domain.dart';
import 'package:compounder/services/backup.dart';
import 'package:compounder/services/rest_sounds.dart';
import 'package:compounder/ui/history.dart';
import 'package:compounder/ui/summary.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:compounder/ui/workout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Personal records (owner request): detect a PR when a set is completed,
/// celebrate it with a tone and a badge, show the PRs in the session summary
/// and surface them in workout history.
///
/// PR definition is the owner's: theoretical 1RM (e1RM), compared against the
/// best e1RM across prior finished sessions and every earlier set in the same
/// session. The first-ever set for an exercise is the baseline and counts as a
/// PR. Zero-rep sets never qualify (audit B4).

/// The e1RM values the tests pin, computed with the shipped formula
/// (`epley` + `formatE1rm`) rather than hard-coded independently.
double _e1rm(double weightKg, int reps) => formatE1rm(epley(weightKg, reps));

class _FakeWorkoutSounds implements WorkoutSounds {
  final List<WorkoutCue> played = [];
  bool disposed = false;

  @override
  Future<void> play(WorkoutCue cue) async {
    played.add(cue);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// A store whose PR query fails, so the summary's error path can be exercised
/// without corrupting a real database.
class _FailingPrStore extends ChangeNotifier implements AppStore {
  @override
  Future<WorkoutDetail?> workoutDetail(int id) async => const WorkoutDetail(
        Workout(id: 1, name: 'Leg day', startedAt: 0, endedAt: 1),
        <ExerciseView>[],
      );

  @override
  Future<List<PrSummary>> prSummary(int id) async =>
      throw Exception('database_closed: the database is closed');

  @override
  WeightUnit get unit => WeightUnit.kg;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('assessPr (detection rule)', () {
    test('the first-ever set for an exercise is a baseline PR', () {
      final result = assessPr(
        weightKg: 100,
        reps: 5,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(result.isPr, isTrue,
          reason: 'no history means the first set establishes the baseline');
      expect(result.e1rmKg, _e1rm(100, 5));
      expect(result.previousBestKg, 0);
    });

    test('beating the prior-session best is a PR', () {
      final result = assessPr(
        weightKg: 110,
        reps: 5,
        isWarmup: false,
        priorBestKg: _e1rm(100, 5),
        earlierSets: const [],
      );
      expect(result.isPr, isTrue);
      expect(result.e1rmKg, _e1rm(110, 5));
      expect(result.previousBestKg, _e1rm(100, 5));
    });

    test('matching the prior-session best is not a PR', () {
      final result = assessPr(
        weightKg: 100,
        reps: 5,
        isWarmup: false,
        priorBestKg: _e1rm(100, 5),
        earlierSets: const [],
      );
      expect(result.isPr, isFalse,
          reason: 'a PR must strictly exceed the previous best');
      expect(result.e1rmKg, isNull);
    });

    test('falling short of the prior-session best is not a PR', () {
      final result = assessPr(
        weightKg: 95,
        reps: 5,
        isWarmup: false,
        priorBestKg: _e1rm(100, 5),
        earlierSets: const [],
      );
      expect(result.isPr, isFalse);
    });

    test('same-session progression flags only the sets that beat the session',
        () {
      final prior = _e1rm(90, 5);
      final first = assessPr(
        weightKg: 100,
        reps: 5,
        isWarmup: false,
        priorBestKg: prior,
        earlierSets: const [],
      );
      expect(first.isPr, isTrue, reason: '100 kg beats the 90 kg history');

      final second = assessPr(
        weightKg: 105,
        reps: 5,
        isWarmup: false,
        priorBestKg: prior,
        earlierSets: const [(100.0, 5)],
      );
      expect(second.isPr, isTrue, reason: '105 kg beats the earlier 100 kg');

      final third = assessPr(
        weightKg: 100,
        reps: 5,
        isWarmup: false,
        priorBestKg: prior,
        earlierSets: const [(100.0, 5), (105.0, 5)],
      );
      expect(third.isPr, isFalse,
          reason: 'a set below the session best is not a PR');
    });

    test('zero-rep sets never qualify, even as the first set', () {
      final result = assessPr(
        weightKg: 100,
        reps: 0,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(result.isPr, isFalse, reason: 'audit B4: zero reps carry no e1RM');
      expect(result.e1rmKg, isNull);
    });

    test('warm-up sets never qualify', () {
      final result = assessPr(
        weightKg: 200,
        reps: 5,
        isWarmup: true,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(result.isPr, isFalse);
    });

    test('a zero-e1RM set (0 kg logged) never flags', () {
      final result = assessPr(
        weightKg: 0,
        reps: 5,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(result.isPr, isFalse,
          reason: '0 kg carries no signal, matching e1rmMaxOf on empty input');
    });

    test('negative weights never qualify', () {
      final result = assessPr(
        weightKg: -5,
        reps: 5,
        isWarmup: false,
        priorBestKg: 0,
        earlierSets: const [],
      );
      expect(result.isPr, isFalse);
    });
  });

  group('store PR detection and persistence', () {
    late String path;
    late Directory tmp;
    late AppStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('compounder_pr_store');
      path = p.join(tmp.path, 'pr.db');
      databaseFactory = databaseFactoryFfi;
      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: path);
    });

    tearDown(() async {
      await store.db.close();
      await databaseFactory.deleteDatabase(path);
      await tmp.delete(recursive: true);
    });

    /// Seeds an exercise and, when [priorWeightKg] is given, a finished session
    /// with one working set at that weight.
    Future<int> seedExercise({double? priorWeightKg, int priorReps = 5}) async {
      final exerciseId = await store.db.insert('exercises', {
        'name': 'Back squat',
        'muscle_group': 'Legs',
        'equipment': 'Barbell',
        'is_custom': 0,
      });
      if (priorWeightKg != null) {
        final workoutId = await store.db.insert('workouts', {
          'name': 'Prior leg day',
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
        'name': 'Leg day',
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

    test('completing a baseline set flags it and stores the e1RM snapshot',
        () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final setId =
          await store.addSet(active.entryId, 100, 5, completed: false);
      expect((await setById(setId)).isPr, isFalse,
          reason: 'an incomplete set is not a performed set');

      await store.updateSet(setId,
          completedAt: DateTime.now().millisecondsSinceEpoch);
      final set = await setById(setId);
      expect(set.isPr, isTrue, reason: 'first-ever set is the baseline PR');
      expect(set.prE1rmKg, _e1rm(100, 5));
    });

    test('beating a prior finished session flags a PR', () async {
      final exerciseId = await seedExercise(priorWeightKg: 100);
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 110, 5);
      final set = await setById(setId);
      expect(set.isPr, isTrue);
      expect(set.prE1rmKg, _e1rm(110, 5));
    });

    test('matching or falling short of the prior session does not flag',
        () async {
      final exerciseId = await seedExercise(priorWeightKg: 100);
      final active = await seedActive(exerciseId);
      final matchId = await store.addSet(active.entryId, 100, 5);
      final shortId = await store.addSet(active.entryId, 95, 5);
      expect((await setById(matchId)).isPr, isFalse);
      expect((await setById(shortId)).isPr, isFalse);
    });

    test('same-session progression flags only the sets that beat the session',
        () async {
      final exerciseId = await seedExercise(priorWeightKg: 90);
      final active = await seedActive(exerciseId);
      final first = await store.addSet(active.entryId, 100, 5);
      final second = await store.addSet(active.entryId, 105, 5);
      final third = await store.addSet(active.entryId, 100, 5);
      expect((await setById(first)).isPr, isTrue);
      expect((await setById(second)).isPr, isTrue);
      expect((await setById(third)).isPr, isFalse,
          reason: 'a set below the session best is not a PR');
    });

    test('an untouched heavier set does not suppress a completed PR', () async {
      final exerciseId = await seedExercise(priorWeightKg: 90);
      final active = await seedActive(exerciseId);
      // A planned 120 kg set that is never performed must not block the PR for
      // the 100 kg set the user actually completed.
      await store.addSet(active.entryId, 120, 5, completed: false);
      final performed = await store.addSet(active.entryId, 100, 5);
      expect((await setById(performed)).isPr, isTrue,
          reason: 'only performed sets count as earlier in the session');
    });

    test('editing a set down recomputes the later sets', () async {
      final exerciseId = await seedExercise(priorWeightKg: 90);
      final active = await seedActive(exerciseId);
      final first = await store.addSet(active.entryId, 100, 5);
      final second = await store.addSet(active.entryId, 105, 5);
      expect((await setById(second)).isPr, isTrue);

      // Lowering the first set does not change the second (it still beats the
      // session). Raising the first above the second must demote the second.
      await store.updateSet(first, weightKg: 110);
      expect((await setById(first)).isPr, isTrue);
      expect((await setById(second)).isPr, isFalse,
          reason: 'the later set no longer beats the earlier one');
    });

    test('zero-rep sets never flag, even when completed', () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 100, 0);
      final set = await setById(setId);
      expect(set.isPr, isFalse);
      expect(set.prE1rmKg, isNull);
    });

    test('warm-up sets never flag', () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 200, 5, warmup: true);
      expect((await setById(setId)).isPr, isFalse);
    });

    test('prSummary reports previous best, new best and delta', () async {
      final exerciseId = await seedExercise(priorWeightKg: 90);
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 100, 5);
      await store.addSet(active.entryId, 105, 5);

      final prs = await store.prSummary(active.workoutId);
      expect(prs, hasLength(1));
      expect(prs.single.exerciseName, 'Back squat');
      expect(prs.single.previousBestKg, _e1rm(90, 5));
      expect(prs.single.newBestKg, _e1rm(105, 5));
      expect(prs.single.deltaKg, _e1rm(105, 5) - _e1rm(90, 5));
      expect(prs.single.isBaseline, isFalse);
    });

    test('prSummary marks a first-ever session as a baseline', () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 60, 10);
      final prs = await store.prSummary(active.workoutId);
      expect(prs, hasLength(1));
      expect(prs.single.isBaseline, isTrue);
      expect(prs.single.previousBestKg, 0);
      expect(prs.single.newBestKg, _e1rm(60, 10));
    });

    test('prSummary is empty when the session has no PRs', () async {
      final exerciseId = await seedExercise(priorWeightKg: 120);
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 100, 5);
      expect(await store.prSummary(active.workoutId), isEmpty);
    });

    test('a historical summary ignores sessions that finished after it',
        () async {
      // Session A is the first-ever session; session B comes later and is
      // heavier. Summarising A must still report the baseline it established,
      // not a "previous best" borrowed from the future.
      final exerciseId = await seedExercise();
      final a = await seedActive(exerciseId);
      await store.addSet(a.entryId, 100, 5);
      await store.finishWorkout(a.workoutId);

      final b = await seedActive(exerciseId);
      await store.addSet(b.entryId, 120, 5);
      await store.finishWorkout(b.workoutId);

      final prsA = await store.prSummary(a.workoutId);
      expect(prsA, hasLength(1));
      expect(prsA.single.previousBestKg, 0,
          reason: 'session B finished after A and must not be its baseline');
      expect(prsA.single.isBaseline, isTrue);
      expect(prsA.single.newBestKg, _e1rm(100, 5));

      // The later session still sees A as its prior best: the bound is
      // "finished before", not "exclude everything".
      final prsB = await store.prSummary(b.workoutId);
      expect(prsB, hasLength(1));
      expect(prsB.single.previousBestKg, _e1rm(100, 5));
      expect(prsB.single.isBaseline, isFalse);
    });

    test('the same exercise twice in one workout shares one session baseline',
        () async {
      final exerciseId = await seedExercise();
      final active = await seedActive(exerciseId);
      final heavy = await store.addSet(active.entryId, 100, 5);
      // The same exercise logged a second time in the same session.
      final secondEntry = await store.db.insert('workout_exercises', {
        'workout_id': active.workoutId,
        'exercise_id': exerciseId,
        'position': 1,
      });
      final lighter = await store.addSet(secondEntry, 90, 5);

      expect((await setById(heavy)).isPr, isTrue,
          reason: 'the first-ever 100 kg set is the baseline PR');
      expect((await setById(lighter)).isPr, isFalse,
          reason: '100 kg was already performed earlier in the same session');

      await store.finishWorkout(active.workoutId);
      final row =
          store.history.firstWhere((r) => r.workoutId == active.workoutId);
      expect(row.prCount, 1,
          reason: 'the duplicate entry must not inflate the PR count');
    });

    test('an unfinished placeholder in a prior session does not suppress a PR',
        () async {
      final exerciseId = await seedExercise();
      final priorWorkout = await store.db.insert('workouts', {
        'name': 'Prior leg day',
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
        'weight_kg': 100.0,
        'reps': 5,
        'completed_at': 1500,
        'is_warmup': 0,
      });
      // A planned 120 kg set that was never performed.
      await store.db.insert('workout_sets', {
        'workout_exercise_id': priorEntry,
        'position': 1,
        'weight_kg': 120.0,
        'reps': 5,
        'completed_at': null,
        'is_warmup': 0,
      });

      final active = await seedActive(exerciseId);
      final setId = await store.addSet(active.entryId, 110, 5);
      expect((await setById(setId)).isPr, isTrue,
          reason: 'only performed prior sets count as the previous best');
    });

    test('history carries the per-session PR count', () async {
      final exerciseId = await seedExercise(priorWeightKg: 90);
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 100, 5);
      await store.addSet(active.entryId, 105, 5);
      await store.finishWorkout(active.workoutId);

      final row =
          store.history.firstWhere((r) => r.workoutId == active.workoutId);
      expect(row.prCount, 2);
    });

    test('migration 11 -> 12 adds the PR columns without false PRs', () async {
      final exerciseId = await seedExercise(priorWeightKg: 100);
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 120, 5);
      await store.finishWorkout(active.workoutId);

      // Rewind to a genuine v11 shape: no PR columns at all.
      await store.db.execute('ALTER TABLE workout_sets DROP COLUMN is_pr');
      await store.db.execute('ALTER TABLE workout_sets DROP COLUMN pr_e1rm_kg');
      await store.db.setVersion(11);
      await store.db.close();

      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: path);
      expect(await store.db.getVersion(), 13);

      final sets = await store.db.query('workout_sets');
      expect(sets, hasLength(2), reason: 'every set must survive the upgrade');
      for (final set in sets) {
        expect(set['is_pr'], 0,
            reason: 'a migrated row must never be marked as a PR');
        expect(set['pr_e1rm_kg'], isNull);
      }
      // The values themselves are untouched.
      final activeSet = sets.firstWhere((s) => s['weight_kg'] == 120.0);
      expect(activeSet['reps'], 5);
      expect(activeSet['completed_at'], isNotNull);
    });

    test('backup export/import preserves the PR flag and snapshot', () async {
      final docs = await Directory.systemTemp.createTemp('compounder_pr_docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProviderChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docs.path;
        }
        return null;
      });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_pathProviderChannel, null);
        await docs.delete(recursive: true);
      });

      final exerciseId = await seedExercise(priorWeightKg: 90);
      final active = await seedActive(exerciseId);
      await store.addSet(active.entryId, 110, 5);
      await store.finishWorkout(active.workoutId);

      final file = await BackupService.export(store);
      final json =
          jsonDecode(await File(file).readAsString()) as Map<String, Object?>;
      final exported = (json['workoutSets'] as List).cast<Map>();
      final prRow = exported.firstWhere((r) => r['is_pr'] == 1);
      expect(prRow['pr_e1rm_kg'], _e1rm(110, 5));

      final targetPath = p.join(tmp.path, 'pr_target.db');
      final target = await AppStore.open(await SharedPreferences.getInstance(),
          path: targetPath);
      addTearDown(() async {
        await target.db.close();
        await databaseFactory.deleteDatabase(targetPath);
      });
      await BackupService.import(target, file);

      final restored =
          await target.db.query('workout_sets', where: 'is_pr = 1');
      expect(restored, hasLength(1),
          reason: 'the PR flag must survive the round-trip');
      expect(restored.single['pr_e1rm_kg'], _e1rm(110, 5));
      expect(restored.single['weight_kg'], 110.0);
    });
  });

  group('workout screen: PR badge and celebration tone', () {
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
        'name': 'Back squat',
        'muscle_group': 'Legs',
        'equipment': 'Barbell',
        'is_custom': 0,
      });
      workoutId = await store.db.insert('workouts', {
        'name': 'Leg day',
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
        'weight_kg': 100.0,
        'reps': 5,
        'completed_at': null,
        'is_warmup': 0,
      });
      await store.refreshAll();
    });

    tearDown(() async {
      await store.db.close();
    });

    Future<void> pumpWorkout(
        WidgetTester tester, _FakeWorkoutSounds sounds) async {
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
      expect(find.text('Back squat'), findsOneWidget);
    }

    Future<void> completeFirstSet(WidgetTester tester) async {
      final checkbox = find.descendant(
          of: find.byTooltip('Mark set complete').first,
          matching: find.byType(Checkbox));
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a baseline PR shows a badge and plays the celebration tone',
        (tester) async {
      final sounds = _FakeWorkoutSounds();
      await pumpWorkout(tester, sounds);
      expect(find.textContaining('PR ·'), findsNothing,
          reason: 'no badge before the set is completed');

      await completeFirstSet(tester);

      expect(sounds.played, contains(WorkoutCue.personalRecord),
          reason: 'completing a PR set must play the celebration tone');
      expect(
          find.text(
              'PR · ${trimZero(fromKg(_e1rm(100, 5), WeightUnit.kg))} kg e1RM'),
          findsOneWidget,
          reason: 'the badge must show the e1RM snapshot in the user unit');
    });

    testWidgets('the mute setting suppresses the celebration tone',
        (tester) async {
      await store.setRestSoundsEnabled(false);
      final sounds = _FakeWorkoutSounds();
      await pumpWorkout(tester, sounds);

      await completeFirstSet(tester);

      expect(sounds.played, isEmpty, reason: 'muted means no PR tone either');
      expect(find.textContaining('PR ·'), findsOneWidget,
          reason: 'the badge is visual and still shown when muted');
    });

    testWidgets('a non-PR set plays no celebration tone', (tester) async {
      // A prior finished session at the same weight makes this set a match,
      // not a PR.
      final exerciseId =
          (await store.db.query('exercises')).single['id'] as int;
      final priorWorkout = await store.db.insert('workouts', {
        'name': 'Prior leg day',
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
        'weight_kg': 100.0,
        'reps': 5,
        'completed_at': 1500,
        'is_warmup': 0,
      });
      await store.refreshAll();

      final sounds = _FakeWorkoutSounds();
      await pumpWorkout(tester, sounds);
      await completeFirstSet(tester);

      expect(sounds.played, isEmpty);
      expect(find.textContaining('PR ·'), findsNothing);
    });
  });

  group('summary and history surfaces', () {
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
      required double priorWeightKg,
      required double newWeightKg,
      bool withPrior = true,
    }) async {
      final exerciseId = await store.db.insert('exercises', {
        'name': 'Back squat',
        'muscle_group': 'Legs',
        'equipment': 'Barbell',
        'is_custom': 0,
      });
      if (withPrior) {
        final priorWorkout = await store.db.insert('workouts', {
          'name': 'Prior leg day',
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
          'weight_kg': priorWeightKg,
          'reps': 5,
          'completed_at': 1500,
          'is_warmup': 0,
        });
      }
      workoutId = await store.db.insert('workouts', {
        'name': 'Leg day',
        'started_at': 3000,
        'ended_at': 4000,
      });
      final entryId = await store.db.insert('workout_exercises', {
        'workout_id': workoutId,
        'exercise_id': exerciseId,
        'position': 0,
      });
      // Go through the store so the PR flags are computed exactly as the app
      // computes them when a set is logged.
      await store.addSet(entryId, newWeightKg, 5);
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

    testWidgets('the summary lists a PR with previous best, new best and delta',
        (tester) async {
      await seedSession(priorWeightKg: 90, newWeightKg: 110);
      await pumpSummary(tester);

      expect(find.text('PERSONAL RECORDS'), findsOneWidget);
      final previous = trimZero(fromKg(_e1rm(90, 5), WeightUnit.kg));
      final newBest = trimZero(fromKg(_e1rm(110, 5), WeightUnit.kg));
      final delta =
          trimZero(fromKg(_e1rm(110, 5) - _e1rm(90, 5), WeightUnit.kg));
      expect(
          find.text('Previous best $previous kg → new best $newBest kg '
              '(+$delta kg)'),
          findsOneWidget);
    });

    testWidgets('a baseline PR reads as a first PR', (tester) async {
      await seedSession(priorWeightKg: 0, newWeightKg: 60, withPrior: false);
      await pumpSummary(tester);

      expect(find.text('PERSONAL RECORDS'), findsOneWidget);
      final newBest = trimZero(fromKg(_e1rm(60, 5), WeightUnit.kg));
      expect(find.text('First PR · $newBest kg'), findsOneWidget);
    });

    testWidgets('the PR section is omitted when the session has no PRs',
        (tester) async {
      await seedSession(priorWeightKg: 120, newWeightKg: 100);
      await pumpSummary(tester);

      expect(find.text('PERSONAL RECORDS'), findsNothing);
      expect(find.text('EXERCISES'), findsOneWidget,
          reason: 'the rest of the summary still renders');
    });

    testWidgets('the summary shows the PR in pounds when lb is selected',
        (tester) async {
      await store.setUnit(WeightUnit.lb);
      await seedSession(priorWeightKg: 90, newWeightKg: 110);
      await pumpSummary(tester);

      final previous = trimZero(fromKg(_e1rm(90, 5), WeightUnit.lb));
      final newBest = trimZero(fromKg(_e1rm(110, 5), WeightUnit.lb));
      final delta =
          trimZero(fromKg(_e1rm(110, 5) - _e1rm(90, 5), WeightUnit.lb));
      expect(
          find.text('Previous best $previous lb → new best $newBest lb '
              '(+$delta lb)'),
          findsOneWidget);
    });

    testWidgets('expanded sets carry a PR badge', (tester) async {
      await seedSession(priorWeightKg: 90, newWeightKg: 110);
      await pumpSummary(tester);

      final expand = find.bySemanticsLabel('Expand sets for Back squat');
      await tester.ensureVisible(expand);
      await tester.pumpAndSettle();
      await tester.tap(expand);
      await tester.pumpAndSettle();

      expect(find.text('PR'), findsOneWidget,
          reason: 'the qualifying set must be badged in the set list');
    });

    testWidgets('history shows the per-session PR count', (tester) async {
      await seedSession(priorWeightKg: 90, newWeightKg: 110);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: MaterialApp(
            theme: CompounderTheme.light(),
            home: const HistoryScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('1 PR'), findsOneWidget,
          reason: 'the history row must surface the session PR count');
    });

    testWidgets('a failed PR query surfaces an error row, not an empty section',
        (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStore>.value(
          value: _FailingPrStore(),
          child: MaterialApp(
            theme: CompounderTheme.light(),
            home: const SummaryScreen(1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('PERSONAL RECORDS'), findsOneWidget,
          reason: 'a DB error must not look like "this session had no PRs"');
      expect(find.text('Could not load personal records for this session.'),
          findsOneWidget);
      expect(find.text('EXERCISES'), findsOneWidget,
          reason: 'the rest of the summary still renders');
    });
  });
}
