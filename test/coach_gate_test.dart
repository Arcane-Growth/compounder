import 'package:compounder/coach/agent.dart';
import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/llm/llm.dart';
import 'package:compounder/ui/coach.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Scripted OpenAI-compatible client: returns the queued results in order and
/// records every message list it was asked to send, so tests can assert what
/// the model was told.
class _ScriptedClient extends ChatClient {
  final List<ChatResult> script;
  final List<List<ChatMessage>> sent = [];
  int calls = 0;

  /// When true the next [chat] call throws, simulating an unreachable endpoint.
  bool failNext = false;

  _ScriptedClient(this.script) : super('http://localhost', 'key', 'model');

  @override
  Future<ChatResult> chat(
      List<ChatMessage> messages, List<ToolSpec> tools) async {
    sent.add(messages);
    if (failNext) {
      failNext = false;
      throw Exception('connection refused');
    }
    final result = script[calls < script.length ? calls : script.length - 1];
    calls++;
    return result;
  }
}

ChatResult _writeCall(String id, String name, String args) =>
    ChatResult(null, [ToolCall(id, name, args)]);

ChatResult _final(String text) => ChatResult(text, const []);

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final path =
        '${await databaseFactory.getDatabasesPath()}/coach_gate_test.db';
    await databaseFactory.deleteDatabase(path);
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
  });

  CoachAgent agentWith(_ScriptedClient client, {void Function(String)? onToolRun}) =>
      CoachAgent(
        toolList: [
          NutritionTool(store),
          LogMealTool(store),
          LogMoodTool(store),
          StartWorkoutTool(store),
          AddSetTool(store),
        ],
        onToolRun: onToolRun,
      );

  group('write tools are gated', () {
    test('a write tool returns a proposal and does not mutate the store',
        () async {
      final client = _ScriptedClient([
        _writeCall('c1', 'logMeal',
            '{"dish":"Chicken bowl","calories":620,"protein":40,"carbs":61,"fat":18}'),
        _final('Logged it.'),
      ]);
      final agent = agentWith(client);

      final turn = await agent.replyMessage(client, ChatMessage.user('I ate a chicken bowl'));

      expect(turn.isPaused, isTrue);
      expect(turn.reply, isNull);
      expect(turn.pending!.changes, hasLength(1));
      final change = turn.pending!.changes.single;
      expect(change.toolName, 'logMeal');
      expect(change.toolCallId, 'c1');
      expect(change.summary, contains('Chicken bowl'));
      expect(change.summary, contains('620 kcal'));
      expect(change.summary, contains('40g protein'));
      expect(change.args['calories'], 620);
      expect(store.meals, isEmpty,
          reason: 'nothing may be written before approval');
      expect(client.calls, 1,
          reason: 'the loop must stop instead of asking the model again');
    });

    test('approving applies the change exactly once and returns the tool result',
        () async {
      final client = _ScriptedClient([
        _writeCall('c1', 'logMeal', '{"dish":"Toast","calories":90}'),
        _final('Saved your toast.'),
      ]);
      final agent = agentWith(client);
      await agent.replyMessage(client, ChatMessage.user('toast'));

      final turn = await agent.approve(client);

      expect(turn.isPaused, isFalse);
      expect(turn.reply, 'Saved your toast.');
      expect(store.meals, hasLength(1));
      expect(store.meals.single.dish, 'Toast');
      expect(store.meals.single.calories, 90);

      // The tool result was fed back into the conversation for the model.
      final last = client.sent.last;
      final toolMessage = last.lastWhere((m) => m.role == ChatMessage.roleTool);
      expect(toolMessage.toolCallId, 'c1');
      expect(toolMessage.content, contains('"ok":true'));
      expect(toolMessage.content, contains('Toast'));

      // Approving twice cannot write twice.
      expect(() => agent.approve(client), throwsStateError);
      expect(store.meals, hasLength(1));
    });

    test('cancelling leaves the store untouched and tells the model it was declined',
        () async {
      final client = _ScriptedClient([
        _writeCall('c1', 'logMood', '{"mood":4,"note":"good day"}'),
        _final('No problem, skipped it.'),
      ]);
      final agent = agentWith(client);
      await agent.replyMessage(client, ChatMessage.user('log my mood'));

      final turn = await agent.decline(client);

      expect(turn.isPaused, isFalse);
      expect(turn.reply, 'No problem, skipped it.');
      expect(store.moods, isEmpty, reason: 'cancel must not write');
      final toolMessage = client.sent.last
          .lastWhere((m) => m.role == ChatMessage.roleTool);
      expect(toolMessage.content, contains('"declined":true'));
      expect(toolMessage.content, contains('Nothing was written'));
      expect(() => agent.decline(client), throwsStateError);
    });

    test('several writes in one turn are gated as a single batch', () async {
      final client = _ScriptedClient([
        ChatResult(null, [
          ToolCall('c1', 'logMeal', '{"dish":"Oats","calories":300}'),
          ToolCall('c2', 'logMood', '{"mood":3}'),
        ]),
        _final('Both saved.'),
      ]);
      final agent = agentWith(client);

      final turn = await agent.replyMessage(client, ChatMessage.user('oats and mood 3'));

      expect(turn.isPaused, isTrue);
      expect(turn.pending!.changes, hasLength(2));
      expect(turn.pending!.summaries, hasLength(2));
      expect(store.meals, isEmpty);
      expect(store.moods, isEmpty);

      final approved = await agent.approve(client);
      expect(approved.reply, 'Both saved.');
      expect(store.meals, hasLength(1));
      expect(store.moods, hasLength(1));
    });

    test('addSet is gated too, so the implicit workout is not created early',
        () async {
      await store.createExercise('Barbell Bench Press', 'Chest', 'Barbell');
      final client = _ScriptedClient([
        _writeCall('c1', 'addSet',
            '{"exerciseName":"Barbell Bench Press","weightKg":80,"reps":5}'),
        _final('Set added.'),
      ]);
      final agent = agentWith(client);

      final turn = await agent.replyMessage(client, ChatMessage.user('bench 80x5'));

      expect(turn.isPaused, isTrue);
      expect(turn.pending!.changes.single.summary, contains('80 kg × 5 reps'));
      expect(await store.activeWorkout(), isNull,
          reason: 'the implicit workout must not exist before approval');
      expect(store.history, isEmpty);

      await agent.approve(client);
      final workout = await store.activeWorkout();
      expect(workout, isNotNull);
      final detail = await store.workoutDetail(workout!.id);
      expect(detail!.exercises.single.sets.single.weightKg, 80);
    });
  });

  group('read-only tools stay ungated', () {
    test('a query runs inline and the turn returns a reply', () async {
      final ran = <String>[];
      final client = _ScriptedClient([
        _writeCall('c1', 'getNutrition', '{"start":"2026-01-01","end":"2026-01-01"}'),
        _final('You logged 0 meals.'),
      ]);
      final agent = agentWith(client, onToolRun: ran.add);

      final turn = await agent.replyMessage(client, ChatMessage.user('what did I eat'));

      expect(turn.isPaused, isFalse);
      expect(turn.reply, 'You logged 0 meals.');
      expect(ran, ['getNutrition']);
      expect(client.calls, 2, reason: 'the query must run without a pause');
      final toolMessage = client.sent.last
          .lastWhere((m) => m.role == ChatMessage.roleTool);
      expect(toolMessage.content, contains('mealCount'));
    });

    test('a read and a write in the same turn: read runs, write waits', () async {
      final ran = <String>[];
      final client = _ScriptedClient([
        ChatResult(null, [
          ToolCall('c1', 'getNutrition', '{}'),
          ToolCall('c2', 'logMeal', '{"dish":"Apple","calories":95}'),
        ]),
        _final('Logged the apple.'),
      ]);
      final agent = agentWith(client, onToolRun: ran.add);

      final turn = await agent.replyMessage(client, ChatMessage.user('apple'));

      expect(turn.isPaused, isTrue);
      expect(turn.pending!.changes.single.toolName, 'logMeal');
      expect(ran, ['getNutrition']);
      expect(store.meals, isEmpty);
      expect(client.calls, 1, reason: 'the loop stops at the write');

      await agent.approve(client);
      expect(store.meals, hasLength(1));
      final toolMessages = client.sent.last
          .where((m) => m.role == ChatMessage.roleTool)
          .toList();
      expect(toolMessages.map((m) => m.toolCallId), ['c1', 'c2'],
          reason: 'the read result and the approved write result are both in '
              'the conversation, in call order');
      expect(toolMessages.first.content, contains('mealCount'));
      expect(toolMessages.last.content, contains('Apple'));
    });
  });

  group('tool classification', () {
    test('write tools are flagged and read tools are not', () {
      final writes = [
        LogMealTool(store),
        LogMoodTool(store),
        StartWorkoutTool(store),
        AddSetTool(store),
      ];
      final reads = [
        NutritionTool(store),
        NetWorthTool(store),
        MindLogTool(store),
        ListRemindersTool(store),
      ];
      for (final tool in writes) {
        expect(tool.isWrite, isTrue, reason: '${tool.spec.name} must be gated');
      }
      for (final tool in reads) {
        expect(tool.isWrite, isFalse,
            reason: '${tool.spec.name} must not be gated');
      }
    });

    test('summaries describe the change in plain language', () {
      expect(
          LogMealTool(store).summarize({
            'dish': 'Chicken bowl',
            'calories': 620,
            'protein': 40,
            'carbs': 61,
            'fat': 18,
            'date': '2026-01-02',
          }),
          'Log a meal: Chicken bowl — 620 kcal, 40g protein, 61g carbs, 18g fat (2026-01-02)');
      expect(LogMoodTool(store).summarize({'mood': 4, 'note': 'good day'}),
          'Log a mood check-in: 4/5 — "good day"');
      expect(StartWorkoutTool(store).summarize({'name': 'Push Day'}),
          'Start a workout: Push Day');
      expect(
          AddSetTool(store).summarize({
            'exerciseName': 'Barbell Bench Press',
            'weightKg': 80,
            'reps': 5,
            'isWarmup': true,
          }),
          'Add a set: Barbell Bench Press 80 kg × 5 reps (warm-up) to the active workout');
    });

    test('a malformed write argument still produces a readable summary', () {
      expect(LogMealTool(store).summarize({}), 'Log a meal: meal');
      expect(AddSetTool(store).summarize({}), contains('? kg × ? reps'));
    });
  });

  group('history', () {
    test('reset clears a pending approval', () async {
      final client = _ScriptedClient([
        _writeCall('c1', 'logMeal', '{"dish":"Toast","calories":90}'),
        _final('ok'),
      ]);
      final agent = agentWith(client);
      await agent.replyMessage(client, ChatMessage.user('toast'));
      expect(agent.pending, isNotNull);
      agent.reset();
      expect(agent.pending, isNull);
      expect(() => agent.approve(client), throwsStateError);
    });

    test('a failed follow-up after approval still reports the write landed',
        () async {
      final client = _ScriptedClient([
        _writeCall('c1', 'logMeal', '{"dish":"Toast","calories":90}'),
        _final('Saved.'),
      ]);
      final agent = agentWith(client);
      await agent.replyMessage(client, ChatMessage.user('toast'));

      // The endpoint dies between the approval and the follow-up turn.
      final dead = _ScriptedClient(const [])..failNext = true;
      final turn = await agent.approve(dead);

      expect(store.meals, hasLength(1), reason: 'the write still happened');
      expect(turn.isPaused, isFalse);
      expect(turn.reply, contains('Saved your change'));
      expect(turn.reply, contains('could not reach'));
    });
  });

  group('approval card', () {
    Future<void> pumpCard(WidgetTester tester, PendingApproval pending,
        {required VoidCallback onApprove, required VoidCallback onCancel}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CoachApprovalCard(
              pending: pending, onApprove: onApprove, onCancel: onCancel),
        ),
      ));
    }

    testWidgets('shows what will be written and offers Approve / Cancel',
        (tester) async {
      var approved = 0;
      var cancelled = 0;
      await pumpCard(
        tester,
        const PendingApproval([
          ProposedChange(
            toolCallId: 'c1',
            toolName: 'logMeal',
            summary: 'Log a meal: Chicken bowl — 620 kcal, 40g protein',
            args: {'dish': 'Chicken bowl', 'calories': 620},
          ),
        ]),
        onApprove: () => approved++,
        onCancel: () => cancelled++,
      );

      expect(find.text('The coach wants to make a change'), findsOneWidget);
      expect(find.text('Log a meal: Chicken bowl — 620 kcal, 40g protein'),
          findsOneWidget);
      expect(find.text('Nothing is saved until you approve.'), findsOneWidget);

      await tester.tap(find.text('Approve'));
      await tester.pump();
      expect(approved, 1);
      expect(cancelled, 0);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(cancelled, 1);
    });

    testWidgets('a batch is shown as one approval with every change listed',
        (tester) async {
      var approved = 0;
      await pumpCard(
        tester,
        const PendingApproval([
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
        ]),
        onApprove: () => approved++,
        onCancel: () {},
      );

      expect(find.text('The coach wants to make 2 changes'), findsOneWidget);
      expect(find.text('Log a meal: Oats — 300 kcal'), findsOneWidget);
      expect(find.text('Log a mood check-in: 3/5'), findsOneWidget);
      expect(find.text('Approve all'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);

      await tester.tap(find.text('Approve all'));
      await tester.pump();
      expect(approved, 1, reason: 'one tap approves the whole batch');
    });
  });
}
