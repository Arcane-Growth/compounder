import 'package:compounder/data/store.dart';
import 'package:compounder/services/rest_sounds.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:compounder/ui/workout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The workout screen's AppBar shows the session name above a live elapsed
/// timer. At 320dp with the Android maximum font scale (2.0) the timer row used
/// to overflow its Row and throw a RenderFlex overflow; the timer text must
/// shrink/ellipsize instead.

class _FakeWorkoutSounds implements WorkoutSounds {
  @override
  Future<void> play(WorkoutCue cue) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('workout AppBar at 320dp/textScale 2.0', () {
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

    testWidgets('the elapsed timer ellipsizes instead of overflowing',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2.0)),
            child: child!,
          ),
          home: WorkoutScreen(
              workoutId: workoutId, sounds: _FakeWorkoutSounds()),
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      await tester.pump();

      expect(find.text('Back squat'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'the workout AppBar must not overflow at 320dp/textScale 2.0');

      final timer = find.textContaining('Elapsed');
      expect(timer, findsOneWidget,
          reason: 'the live timer must still be shown');
      final rect = tester.getRect(timer);
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(320.0),
          reason: 'the timer text must stay inside the 320dp screen');

      // Dispose the tree so the periodic elapsed timer is cancelled.
      await tester.pumpWidget(const SizedBox());
    });
  });
}
