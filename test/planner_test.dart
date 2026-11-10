import 'dart:ui' show CheckedState;

import 'package:compounder/data/store.dart';
import 'package:compounder/domain/plan.dart';
import 'package:compounder/ui/planner.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

  testWidgets('the inline field is pulled clear when the keyboard opens',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.tapAt(Offset(200, gridY(tester, 420)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-inline')), findsOneWidget);

    // Scroll the field down toward the bottom of the viewport, where the
    // keyboard would cover it. Without the metrics handler this is its final
    // position.
    await tester.dragFrom(const Offset(200, 500), const Offset(0, 200));
    await tester.pumpAndSettle();
    final before = tester.getRect(find.byKey(const ValueKey('plan-inline')));
    expect(before.bottom, greaterThan(400),
        reason: 'precondition: the field must start low on screen');

    // Simulate the keyboard covering the bottom 300 logical pixels.
    tester.view.viewInsets =
        FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    addTearDown(() => tester.view.resetViewInsets());
    await tester.pumpAndSettle();

    final after = tester.getRect(find.byKey(const ValueKey('plan-inline')));
    expect(after.bottom, lessThanOrEqualTo(400),
        reason: 'the inline field must be pulled clear of the keyboard');
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

  testWidgets('a tap off the 15-minute boundary snaps the new block down',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    // 380 minutes is 06:20: the block must start at 06:15, not 06:20.
    await tester.tapAt(Offset(200, gridY(tester, 380)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('plan-inline')), 'Snapped');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.startMin, 375,
        reason: 'a tap at 06:20 must snap down to 06:15');
    expect(blocks.single.startMin % 15, 0);
  });

  testWidgets('a 15-minute block keeps the 48dp minimum card height',
      (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Quick', startMin: 60, endMin: 75);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    final card = tester.getSize(find.byKey(ValueKey('plan-card-$id')));
    expect(card.height, greaterThanOrEqualTo(48),
        reason: 'a 15-minute block must still be a 48dp touch target');
    // And it is still tappable to rename.
    await tester.tap(find.byKey(ValueKey('plan-block-$id')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-inline')), findsOneWidget);
  });

  testWidgets('the resize strip has a 48dp touch target', (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    final handle = tester.getSize(find.byKey(ValueKey('plan-resize-$id')));
    expect(handle.height, greaterThanOrEqualTo(48),
        reason: 'the only resize affordance must meet the 48dp minimum');
  });

  testWidgets('a drag that returns to its origin restores the block',
      (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    final gesture = await tester
        .startGesture(tester.getCenter(find.byKey(ValueKey('plan-block-$id'))));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.up();
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.single.startMin, 60,
        reason: 'a drag back to the origin must not move the block');
    expect(blocks.single.endMin, 120);
  });

  testWidgets('starting a drag commits an open rename instead of dropping it',
      (tester) async {
    late int a;
    late int b;
    await tester.runAsync(() async {
      a = await store.createPlanBlock(
          day: day, title: 'Block A', startMin: 60, endMin: 120);
      b = await store.createPlanBlock(
          day: day, title: 'Block B', startMin: 180, endMin: 240);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.tap(find.byKey(ValueKey('plan-block-$a')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('plan-inline')), 'Renamed A');

    // Drag B while A's editor is still open.
    await tester.drag(
        find.byKey(ValueKey('plan-block-$b')), const Offset(0, 96));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    final renamed = blocks.firstWhere((block) => block.id == a);
    expect(renamed.title, 'Renamed A',
        reason: 'the open rename must be committed, not discarded');
  });

  testWidgets('starting a drag commits a pending create instead of dropping it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late int b;
    await tester.runAsync(() async {
      b = await store.createPlanBlock(
          day: day, title: 'Block B', startMin: 600, endMin: 660);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.tapAt(Offset(200, gridY(tester, 375)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('plan-inline')), 'New thing');

    await tester.drag(
        find.byKey(ValueKey('plan-block-$b')), const Offset(0, 96));
    await settle(tester);

    final blocks = await store.planBlocksForDay(day);
    expect(blocks.map((block) => block.title), contains('New thing'),
        reason: 'the pending create must be committed, not discarded');
  });

  testWidgets('undo after a day switch restores the block to its own day',
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

    // Move to the next day while the undo snackbar is still up.
    await tester.tap(find.byKey(const ValueKey('plan-next')));
    await settle(tester);
    await tester.tap(find.text('Undo'));
    await settle(tester);

    final original = await store.planBlocksForDay(day);
    expect(original, hasLength(1),
        reason: 'undo must restore the block to the day it was deleted from');
    expect(original.single.title, 'Deep work');
    expect(await store.planBlocksForDay(DateTime(2026, 11, 10)), isEmpty,
        reason: 'undo must not create the block on the day now on screen');
  });

  testWidgets('a block at the end of the day stays inside the grid',
      (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Late', startMin: 1425, endMin: 1440);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    // Scroll to the bottom of the day.
    await tester.drag(
        find.byKey(const ValueKey('plan-grid')), const Offset(0, -3000));
    await tester.pumpAndSettle();

    final grid = tester.getRect(find.byKey(const ValueKey('plan-grid')));
    final handle = tester.getRect(find.byKey(ValueKey('plan-resize-$id')));
    expect(handle.bottom, lessThanOrEqualTo(grid.bottom),
        reason: 'the resize handle must not be clipped by the grid');
  });

  testWidgets('an editor at the end of the day stays inside the grid',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await settle(tester);
    await tester.drag(
        find.byKey(const ValueKey('plan-grid')), const Offset(0, -3000));
    await tester.pumpAndSettle();

    await tester.tapAt(Offset(200, gridY(tester, 1425)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-inline')), findsOneWidget);

    final grid = tester.getRect(find.byKey(const ValueKey('plan-grid')));
    final field = tester.getRect(find.byKey(const ValueKey('plan-inline')));
    expect(field.bottom, lessThanOrEqualTo(grid.bottom),
        reason: 'the inline field must not be clipped by the grid');
  });

  testWidgets('tapping the resize strip also opens the inline editor',
      (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    await tester.tap(find.byKey(ValueKey('plan-resize-$id')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-inline')), findsOneWidget,
        reason: 'the bottom strip must not be a dead zone');
  });

  testWidgets('resize and done controls expose semantics actions and state',
      (tester) async {
    final handle = tester.ensureSemantics();
    late int id;
    await tester.runAsync(() async {
      id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 60, endMin: 120);
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await scrollToTop(tester);

    final resize = tester.getSemantics(find.byKey(ValueKey('plan-resize-$id')));
    final resizeData = resize.getSemanticsData();
    expect(resizeData.hasAction(SemanticsAction.increase), isTrue,
        reason: 'a screen reader must be able to extend the block');
    expect(resizeData.hasAction(SemanticsAction.decrease), isTrue,
        reason: 'a screen reader must be able to shrink the block');

    final done = tester.getSemantics(find.byKey(ValueKey('plan-done-$id')));
    final doneFlags = done.getSemanticsData().flagsCollection;
    expect(doneFlags.isChecked, isNot(CheckedState.none),
        reason: 'the done toggle must announce that it has a state');
    expect(doneFlags.isChecked, CheckedState.isFalse);
    handle.dispose();
  });

  testWidgets('a compact block does not overflow at 320dp with 2.0 text scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      // 30 minutes takes the compact card path, which the 60-minute test above
      // never exercises.
      await store.createPlanBlock(
          day: day,
          title: 'A deliberately long block title that must ellipsize',
          startMin: 540,
          endMin: 570);
    });

    await tester.pumpWidget(host(textScaler: 2.0));
    await settle(tester);

    expect(tester.takeException(), isNull,
        reason: 'the compact card must not overflow at 320dp / 2.0');
    expect(find.byKey(const ValueKey('plan-grid')), findsOneWidget);
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
