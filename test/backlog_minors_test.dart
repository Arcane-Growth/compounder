import 'dart:convert';
import 'dart:io';

import 'package:compounder/coach/agent.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/llm/llm.dart';
import 'package:compounder/seeder.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/subscription/entitlement.dart';
import 'package:compounder/ui/coach.dart';
import 'package:compounder/ui/settings.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression tests for the deferred audit minors/nits that change behaviour:
///
///  * m8 — the Settings version label drifted to v0.3.0 while pubspec.yaml was
///    at 0.3.2+9.
///  * m5 — `disconnect()` swallowed a failed `revokePermissions()` and still
///    reported "disconnected".
///  * backup MINOR-3 — `addExerciseToWorkout` threw a raw DatabaseException on
///    a dangling exercise id instead of a user-facing error.
///  * F5 — `_decodeFoods` discarded every food for a meal when one entry was
///    malformed.
///  * F6 — `seedExercises` ran unguarded on the pre-runApp launch path.
class _RevokeSource implements HealthSource {
  _RevokeSource({required this.failures});

  /// How many `revokePermissions()` calls throw before one succeeds.
  int failures;
  int attempts = 0;

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
  Future<void> revokePermissions() async {
    attempts++;
    if (attempts <= failures) throw StateError('revoke failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late String dbPath;
  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dbPath = '${await databaseFactory.getDatabasesPath()}/backlog_minors.db';
    await databaseFactory.deleteDatabase(dbPath);
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: dbPath);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  group('m8 settings version label', () {
    test('matches the pubspec version', () {
      // The label is a constant because package_info_plus is not a dependency;
      // this test is the guard against it drifting again. It reads the real
      // pubspec so bumping the version without updating the label fails here.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final versionLine = const LineSplitter()
          .convert(pubspec)
          .firstWhere((line) => line.startsWith('version:'));
      final version = versionLine.split(':')[1].trim().split('+').first;
      expect(appVersionLabel, 'Compounder v$version');
    });
  });

  group('m5 disconnect reports a failed revoke', () {
    test('a revoke that keeps failing is surfaced in lastError', () async {
      final source = _RevokeSource(failures: 99);
      final health = HealthService(
        store: store,
        repository: HealthRepository(store.db),
        source: source,
      );
      await health.disconnect();

      expect(source.attempts, 2, reason: 'one retry is attempted');
      expect(health.lastError, isNotNull,
          reason: 'the UI must not claim a clean disconnect');
      expect(health.lastError, contains('did not revoke'));
      expect(health.enabled, isFalse,
          reason: 'local state still disconnects');
    });

    test('a revoke that succeeds on retry leaves lastError null', () async {
      final source = _RevokeSource(failures: 1);
      final health = HealthService(
        store: store,
        repository: HealthRepository(store.db),
        source: source,
      );
      await health.disconnect();

      expect(source.attempts, 2);
      expect(health.lastError, isNull);
      expect(health.enabled, isFalse);
    });
  });

  group('backup MINOR-3 addExerciseToWorkout', () {
    test('a dangling exercise id raises StoreException, not DatabaseException',
        () async {
      final workoutId = await store.createWorkout('Push');
      // 9999 does not exist; PRAGMA foreign_keys = ON rejects the insert.
      await expectLater(
        store.addExerciseToWorkout(workoutId, 9999),
        throwsA(isA<StoreException>()),
      );
    });

    test('a valid exercise id still inserts', () async {
      final workoutId = await store.createWorkout('Push');
      await store.createExercise('Curl', 'Arms', 'Barbell');
      final exerciseId =
          store.exercises.firstWhere((e) => e.name == 'Curl').id;
      final entryId = await store.addExerciseToWorkout(workoutId, exerciseId);
      expect(entryId, greaterThan(0));
    });
  });

  group('F5 per-entry foods decode', () {
    test('one malformed food does not discard the rest of the meal', () async {
      await store.db.insert('meals', {
        'timestamp': 1000,
        'image_path': '',
        'dish': 'Plate',
        'calories': 500.0,
        'protein': 20.0,
        'carbs': 40.0,
        'fat': 10.0,
        'foods_json': jsonEncode([
          {'name': 'Rice', 'grams': 150, 'calories': 200, 'protein': 4,
            'carbs': 44, 'fat': 1},
          // `name` is not a String, so Food.fromJson throws for this entry.
          {'name': 42, 'grams': 100, 'calories': 300, 'protein': 16,
            'carbs': 0, 'fat': 9},
        ]),
        'is_auto': 0,
      });
      await store.db.close();
      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: dbPath);

      expect(store.meals, hasLength(1));
      expect(store.meals.single.foods, hasLength(1),
          reason: 'the valid entry survives the malformed one');
      expect(store.meals.single.foods.single.name, 'Rice');
    });

    test('a fully valid payload decodes every entry', () async {
      await store.db.insert('meals', {
        'timestamp': 1000,
        'image_path': '',
        'dish': 'Plate',
        'calories': 500.0,
        'protein': 20.0,
        'carbs': 40.0,
        'fat': 10.0,
        'foods_json': jsonEncode([
          {'name': 'Rice', 'grams': 150, 'calories': 200, 'protein': 4,
            'carbs': 44, 'fat': 1},
          {'name': 'Chicken', 'grams': 120, 'calories': 300, 'protein': 16,
            'carbs': 0, 'fat': 9},
        ]),
        'is_auto': 0,
      });
      await store.db.close();
      store = await AppStore.open(await SharedPreferences.getInstance(),
          path: dbPath);

      expect(store.meals.single.foods, hasLength(2));
    });
  });

