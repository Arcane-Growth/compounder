import 'package:compounder/data/store.dart';
import 'package:compounder/domain/plan.dart';
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

  Widget host({double textScaler = 1.0}) =>
      ChangeNotifierProvider<AppStore>.value(
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

  testWidgets('shows the next block and a now marker on today', (tester) async {
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

  testWidgets('clears the now marker when the day rolls over at midnight',
      (tester) async {
    await tester.runAsync(() async {
      await store.createPlanBlock(
          day: day,
          title: 'Late block',
          startMin: 23 * 60,
          endMin: 23 * 60 + 30);
    });

    var current = DateTime(2026, 11, 9, 23, 59);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: CompounderTheme.light(),
        home: PlannerScreen(now: () => current, initialDay: day),
      ),
    ));
    await settle(tester);

    expect(find.text('Now 23:59'), findsOneWidget,
        reason: 'today must show a now marker before midnight');

    // The screen is left open across midnight. The local day key changes, so
    // the marker must clear instead of staying frozen on yesterday's date.
    current = DateTime(2026, 11, 10, 0, 1);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();

    expect(find.text('Now 23:59'), findsNothing,
        reason: 'a stale now marker must not survive the day rollover');
    expect(find.textContaining('Now '), findsNothing);
  });

  testWidgets('a stale day query cannot overwrite the selected day',
      (tester) async {
    // Two rapid day shifts: the 11-10 query is slow (400 ms) and the 11-11
    // query is fast (20 ms). Without a generation guard the 11-10 result lands
    // last and paints day 10's block under the day 11 header.
    Future<List<PlanBlock>> load(DateTime d) async {
      final delay = switch (d.day) {
        10 => const Duration(milliseconds: 400),
        11 => const Duration(milliseconds: 20),
        _ => Duration.zero,
      };
      await Future<void>.delayed(delay);
      return [
        PlanBlock(
          id: d.day,
          day: planDayKey(d),
          title: 'Block for day ${d.day}',
          startMin: 540,
          endMin: 600,
          createdAt: 0,
        ),
      ];
    }

    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: CompounderTheme.light(),
        home: PlannerScreen(
          now: () => now,
          initialDay: day,
          loadBlocks: load,
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('plan-next')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('plan-next')));
    await tester.pump();

    // The fast 11-11 query lands first, then the slow 11-10 one.
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Wed, Nov 11, 2026'), findsOneWidget);
    expect(find.text('Block for day 11'), findsOneWidget);
    expect(find.text('Block for day 10'), findsNothing,
        reason: 'the stale day-10 query must not overwrite day 11');
  });

  testWidgets('does not overflow at 320dp with 2.0 text scale', (tester) async {
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
