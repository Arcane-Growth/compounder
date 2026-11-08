import 'package:compounder/data/store.dart';
import 'package:compounder/domain/habits.dart';
import 'package:compounder/ui/habits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature 4 widget proof: checking a habit off updates the progress line, and
/// the CRUD dialogs add, archive and delete habits.

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

  Widget host() => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: const MaterialApp(home: HabitsScreen()),
      );

  Future<void> tallViewport(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// Lets a store write (real async DB work) finish and then rebuilds the UI.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  testWidgets('checking a habit off updates progress and streak',
      (tester) async {
    final today = DateTime.now();
    await tester.runAsync(() async {
      await store.createHabit('Read', 'daily', 1);
    });

    await tallViewport(tester);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('Read'), findsOneWidget);
    expect(find.text('0/1 today · streak 0'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('habit-check-1')));
    await tester.pumpAndSettle();

    expect(find.text('1/1 today · streak 1'), findsOneWidget,
        reason: 'the checklist must show the checked-off day and its streak');
    expect(store.habitCompletions.single.day, habitDayKey(today));

    // Undo: the same control clears the day again.
    await tester.tap(find.byKey(const ValueKey('habit-check-1')));
    await tester.pumpAndSettle();
    expect(find.text('0/1 today · streak 0'), findsOneWidget);
    expect(store.habitCompletions, isEmpty);
  });

  testWidgets('the add dialog creates a habit with the chosen cadence',
      (tester) async {
    await tallViewport(tester);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('No habits yet'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('habits-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('habit-name')), 'Walk');
    await tester.enterText(find.byKey(const ValueKey('habit-target')), '3');
    await tester.tap(find.byKey(const ValueKey('habit-cadence')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekly').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(store.habits, hasLength(1));
    expect(store.habits.single.name, 'Walk');
    expect(store.habits.single.cadence, 'weekly');
    expect(store.habits.single.target, 3);
    expect(find.text('Walk'), findsOneWidget);
    expect(find.text('0/3 this week · streak 0'), findsOneWidget);
  });

  testWidgets('the add dialog rejects an empty name and a bad target',
      (tester) async {
    await tallViewport(tester);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('habits-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a habit name.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('habit-name')), 'Read');
    await tester.enterText(find.byKey(const ValueKey('habit-target')), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Target must be a whole number of at least 1.'),
        findsOneWidget);
    expect(store.habits, isEmpty);
  });

  testWidgets(
      'archive moves a habit out of the checklist and restore brings it back',
      (tester) async {
    await tester.runAsync(() async {
      await store.createHabit('Read', 'daily', 1);
    });
    await tallViewport(tester);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('habit-menu-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await settle(tester);

    expect(store.habits.single.archived, isTrue);
    expect(find.text('ARCHIVED'), findsOneWidget,
        reason: 'SectionHeader renders its label uppercased');
    expect(find.byKey(const ValueKey('habit-check-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('habit-restore-1')));
    await settle(tester);
    expect(store.habits.single.archived, isFalse);
    expect(find.byKey(const ValueKey('habit-check-1')), findsOneWidget);
  });

  testWidgets('delete asks for confirmation before removing the habit',
      (tester) async {
    await tester.runAsync(() async {
      final id = await store.createHabit('Read', 'daily', 1);
      await store.setHabitCompletion(id, DateTime.now(), true);
    });
    await tallViewport(tester);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('habit-menu-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete "Read"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.habits, hasLength(1), reason: 'cancel must keep the habit');

    await tester.tap(find.byKey(const ValueKey('habit-menu-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);

    expect(store.habits, isEmpty);
    expect(store.habitCompletions, isEmpty);
    expect(find.text('No habits yet'), findsOneWidget);
  });

  testWidgets('a failed write surfaces a message instead of vanishing',
      (tester) async {
    await tester.runAsync(() async {
      await store.createHabit('Read', 'daily', 1);
    });
    // Delete the row behind the store's back: the cache still lists the habit,
    // so the toggle hits the store's "no habit" guard.
    await tester.runAsync(() async {
      await store.db.delete('habits', where: 'id = ?', whereArgs: [1]);
    });
    await tallViewport(tester);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('habit-check-1')));
    await settle(tester);

    expect(find.text('No habit with id 1.'), findsOneWidget,
        reason: 'the StoreException must reach the user, not be dropped');
  });

  testWidgets('resuming on a new day refreshes the checklist date',
      (tester) async {
    await tester.runAsync(() async {
      await store.createHabit('Read', 'daily', 1);
    });
    var clock = DateTime(2026, 11, 8, 23, 50);
    await tallViewport(tester);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(home: HabitsScreen(now: () => clock)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('0/1 today · streak 0'), findsOneWidget);

    // The app was backgrounded overnight and resumes on the next day.
    clock = DateTime(2026, 11, 9, 0, 10);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('habit-check-1')));
    await settle(tester);
    expect(store.habitCompletions.single.day, '2026-11-09',
        reason: 'the checklist must follow the calendar, not the build date');
  });
}