  group('F6 seeder tolerates a bad catalog', () {
    test('malformed JSON seeds nothing instead of throwing', () async {
      // Before the fix this threw out of main() before runApp and the app never
      // started (audit F6).
      await seedCatalog(store, '{"not": "a list"');
      expect(store.exercises, isEmpty);
    });

    test('a JSON object (not a list) seeds nothing', () async {
      await seedCatalog(store, '{"name": "Curl"}');
      expect(store.exercises, isEmpty);
    });

    test('a valid catalog seeds, and re-seeding inserts nothing', () async {
      await seedCatalog(
          store,
          jsonEncode([
            {'name': 'Curl', 'muscle_group': 'Arms', 'equipment': 'Barbell'},
            {'name': 'Squat', 'muscle_group': 'Legs', 'equipment': 'Barbell'},
          ]));
      expect(store.exercises, hasLength(2));

      await seedCatalog(
          store,
          jsonEncode([
            {'name': 'Curl', 'muscle_group': 'Arms', 'equipment': 'Barbell'},
            {'name': 'Squat', 'muscle_group': 'Legs', 'equipment': 'Barbell'},
          ]));
      expect(store.exercises, hasLength(2),
          reason: 'the seeder dedupes on name');
    });

    test('rows with a non-String name are skipped, not fatal', () async {
      await seedCatalog(
          store,
          jsonEncode([
            {'name': 42, 'muscle_group': 'Arms'},
            {'name': 'Curl', 'muscle_group': 'Arms'},
          ]));
      expect(store.exercises, hasLength(1));
      expect(store.exercises.single.name, 'Curl');
    });
  });

  group('nutrition MINOR-4 goal parsing', () {
    test('a finite positive goal is accepted', () {
      expect(parseGoal('2500'), 2500);
      expect(parseGoal(' 180 '), 180);
      expect(parseGoal('72.5'), 72.5);
    });

    test('NaN and Infinity are rejected, not persisted', () {
      // `double.tryParse('NaN')` returns NaN, which used to persist and then
      // assert LinearProgressIndicator and poison the chart's maxY.
      expect(parseGoal('NaN'), isNull);
      expect(parseGoal('Infinity'), isNull);
      expect(parseGoal('-Infinity'), isNull);
    });

    test('zero, negative and non-numeric input is rejected', () {
      expect(parseGoal('0'), isNull);
      expect(parseGoal('-10'), isNull);
      expect(parseGoal(''), isNull);
      expect(parseGoal('abc'), isNull);
    });
  });

  group('backup MINOR-2 import confirmation copy', () {
    test('names every table the import replaces', () {
      for (final word in [
        'workouts',
        'meals',
        'accounts',
        'net-worth',
        'reminders',
        'day plans',
        'mind',
      ]) {
        expect(importConfirmText, contains(word),
            reason: 'the dialog must not understate what is wiped');
      }
    });
  });

  group('coach-history MINOR-2 transcript assembly', () {
    test('a blank note is dropped and the reply is kept', () {
      final out = messagesAfterTurn(
          const [], const CoachTurn(note: '   ', reply: 'Done.'));
      expect(out, hasLength(1));
      expect(out.single.text, 'Done.');
      expect(out.single.role, ChatMessage.roleAssistant);
    });

    test('a non-blank note is kept before the reply', () {
      final out = messagesAfterTurn(
          const [], const CoachTurn(note: '3 calls skipped', reply: 'Done.'));
      expect(out.map((m) => m.text).toList(), ['3 calls skipped', 'Done.']);
    });
  });

  group('trial-state MINOR-2 settings trial copy', () {
    testWidgets('Settings shows "Trial · ends <date>", never "Active · renews"',
        (tester) async {
      final end = DateTime.now().add(const Duration(days: 7));
      await store.saveEntitlement(Entitlement(
        status: EntitlementStatus.trialing,
        planCode: 'monthly',
        currentPeriodEnd: end,
        quota: const Quota(dailyLimit: 20, dailyUsed: 3),
        fetchedAt: DateTime.now(),
      ));
      final health = HealthService(
        store: store,
        repository: HealthRepository(store.db),
        source: _RevokeSource(failures: 0),
      );

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: health),
          Provider.value(value: NotifyService()),
        ],
        child: MaterialApp(
          theme: CompounderTheme.light(),
          home: const SettingsScreen(),
        ),
      ));
      await tester.pumpAndSettle();

      // The wiring at settings.dart must pass the cached trial, not a stale or
      // null entitlement: a trial is access without a completed purchase.
      expect(
          find.text('Trial · ends ${formatDate(end.millisecondsSinceEpoch)}'),
          findsOneWidget);
      expect(find.textContaining('Active · renews'), findsNothing);
      expect(find.text('Manage subscription'), findsOneWidget,
          reason: 'a trial grants access, so Settings offers management');
    });
  });
}
