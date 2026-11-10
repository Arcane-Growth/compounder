import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Guards the coach chat's markdown renderer across dependency bumps.
///
/// The coach prompt (lib/coach/agent.dart) asks the model for headers, bullets
/// and tables, and lib/ui/coach.dart renders replies with `GptMarkdown`. A
/// transitive swap inside gpt_markdown (1.3.4 replaced flutter_math_fork with
/// val_latex_flutter and dropped flutter_svg) could silently break that path,
/// so this test renders representative coach output and asserts the text
/// actually reaches the screen.
void main() {
  Future<void> pump(WidgetTester tester, String markdown) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GptMarkdown(
              markdown,
              style: const TextStyle(fontSize: 14),
              isStreaming: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// gpt_markdown renders paragraphs through BidiRichText, a RichText
  /// subclass, so match on the base type rather than an exact runtimeType.
  String rendered(WidgetTester tester) => tester
      .widgetList<RichText>(
        find.byWidgetPredicate((w) => w is RichText),
      )
      .map((w) => w.text.toPlainText())
      .join('\n');

  testWidgets('renders coach headings, bullets and tables', (tester) async {
    const md = '''
## Weekly plan

- Push day: 4 sets of bench press
- Pull day: 3 sets of rows

| Week | Calories | Protein |
| --- | --- | --- |
| 1 | 2400 | 180 |
''';
    await pump(tester, md);
    expect(tester.takeException(), isNull);
    final text = rendered(tester);
    expect(text, contains('Weekly plan'));
    expect(text, contains('Push day'));
    expect(text, contains('Calories'));
    expect(text, contains('180'));
  });

  testWidgets('keeps prices as prose, not maths', (tester) async {
    await pump(tester, r'A membership costs $5 and $10 per month.');
    expect(tester.takeException(), isNull);
    expect(rendered(tester), contains(r'$5 and $10'));
  });

  testWidgets('renders inline LaTeX through the new maths engine', (
    tester,
  ) async {
    await pump(tester, r'Your deficit is \(500\) kcal per day.');
    expect(tester.takeException(), isNull);
    final text = rendered(tester);
    expect(text, contains('deficit'));
    // The maths engine renders the formula as an embedded widget, which
    // surfaces as U+FFFC (object replacement character) in the plain text.
    // Asserting it proves the engine produced something, rather than the
    // paragraph silently dropping the formula.
    expect(text, contains('\uFFFC'));
  });

  testWidgets('renders bold and inline code', (tester) async {
    await pump(tester, '**Goal:** keep `protein` above 180 g.');
    expect(tester.takeException(), isNull);
    final text = rendered(tester);
    expect(text, contains('Goal:'));
    expect(text, contains('protein'));
  });
}
