import 'package:compounder/coach/agent.dart';
import 'package:compounder/ui/coach.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression proof for the approval card on a real phone.
///
/// The app theme sets `filledButtonTheme.minimumSize` to `Size.fromHeight(48)`
/// — a minimum width of *infinity*. The card used to lay Cancel and Approve out
/// in a `Row`, whose main axis is unbounded, so the FilledButton was forced to
/// an infinite width: the row overflowed and, in a release build (where
/// overflow is silently clipped instead of throwing), the Approve button was
/// pushed off the right edge of the screen. The owner saw only Cancel.
///
/// These tests therefore pump the card with the *real* `CompounderTheme`, at
/// the Pixel 10's logical size and at a narrow 320dp phone, with the text
/// scaled up to 2.0. The default test theme has no filled-button minimum size,
/// so a test that skips the app theme cannot catch this bug.
void main() {
  const single = PendingApproval([
    ProposedChange(
      toolCallId: 'c1',
      toolName: 'logMeal',
      summary: 'Log a meal: Chicken bowl — 620 kcal, 40g protein',
      args: {'dish': 'Chicken bowl', 'calories': 620},
    ),
  ]);
  const batch = PendingApproval([
    ProposedChange(
        toolCallId: 'c1',
        toolName: 'logMeal',
        summary: 'Log a meal: Oats — 300 kcal',
        args: {}),
    ProposedChange(
        toolCallId: 'c2',
        toolName: 'logMood',
        summary: 'Log a mood check-in: 3/5',
        args: {}),
  ]);

  /// Pumps the card the way the coach screen does: last item of the transcript
  /// list, inside the app's theme, on a phone-sized surface.
  Future<void> pumpCard(
    WidgetTester tester, {
    required Size size,
    required double textScale,
    required PendingApproval pending,
    required VoidCallback onApprove,
    required VoidCallback onCancel,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: CompounderTheme.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            CoachApprovalCard(
                pending: pending, onApprove: onApprove, onCancel: onCancel),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // The coach screen scrolls the transcript to the newest turn; do the same
    // so the card's action row is on screen, as it is on the device.
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
  }

  /// The button must be fully inside the screen, not clipped off an edge.
  void expectOnScreen(WidgetTester tester, Finder button, Size size) {
    final rect = tester.getRect(button);
    expect(rect.left, greaterThanOrEqualTo(0),
        reason: 'button starts off the left edge: $rect');
    expect(rect.right, lessThanOrEqualTo(size.width),
        reason: 'button is clipped off the right edge: $rect');
    expect(rect.top, greaterThanOrEqualTo(0),
        reason: 'button starts above the top edge: $rect');
    expect(rect.bottom, lessThanOrEqualTo(size.height),
        reason: 'button is below the bottom edge: $rect');
  }

  for (final size in const [Size(412, 915), Size(320, 640)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets(
          'Approve and Cancel are visible and tappable at '
          '${size.width.toInt()}x${size.height.toInt()} textScale $scale',
          (tester) async {
        var approved = 0;
        var cancelled = 0;
        await pumpCard(
          tester,
          size: size,
          textScale: scale,
          pending: single,
          onApprove: () => approved++,
          onCancel: () => cancelled++,
        );

        expect(tester.takeException(), isNull,
            reason: 'the action row must not overflow');

        final approve = find.widgetWithText(FilledButton, 'Approve');
        final cancel = find.widgetWithText(TextButton, 'Cancel');
        expect(approve, findsOneWidget);
        expect(cancel, findsOneWidget);
        expect(find.text('Nothing is saved until you approve.'), findsOneWidget);

        expectOnScreen(tester, approve, size);
        expectOnScreen(tester, cancel, size);

        await tester.tap(approve);
        await tester.pump();
        expect(approved, 1, reason: 'tapping Approve must fire onApprove');
        expect(cancelled, 0);

        await tester.tap(cancel);
        await tester.pump();
        expect(cancelled, 1, reason: 'tapping Cancel must fire onCancel');
      });
    }
  }

  testWidgets('a batch offers a visible, tappable Approve all at 320dp '
      'textScale 2.0', (tester) async {
    var approved = 0;
    await pumpCard(
      tester,
      size: const Size(320, 640),
      textScale: 2.0,
      pending: batch,
      onApprove: () => approved++,
      onCancel: () {},
    );

    expect(tester.takeException(), isNull);
    expect(find.text('The coach wants to make 2 changes'), findsOneWidget);
    final approveAll = find.widgetWithText(FilledButton, 'Approve all');
    expect(approveAll, findsOneWidget);
    expectOnScreen(tester, approveAll, const Size(320, 640));

    await tester.tap(approveAll);
    await tester.pump();
    expect(approved, 1);
  });
}
