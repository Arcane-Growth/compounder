import 'package:compounder/coach/agent.dart';
import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/health/repository.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/llm/llm.dart';
import 'package:compounder/services/notify.dart';
import 'package:compounder/ui/coach.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// End-to-end coverage for the coach approval card that the layout-only test
/// (test/coach_approval_layout_test.dart) cannot reach:
///
///  * the card is revealed above an open keyboard (the `_scrollToBottom`
///    re-anchor path), and
///  * tapping Approve actually applies the pending write, while Cancel leaves
///    the store untouched — the `CoachApprovalCard -> _decide` wiring.
///
/// The tab is pumped with an injected agent and chat client so a real turn can
/// run without a network endpoint.
class _ScriptedClient extends ChatClient {
  final List<ChatResult> script;
  int calls = 0;

  _ScriptedClient(this.script) : super('http://localhost', 'key', 'model');

  @override
  Future<ChatResult> chat(
      List<ChatMessage> messages, List<ToolSpec> tools) async {
    final result = script[calls < script.length ? calls : script.length - 1];
    calls++;
    return result;
  }
}

ChatResult _writeCall(String id, String name, String args) =>
    ChatResult(null, [ToolCall(id, name, args)]);

ChatResult _final(String text) => ChatResult(text, const []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  const notifications = MethodChannel('dexterous.com/flutter/local_notifications');
  const timezone = MethodChannel('flutter_timezone');

  late AppStore store;
  late HealthService health;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: inMemoryDatabasePath);
    // The coach refuses to send unless the selected source is configured.
    await store.saveAi(
        const AiSettings(baseUrl: 'http://localhost', apiKey: 'key', model: 'model'));
    health = HealthService(store: store, repository: HealthRepository(store.db));

    // Every turn reschedules the daily digest (unawaited). Register the Android
    // implementation and stub the plugin channels so that does not throw
    // MissingPluginException / LateInitializationError in a widget test.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifications, (call) async {
      // AndroidFlutterLocalNotificationsPlugin.initialize is typed Future<bool>.
      if (call.method == 'initialize') return true;
      return null;
    });
    messenger.setMockMethodCallHandler(timezone, (call) async => 'UTC');
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifications, null);
    messenger.setMockMethodCallHandler(timezone, null);
    health.dispose();
    await store.db.close();
  });

  CoachAgent agentWith() => CoachAgent(toolList: [LogMealTool(store)]);

  /// Pumps the real coach screen with the app theme, a phone-sized surface and
  /// an optional keyboard inset.
  Future<void> pumpCoach(
    WidgetTester tester, {
    required CoachAgent agent,
    required ChatClient client,
    double keyboardInset = 0,
  }) async {
    await tester.binding.setSurfaceSize(const Size(412, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: health),
        Provider.value(value: NotifyService()),
      ],
      child: MaterialApp(
        theme: CompounderTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(viewInsets: EdgeInsets.only(bottom: keyboardInset)),
          child: child!,
        ),
        home: CoachTab(agent: agent, client: client),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.send));
    await tester.pumpAndSettle();
  }

  testWidgets('the approval card is fully revealed above an open keyboard',
      (tester) async {
    const inset = 250.0;
    const screenHeight = 700.0;
    final client = _ScriptedClient([
      _writeCall('c1', 'logMeal', '{"dish":"Toast","calories":90}'),
      _final('Saved your toast.'),
    ]);
    await pumpCoach(tester,
        agent: agentWith(), client: client, keyboardInset: inset);
    await send(tester, 'toast');

    expect(tester.takeException(), isNull,
        reason: 'the card must not overflow with the keyboard open');
    final card = find.byType(CoachApprovalCard);
    final approve = find.widgetWithText(FilledButton, 'Approve');
    expect(card, findsOneWidget);
    expect(approve, findsOneWidget);

    // The keyboard covers the bottom [inset] pixels; the card and its action
    // row must sit entirely above that fold, not merely inside the screen.
    final fold = screenHeight - inset;
    final cardRect = tester.getRect(card);
    final approveRect = tester.getRect(approve);
    expect(cardRect.top, greaterThanOrEqualTo(0),
        reason: 'card starts above the top edge: $cardRect');
    expect(cardRect.bottom, lessThanOrEqualTo(fold),
        reason: 'card is hidden behind the keyboard: $cardRect');
    expect(approveRect.bottom, lessThanOrEqualTo(fold),
        reason: 'Approve is hidden behind the keyboard: $approveRect');
    expect(approveRect.right, lessThanOrEqualTo(412),
        reason: 'Approve is clipped off the right edge: $approveRect');
  });

  testWidgets('tapping Approve applies the pending write', (tester) async {
    final client = _ScriptedClient([
      _writeCall('c1', 'logMeal', '{"dish":"Toast","calories":90}'),
      _final('Saved your toast.'),
    ]);
    await pumpCoach(tester, agent: agentWith(), client: client);
    await send(tester, 'toast');

    expect(store.meals, isEmpty,
        reason: 'nothing may be written before the decision');
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();

    expect(store.meals, hasLength(1),
        reason: 'Approve must run the pending tool');
    expect(store.meals.single.dish, 'Toast');
    expect(store.meals.single.calories, 90);
    expect(find.byType(CoachApprovalCard), findsNothing);
    expect(find.text('Saved your toast.'), findsOneWidget);
  });

  testWidgets('tapping Cancel declines without writing', (tester) async {
    final client = _ScriptedClient([
      _writeCall('c1', 'logMeal', '{"dish":"Toast","calories":90}'),
      _final('No problem, skipped it.'),
    ]);
    await pumpCoach(tester, agent: agentWith(), client: client);
    await send(tester, 'toast');

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(store.meals, isEmpty, reason: 'Cancel must not write');
    expect(find.byType(CoachApprovalCard), findsNothing);
    expect(find.text('No problem, skipped it.'), findsOneWidget);
  });
}
