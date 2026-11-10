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

/// Day planner lane layout proofs: overlapping blocks must render side by side
/// in deterministic lanes (2 and 3+ overlaps, partial overlaps), every lane
/// block must stay visible, tappable and resizable, and blocks that touch in
/// time must show a visual gap without changing their stored times.
///
/// The rect assertions are the point: "no exception" would pass with every card
/// stacked at full width, which is the bug this suite guards.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
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

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  Future<void> scrollToTop(WidgetTester tester) async {
    await tester.drag(
        find.byKey(const ValueKey('plan-grid')), const Offset(0, 3000));
    await tester.pumpAndSettle();
  }

  Future<int> addBlock(String title, int start, int end) async {
    return store.createPlanBlock(
        day: day, title: title, startMin: start, endMin: end);
  }

  Rect card(WidgetTester tester, int id) =>
      tester.getRect(find.byKey(ValueKey('plan-card-$id')));

  Rect body(WidgetTester tester, int id) =>
      tester.getRect(find.byKey(ValueKey('plan-block-$id')));

  Rect handle(WidgetTester tester, int id) =>
      tester.getRect(find.byKey(ValueKey('plan-resize-$id')));

  String blockLabel(int start, int duration) =>
      '${formatPlanTime(start)}–${formatPlanTime(start + duration)} · '
      '${formatPlanDuration(duration)}';

  /// The block column's horizontal bounds on a 400dp surface.
  const timelineLeft = 56.0;
  const timelineRight = 400.0 - 8.0;

  void expectSideBySide(Rect a, Rect b, {required String reason}) {
    final disjoint = a.right <= b.left || b.right <= a.left;
    expect(disjoint, isTrue,
        reason: '$reason: ${a.left}..${a.right} vs ${b.left}..${b.right}');
  }

  void expectInsideTimeline(Rect r, {required String reason}) {
    expect(r.left, greaterThanOrEqualTo(timelineLeft - 0.01), reason: reason);
    expect(r.right, lessThanOrEqualTo(timelineRight + 0.01), reason: reason);
    expect(r.width, greaterThan(0), reason: reason);
  }

  group('plannerLaneLayout', () {
    PlannerSpan span(int id, int start, int end) =>
        PlannerSpan(id: id, start: start, end: end);

    test('two overlapping blocks get two lanes', () {
      final lanes = plannerLaneLayout([span(1, 360, 420), span(2, 390, 450)]);
      expect(lanes[1]!.lanes, 2);
      expect(lanes[2]!.lanes, 2);
      expect(lanes[1]!.lane, isNot(lanes[2]!.lane));
    });

    test('three mutually overlapping blocks get three lanes', () {
      final lanes = plannerLaneLayout(
          [span(1, 360, 480), span(2, 390, 510), span(3, 420, 540)]);
      expect(lanes.values.map((l) => l.lanes).toSet(), {3});
      expect(lanes.values.map((l) => l.lane).toSet(), {0, 1, 2});
    });

    test('a transitive overlap chain shares one cluster', () {
      // A overlaps B, B overlaps C: one cluster, even though A and C do not
      // overlap each other.
      final lanes = plannerLaneLayout(
          [span(1, 360, 420), span(2, 390, 450), span(3, 420, 480)]);
      expect(lanes.values.map((l) => l.lanes).toSet(), {2},
          reason: 'A and C can share a lane, but all three are one cluster');
      expect(lanes[1]!.lane, lanes[3]!.lane,
          reason: 'A ends when C starts, so C reuses A\'s lane');
      expect(lanes[2]!.lane, isNot(lanes[1]!.lane));
    });

    test('blocks that only touch are not overlapping', () {
      final lanes = plannerLaneLayout([span(1, 360, 420), span(2, 420, 480)]);
      expect(lanes[1]!.lanes, 1);
      expect(lanes[2]!.lanes, 1);
    });

    test('partial overlap of three blocks needs three lanes', () {
      // At 06:30-07:00 all three are live, so three lanes are required.
      final lanes = plannerLaneLayout(
          [span(1, 360, 480), span(2, 420, 540), span(3, 390, 450)]);
      expect(lanes.values.map((l) => l.lanes).toSet(), {3});
      expect(lanes.values.map((l) => l.lane).toSet(), {0, 1, 2});
    });

    test('lane assignment is deterministic regardless of input order', () {
      final spans = [
        span(7, 360, 480),
        span(3, 390, 510),
        span(9, 420, 540),
        span(1, 600, 660),
      ];
      final forward = plannerLaneLayout(spans);
      final reversed = plannerLaneLayout(spans.reversed.toList());
      expect(reversed.length, forward.length);
      for (final id in forward.keys) {
        expect(reversed[id]!.lane, forward[id]!.lane,
            reason: 'block $id must keep its lane across rebuilds');
        expect(reversed[id]!.lanes, forward[id]!.lanes);
      }
    });

    test('every span gets an entry', () {
      final lanes = plannerLaneLayout([span(4, 0, 15), span(5, 1430, 1440)]);
      expect(lanes.keys.toSet(), {4, 5});
    });
  });

  group('overlapping blocks render side by side', () {
    testWidgets(
        'two overlapping blocks split into two lanes and both are '
        'tappable', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('Deep work', 360, 420);
        b = await addBlock('Review', 390, 450);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      final rectA = card(tester, a);
      final rectB = card(tester, b);
      expectSideBySide(rectA, rectB,
          reason: 'overlapping blocks must not paint over each other');
      expectInsideTimeline(rectA, reason: 'lane 0 must stay inside the grid');
      expectInsideTimeline(rectB, reason: 'lane 1 must stay inside the grid');
      expect(rectA.width, lessThan(timelineRight - timelineLeft),
          reason: 'a lane must be narrower than the full block column');

      // Both bodies are hit-testable: a tap opens that block's inline editor.
      await tester.tap(find.byKey(ValueKey('plan-block-$a')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('plan-inline')), findsOneWidget);
      expect(find.text('Deep work'), findsWidgets,
          reason: 'the tap must reach the first block, not the one on top');
      await tester.tap(find.byKey(const ValueKey('plan-inline-cancel')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('plan-block-$b')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('plan-inline')), findsOneWidget);
      expect(find.text('Review'), findsWidgets,
          reason: 'the second block must be reachable too');
    });

    testWidgets('three overlapping blocks get three distinct lanes',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b, c;
      await tester.runAsync(() async {
        a = await addBlock('One', 360, 480);
        b = await addBlock('Two', 390, 510);
        c = await addBlock('Three', 420, 540);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      final rects = [card(tester, a), card(tester, b), card(tester, c)];
      final lefts = rects.map((r) => r.left).toSet();
      expect(lefts, hasLength(3),
          reason: 'three overlapping blocks must occupy three lanes');
      for (var i = 0; i < rects.length; i++) {
        expectInsideTimeline(rects[i], reason: 'lane $i must stay in bounds');
        for (var j = i + 1; j < rects.length; j++) {
          expectSideBySide(rects[i], rects[j],
              reason: 'lanes $i and $j must not overlap');
        }
      }
      // Every lane keeps a reachable resize strip inside its own card.
      for (final id in [a, b, c]) {
        final strip = handle(tester, id);
        final rect = card(tester, id);
        expect(strip.left, greaterThanOrEqualTo(rect.left - 0.01));
        expect(strip.right, lessThanOrEqualTo(rect.right + 0.01));
        expect(strip.height, greaterThanOrEqualTo(16),
            reason: 'the resize strip must stay reachable in a narrow lane');
      }
    });

    testWidgets('a block dragged into an overlap re-lanes mid-gesture',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('Deep work', 360, 420);
        b = await addBlock('Review', 450, 510);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      // Before the drag the blocks do not overlap: both are full width.
      final beforeA = card(tester, a);
      final beforeB = card(tester, b);
      expect(beforeA.width, closeTo(beforeB.width, 0.01),
          reason: 'non-overlapping blocks must both use the full column');

      final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('plan-block-$a'))));
      // One hour down: 06:00-07:00 becomes 07:00-08:00, overlapping 07:30-08:30.
      await gesture.moveBy(const Offset(0, 96));
      await tester.pump();

      final duringA = card(tester, a);
      final duringB = card(tester, b);
      expectSideBySide(duringA, duringB,
          reason:
              'the lanes must recompute while the block is under the finger');
      expect(duringA.width, lessThan(beforeA.width),
          reason: 'the dragged block must shrink into a lane mid-gesture');

      await gesture.up();
      await settle(tester);
      final stored = await store.planBlocksForDay(day);
      expect(stored.firstWhere((block) => block.id == a).startMin, 420,
          reason: 'the drag must still write the moved start');
    });

    testWidgets('a 45-minute block in a 2-lane cluster keeps its full label',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('Block 45', 540, 585);
        b = await addBlock('Other', 555, 600);
      });
      await tester.pumpWidget(host());
      await settle(tester);

      final label = '${formatPlanTime(540)}–${formatPlanTime(585)} · '
          '${formatPlanDuration(45)}';
      final cardRect = card(tester, a);
      final otherRect = card(tester, b);
      expectSideBySide(cardRect, otherRect,
          reason: 'the 45-minute block must sit in its own lane');
      final bodyRect = body(tester, a);
      final labelRect = tester.getRect(find.text(label));
      final titleRect = tester.getRect(find.text('Block 45'));

      expect(bodyRect.bottom, lessThanOrEqualTo(cardRect.bottom),
          reason: 'the body must sit above the resize strip');
      expect(titleRect.top, greaterThanOrEqualTo(bodyRect.top));
      expect(titleRect.bottom, lessThanOrEqualTo(bodyRect.bottom),
          reason: 'the title must not be clipped in a narrow lane');
      expect(labelRect.top, greaterThanOrEqualTo(bodyRect.top));
      expect(labelRect.bottom, lessThanOrEqualTo(bodyRect.bottom),
          reason: 'the round-3 full-label fix must survive the lane layout');
      expect(tester.takeException(), isNull);
    });

    testWidgets('lane blocks keep their semantics labels and resize actions',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('Deep work', 360, 420);
        b = await addBlock('Review', 390, 450);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      for (final id in [a, b]) {
        expect(find.bySemanticsLabel(RegExp('Resize ')), findsWidgets);
        final resize =
            tester.getSemantics(find.byKey(ValueKey('plan-resize-$id')));
        expect(resize.getSemanticsData().hasAction(SemanticsAction.increase),
            isTrue);
        expect(resize.getSemanticsData().hasAction(SemanticsAction.decrease),
            isTrue);
      }
      handle.dispose();
    });
  });

  group('gap does not regress the card layout', () {
    testWidgets('a 60-minute block keeps its two-line layout after the gap',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int id;
      await tester.runAsync(() async {
        id = await addBlock('Deep work', 360, 420);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      // A 60-minute slot can afford the two-line column: the title above the
      // time label. The gap must be accounted for in that decision, otherwise
      // the card silently downgrades to the one-line compact row.
      final titleRect = tester.getRect(find.text('Deep work'));
      final labelRect = tester.getRect(find.text(blockLabel(360, 60)));
      expect(labelRect.top, greaterThanOrEqualTo(titleRect.bottom),
          reason: 'the label must sit below the title, not beside it');
      final bodyRect = body(tester, id);
      expect(labelRect.bottom, lessThanOrEqualTo(bodyRect.bottom),
          reason: 'the two-line layout must not clip the label');
    });
  });

  group('back-to-back blocks', () {
    testWidgets('touching blocks render with a positive vertical gap',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('First', 360, 420);
        b = await addBlock('Second', 420, 480);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      final rectA = card(tester, a);
      final rectB = card(tester, b);
      expect(rectB.top - rectA.bottom, greaterThan(0),
          reason: 'back-to-back blocks must not render flush');
      expect(rectB.top - rectA.bottom, lessThanOrEqualTo(4),
          reason: 'the gap must stay a hairline, not a hole');

      // The gap is purely visual: the stored times are untouched and the card
      // still starts at its real start minute (plus half the inset).
      final stored = await store.planBlocksForDay(day);
      expect(stored.firstWhere((block) => block.id == a).endMin, 420);
      expect(stored.firstWhere((block) => block.id == b).startMin, 420);
      final grid = tester.getRect(find.byKey(const ValueKey('plan-grid')));
      expect(rectA.top - grid.top, closeTo(360 / 60 * 96 + 1, 0.6),
          reason: 'the card must still map to its real start minute');
      expect(rectB.top - grid.top, closeTo(420 / 60 * 96 + 1, 0.6));
    });

    testWidgets('a tap on a touching block still opens the right editor',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('First', 360, 420);
        b = await addBlock('Second', 420, 480);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      await tester.tap(find.byKey(ValueKey('plan-block-$b')));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsWidgets,
          reason: 'hit-testing must be unchanged by the visual gap');
      await tester.tap(find.byKey(const ValueKey('plan-inline-cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('plan-block-$a')));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsWidgets);
    });
  });

  // A card that cannot fit its text grows past its slot. When another block
  // starts where it ends, the later card used to paint over the earlier card's
  // resize strip, so the strip was unreachable by touch. The card is now
  // clamped to the next block's top; these rect assertions are the guard.
  group('back-to-back short blocks keep the earlier resize strip reachable',
      () {
    testWidgets('15-minute blocks at 1.0: strip A is clear of card B',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('First', 360, 375);
        b = await addBlock('Second', 375, 390);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      final rectA = card(tester, a);
      final rectB = card(tester, b);
      final stripA = handle(tester, a);
      expect(stripA.bottom, lessThanOrEqualTo(rectB.top),
          reason: 'card B must not cover A\'s resize strip: '
              'strip ${stripA.top}..${stripA.bottom} vs B top ${rectB.top}');
      expect(stripA.height, greaterThanOrEqualTo(16),
          reason: 'the strip must stay a real touch target');
      expect(stripA.top, greaterThanOrEqualTo(rectA.top));
      expect(stripA.bottom, lessThanOrEqualTo(rectA.bottom));

      await tester.tapAt(stripA.center);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('plan-inline-done-$a')), findsOneWidget,
          reason: 'tapping A\'s strip must open A\'s editor, not B\'s');
      expect(find.byKey(ValueKey('plan-inline-done-$b')), findsNothing);

      final stored = await store.planBlocksForDay(day);
      expect(stored.firstWhere((block) => block.id == a).endMin, 375,
          reason: 'the clamp is visual: A still ends at 06:15');
      expect(stored.firstWhere((block) => block.id == b).startMin, 375,
          reason: 'the clamp is visual: B still starts at 06:15');
    });

    testWidgets('30-minute blocks at 2.0: strip A is clear of card B',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('First', 360, 390);
        b = await addBlock('Second', 390, 420);
      });
      await tester.pumpWidget(host(textScaler: 2.0));
      await settle(tester);
      await scrollToTop(tester);

      final rectA = card(tester, a);
      final rectB = card(tester, b);
      final stripA = handle(tester, a);
      expect(stripA.bottom, lessThanOrEqualTo(rectB.top),
          reason: 'at 2.0 card B must not cover A\'s resize strip: '
              'strip ${stripA.top}..${stripA.bottom} vs B top ${rectB.top}');
      expect(stripA.height, greaterThanOrEqualTo(16),
          reason: 'the strip must stay a real touch target');
      expect(stripA.top, greaterThanOrEqualTo(rectA.top));
      expect(stripA.bottom, lessThanOrEqualTo(rectA.bottom));

      await tester.tapAt(stripA.center);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('plan-inline-done-$a')), findsOneWidget,
          reason: 'tapping A\'s strip must open A\'s editor, not B\'s');
      expect(find.byKey(ValueKey('plan-inline-done-$b')), findsNothing);

      final stored = await store.planBlocksForDay(day);
      expect(stored.firstWhere((block) => block.id == a).endMin, 390);
      expect(stored.firstWhere((block) => block.id == b).startMin, 390);
    });

    testWidgets(
        'a resize drag on the clamped strip keeps the 96px/hour mapping',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late int a, b;
      await tester.runAsync(() async {
        a = await addBlock('First', 360, 375);
        b = await addBlock('Second', 375, 390);
      });
      await tester.pumpWidget(host());
      await settle(tester);
      await scrollToTop(tester);

      // 48px is 30 minutes: 06:00-06:15 becomes 06:00-06:45, overlapping B.
      await tester.drag(
          find.byKey(ValueKey('plan-resize-$a')), const Offset(0, 48));
      await settle(tester);

      final stored = await store.planBlocksForDay(day);
      expect(stored.firstWhere((block) => block.id == a).startMin, 360,
          reason: 'a resize must not move the start');
      expect(stored.firstWhere((block) => block.id == a).endMin, 405,
          reason: 'a 48px drag must extend the block by exactly 30 minutes');
      expect(stored.firstWhere((block) => block.id == b).startMin, 375,
          reason: 'resizing A must not touch B');
    });
  });
}
