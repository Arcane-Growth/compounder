import 'package:compounder/data/store.dart';
import 'package:compounder/ui/planner.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Day planner widget proofs: empty state, add/edit/complete/delete flows, and
/// the 320dp / 2.0 text-scale overflow guard.

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

  final day = DateTime(2026, 11, 9);
  final now = DateTime(2026, 11, 9, 12);

  Widget host({double textScaler = 1.0}) => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: CompounderTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScaler)),
            child: child!,
          ),
          home: PlannerScreen(now: () => now, initialDay: day),
        ),
      );

  /// Lets a store write (real async DB work) finish and then rebuilds the UI.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  testWidgets('shows an empty state that prompts planning', (tester) async {
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.text('Nothing planned for this day'), findsOneWidget);
    expect(find.text('Add a block to plan your day.'), findsOneWidget);
    expect(find.text('Add block'), findsOneWidget);
  });

  testWidgets('adds a block through the dialog', (tester) async {
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('plan-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('plan-title')), 'Deep work');
    await tester.tap(find.byKey(const ValueKey('plan-save')));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks, hasLength(1));
    expect(blocks.single.title, 'Deep work');
    expect(blocks.single.startMin, 9 * 60);
    expect(blocks.single.endMin, 10 * 60);
    expect(find.text('Deep work'), findsOneWidget);
    expect(find.text('09:00–10:00 · 1h'), findsOneWidget);
    expect(find.text('0 of 1 blocks done'), findsOneWidget);
  });

  testWidgets('rejects a blank title inline without writing', (tester) async {
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('plan-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan-save')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a title for this block.'), findsOneWidget);
    expect(await store.planBlocksForDay(day), isEmpty);
  });

  testWidgets('edits a block', (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 540, endMin: 600);
    });
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.text('Deep work'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('plan-title')), 'Deep work v2');
    await tester.tap(find.byKey(const ValueKey('plan-save')));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.id, id);
    expect(blocks.single.title, 'Deep work v2');
    expect(find.text('Deep work v2'), findsOneWidget);
  });

  testWidgets('marks a block done and reports progress', (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 540, endMin: 600);
    });
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.byKey(ValueKey('plan-done-$id')));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.done, isTrue);
    expect(blocks.single.doneAt, isNotNull);
    expect(find.text('1 of 1 blocks done'), findsOneWidget);
  });

  testWidgets('deletes a block after confirmation', (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 540, endMin: 600);
    });
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.byKey(ValueKey('plan-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // The confirmation dialog is up; cancelling must keep the block.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(await store.planBlocksForDay(day), hasLength(1));

    await tester.tap(find.byKey(ValueKey('plan-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);

    expect(await store.planBlocksForDay(day), isEmpty);
    expect(find.text('Nothing planned for this day'), findsOneWidget);
  });

  testWidgets('shows the next block and a now marker on today',
      (tester) async {
    await tester.runAsync(() async {
      await store.createPlanBlock(
          day: day, title: 'Afternoon', startMin: 13 * 60, endMin: 14 * 60);
    });
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.text('Now 12:00'), findsOneWidget,
        reason: 'today must show a now indicator');
    expect(find.text('Afternoon'), findsOneWidget);
  });

  testWidgets('does not overflow at 320dp with 2.0 text scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await store.createPlanBlock(
          day: day,
          title: 'A deliberately long block title that must ellipsize',
          startMin: 540,
          endMin: 600);
    });

    await tester.pumpWidget(host(textScaler: 2.0));
    await settle(tester);

    expect(tester.takeException(), isNull,
        reason: 'the planner must not overflow at 320dp / 2.0');
    expect(find.text('Add block'), findsOneWidget);
  });

  testWidgets('empty state does not overflow at 320dp with 2.0 text scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(textScaler: 2.0));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Nothing planned for this day'), findsOneWidget);
  });
}
