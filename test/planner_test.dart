import 'package:compounder/data/store.dart';
import 'package:compounder/domain/plan.dart';
import 'package:compounder/ui/planner.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Day planner widget proofs: the direct-manipulation timeline — tap-to-create
/// with an inline one-liner, drag-to-resize, drag-to-move, delete with undo —
/// plus the now marker, the stale-query guard and the 320dp / 2.0 overflow
/// guard.

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

  /// Scrolls the grid back to midnight. The screen auto-scrolls to the current
  /// time on open, so a test that wants an early-morning block on screen has to
  /// undo that first.
  Future<void> scrollToTop(WidgetTester tester) async {
    await tester.drag(
        find.byKey(const ValueKey('plan-grid')), const Offset(0, 3000));
    await tester.pumpAndSettle();
  }

  /// The global y of [minute] on the grid, using the grid's real rect so the
  /// test does not depend on the day bar's height.
  double gridY(WidgetTester tester, int minute) {
    final rect = tester.getRect(find.byKey(const ValueKey('plan-grid')));
    return rect.top + minute / 60 * 96;
  }

  testWidgets('shows the empty hint and a full-day grid', (tester) async {
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.textContaining('Nothing planned for this day'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-grid')), findsOneWidget);
    // Hour labels cover the whole day, including the 24:00 end.
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('24:00'), findsOneWidget);
    // The old dialog-based add button is gone.
    expect(find.byKey(const ValueKey('plan-add')), findsNothing);
  });

  testWidgets('tap, type, Enter creates a block with the default duration',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    // Tap an empty slot at 06:15 (375 minutes from midnight).
    await tester.tapAt(Offset(200, gridY(tester, 375)));
    await tester.pumpAndSettle();

    // Inline field, in place: no dialog, no bottom sheet.
    expect(find.byKey(const ValueKey('plan-inline')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.enterText(
        find.byKey(const ValueKey('plan-inline')), 'Deep work');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks, hasLength(1));
    expect(blocks.single.title, 'Deep work');
    expect(blocks.single.startMin, 375,
        reason: 'the block must start at the tapped slot');
    expect(blocks.single.endMin, 405,
        reason: 'a new block defaults to 30 minutes');
    expect(find.text('Deep work'), findsOneWidget);
    expect(find.text('06:15–06:45 · 30 min'), findsOneWidget);
    expect(find.text('0 of 1 blocks done'), findsOneWidget);
  });

  testWidgets('a blank inline entry writes nothing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.tapAt(Offset(200, gridY(tester, 375)));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(await store.planBlocksForDay(day), isEmpty);
    expect(find.byKey(const ValueKey('plan-inline')), findsNothing);
  });

  testWidgets('dragging the bottom edge resizes and snaps to 15 minutes',
      (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    // 96px is one hour: 01:00-02:00 becomes 01:00-03:00.
    await tester.drag(
        find.byKey(ValueKey('plan-resize-$id')), const Offset(0, 96));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.startMin, 60,
        reason: 'a resize must not move the start');
    expect(blocks.single.endMin, 180,
        reason: 'a 96px drag must extend the block by exactly one hour');
    expect(blocks.single.durationMinutes, 120);
  });

  testWidgets('a resize drag snaps to the nearest 15-minute boundary',
      (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    // 40px is 25 minutes: the end must land on 02:30, not 02:25.
    await tester.drag(
        find.byKey(ValueKey('plan-resize-$id')), const Offset(0, 40));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.endMin, 150,
        reason: '25 minutes of drag must snap to the 30-minute mark');
    expect(blocks.single.endMin % 15, 0);
  });

  testWidgets('dragging the block body moves it in time', (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.drag(
        find.byKey(ValueKey('plan-block-$id')), const Offset(0, 96));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.startMin, 120,
        reason: 'a 96px body drag must move the block one hour later');
    expect(blocks.single.endMin, 180,
        reason: 'a move must keep the block duration');
  });

  testWidgets('long-press deletes with an undo that restores the block',
      (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.longPress(find.byKey(ValueKey('plan-block-$id')));
    await settle(tester);

    expect(await store.planBlocksForDay(day), isEmpty);
    expect(find.text('Deleted "Deep work"'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await settle(tester);

    final restored = await store.planBlocksForDay(day);
    expect(restored, hasLength(1));
    expect(restored.single.title, 'Deep work');
    expect(restored.single.startMin, 60);
    expect(restored.single.endMin, 120);
    expect(find.text('Deep work'), findsOneWidget);
  });

  testWidgets('tapping a block edits its one-liner in place', (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.tap(find.byKey(ValueKey('plan-block-$id')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('plan-inline')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.enterText(
        find.byKey(const ValueKey('plan-inline')), 'Deep work v2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.id, id);
    expect(blocks.single.title, 'Deep work v2');
    expect(blocks.single.startMin, 60,
        reason: 'renaming must not touch the times');
    expect(find.text('Deep work v2'), findsOneWidget);
  });

  testWidgets('marks a block done and reports progress', (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.tap(find.byKey(ValueKey('plan-done-$id')));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.done, isTrue);
    expect(blocks.single.doneAt, isNotNull);
    expect(find.text('1 of 1 blocks done'), findsOneWidget);
  });

  testWidgets('shows a now marker on today', (tester) async {
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
    expect(find.byKey(const ValueKey('plan-grid')), findsOneWidget);
  });

  testWidgets('empty state does not overflow at 320dp with 2.0 text scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(textScaler: 2.0));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Nothing planned for this day'), findsOneWidget);
  });
}
