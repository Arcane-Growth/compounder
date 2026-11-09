import 'package:compounder/data/store.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/services/rest_sounds.dart';
import 'package:compounder/ui/settings.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:compounder/ui/workout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Health plugin stub: Settings' availability probe must not touch platform
/// channels.
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

/// Rest-timer audio cues (owner request):
///  * one quiet tick when 5 seconds of rest remain;
///  * a distinct "go" tone when the countdown reaches zero;
///  * a Settings mute switch that suppresses both;
///  * no cue after an early cancel, a restart or disposal.
///
/// Playback is injected, so these tests assert cue calls without touching
/// audio hardware.
class _FakeRestSounds implements RestSounds {
  final List<RestCue> played = [];
  bool disposed = false;

  @override
  Future<void> play(RestCue cue) async {
    played.add(cue);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  // No isolate: the widget test's fake-async zone cannot receive messages from
  // a background isolate, so DB futures would never complete.
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;
  late int workoutId;

  /// Seeds an active workout with two incomplete sets and a 7s rest default,
  /// so the 5s cue is two ticks away and the "go" cue seven.
  Future<void> seed({bool soundsEnabled = true}) async {
    SharedPreferences.setMockInitialValues({
      'restSeconds': 7,
      'restSoundsEnabled': soundsEnabled,
    });
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
    await store.db.insert('workout_sets', {
      'workout_exercise_id': entryId,
      'position': 1,
      'weight_kg': 100.0,
      'reps': 5,
      'completed_at': null,
      'is_warmup': 0,
    });
    await store.refreshAll();
  }

  tearDown(() async {
    await store.db.close();
  });

  Future<void> pumpWorkout(WidgetTester tester, _FakeRestSounds sounds) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: CompounderTheme.dark(),
        home: WorkoutScreen(workoutId: workoutId, sounds: sounds),
      ),
    ));
    // The detail query hits sqflite_common_ffi, which needs real async time.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Back squat'), findsOneWidget,
        reason: 'the workout detail must be loaded before the timer tests run');
  }

  /// Taps the "Done" checkbox of the next incomplete set and lets the DB
  /// writes finish. The rest timer is created in the fake-async zone by the
  /// pump.
  Future<void> completeSet(WidgetTester tester) async {
    final checkbox = find.descendant(
        of: find.byTooltip('Mark set complete').first,
        matching: find.byType(Checkbox));
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('plays one tick at 5s left and one go tone at zero',
      (tester) async {
    await seed();
    final sounds = _FakeRestSounds();
    await pumpWorkout(tester, sounds);

    await completeSet(tester);
    expect(find.text('0:07'), findsOneWidget,
        reason: 'completing a set starts the configured 7s rest');

    // 7 -> 6: nothing yet.
    await tester.pump(const Duration(seconds: 1));
    expect(sounds.played, isEmpty);
    // 6 -> 5: the warning tick.
    await tester.pump(const Duration(seconds: 1));
    expect(sounds.played, [RestCue.fiveSeconds],
        reason: 'exactly one tick at five seconds left');
    expect(find.text('0:05'), findsOneWidget);

    // 5 -> 4 -> 3 -> 2 -> 1: no further tick.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(sounds.played, [RestCue.fiveSeconds],
        reason: 'the tick must fire once, not on every tick below five');

    // 1 -> 0: the go tone.
    await tester.pump(const Duration(seconds: 1));
    expect(sounds.played, [RestCue.fiveSeconds, RestCue.go],
        reason: 'one go tone when the countdown reaches zero');
    expect(find.text('0:00'), findsNothing,
        reason: 'the rest chip disappears at zero');

    // Nothing more after the timer stopped.
    await tester.pump(const Duration(seconds: 5));
    expect(sounds.played, [RestCue.fiveSeconds, RestCue.go]);
  });

  testWidgets('the mute setting suppresses both cues', (tester) async {
    await seed(soundsEnabled: false);
    final sounds = _FakeRestSounds();
    await pumpWorkout(tester, sounds);

    await completeSet(tester);
    expect(find.text('0:07'), findsOneWidget,
        reason: 'the timer still runs when muted');

    for (var i = 0; i < 7; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(sounds.played, isEmpty,
        reason: 'muted means no audio at all, not just a quieter cue');
  });

  testWidgets('cancelling the rest early produces no go tone', (tester) async {
    await seed();
    final sounds = _FakeRestSounds();
    await pumpWorkout(tester, sounds);

    await completeSet(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(sounds.played, [RestCue.fiveSeconds]);

    // Tap the rest chip to cancel.
    await tester.tap(find.byType(ActionChip));
    await tester.pump();
    expect(find.byType(ActionChip), findsNothing,
        reason: 'the chip disappears when the rest is cancelled');

    await tester.pump(const Duration(seconds: 10));
    expect(sounds.played, [RestCue.fiveSeconds],
        reason: 'a cancelled rest must never fire the go tone');
  });

  testWidgets('restarting the rest timer does not leak a stale cue',
      (tester) async {
    await seed();
    final sounds = _FakeRestSounds();
    await pumpWorkout(tester, sounds);

    await completeSet(tester);
    await tester.pump(const Duration(seconds: 1)); // 6s left
    // Complete the second set: the rest restarts at 7s.
    await completeSet(tester);
    expect(find.text('0:07'), findsOneWidget);

    // The first timer would have reached zero at t=7s; the restarted one
    // reaches zero at t=7s from the restart. Exactly one tick and one go.
    for (var i = 0; i < 7; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(sounds.played, [RestCue.fiveSeconds, RestCue.go],
        reason: 'the abandoned timer must not fire its own cues');
  });

  testWidgets('disposing the screen mid-rest fires no cue and disposes audio',
      (tester) async {
    await seed();
    final sounds = _FakeRestSounds();
    await pumpWorkout(tester, sounds);

    await completeSet(tester);
    await tester.pump(const Duration(seconds: 1)); // 6s left, no cue yet

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));

    expect(sounds.played, isEmpty,
        reason: 'a disposed screen must not fire a stale cue');
    expect(sounds.disposed, isTrue,
        reason: 'the audio players are released with the screen');
  });

  group('restSoundsEnabled preference', () {
    test('defaults to on and round-trips through the store', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final first = await AppStore.open(prefs, path: inMemoryDatabasePath);
      addTearDown(() => first.db.close());

      expect(first.restSoundsEnabled, isTrue, reason: 'cues are on by default');

      await first.setRestSoundsEnabled(false);
      expect(first.restSoundsEnabled, isFalse);
      expect(prefs.getBool('restSoundsEnabled'), isFalse,
          reason: 'the setting must be persisted, not just held in memory');

      // A fresh store reading the same preferences sees the muted value.
      final second = await AppStore.open(prefs, path: inMemoryDatabasePath);
      addTearDown(() => second.db.close());
      expect(second.restSoundsEnabled, isFalse);

      await second.setRestSoundsEnabled(true);
      expect(first.restSoundsEnabled, isTrue,
          reason: 'the getter reads the persisted value');
    });

    testWidgets('Settings exposes a mute switch wired to the preference',
        (tester) async {
      await seed();
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final health = HealthService(
        store: store,
        repository: HealthRepository(store.db),
        source: _StubHealthSource(),
      );
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: health),
          Provider.value(value: NotifyService()),
        ],
        child: MaterialApp(
          theme: CompounderTheme.dark(),
          home: const SettingsScreen(),
        ),
      ));
      await tester.pump();
      await tester.pump();

      final tile = find.widgetWithText(SwitchListTile, 'Rest timer sounds');
      await tester.ensureVisible(tile);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue,
          reason: 'the switch reflects the default-on preference');

      await tester.tap(tile);
      await tester.pump();
      expect(store.restSoundsEnabled, isFalse,
          reason: 'toggling the switch must persist the mute');
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    });
  });
}
