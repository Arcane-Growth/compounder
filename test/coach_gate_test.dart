import 'package:compounder/coach/agent.dart';
import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/models.dart';
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

/// A step that asks for [count] read calls, all of which run inline.
ChatResult _reads(String prefix, {int count = 5}) => ChatResult(null, [
      for (var i = 0; i < count; i++)
        ToolCall('$prefix$i', 'getNutrition',
            '{"start":"2026-01-01","end":"2026-01-01"}'),
    ]);

/// A step that asks for [count] write calls, so the loop pauses for approval.
ChatResult _writes(String prefix, {int count = 5}) => ChatResult('On it.', [
      for (var i = 0; i < count; i++)
        ToolCall(
            '$prefix$i', 'logMeal', '{"dish":"Meal $prefix$i","calories":100}'),
    ]);

/// Largest conversation the model was ever sent (system prompt excluded).
int _peakSent(_ScriptedClient client) {
  var peak = 0;
  for (final sent in client.sent) {
    final n = sent.where((m) => m.role != ChatMessage.roleSystem).length;
    if (n > peak) peak = n;
  }
  return peak;
}

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

  CoachAgent agentWith(_ScriptedClient client,
          {void Function(String)? onToolRun}) =>
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

      final turn = await agent.replyMessage(
          client, ChatMessage.user('I ate a chicken bowl'));

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

    test(
        'approving applies the change exactly once and returns the tool result',
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

    test(
        'cancelling leaves the store untouched and tells the model it was declined',
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
      final toolMessage =
          client.sent.last.lastWhere((m) => m.role == ChatMessage.roleTool);
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

      final turn =
          await agent.replyMessage(client, ChatMessage.user('oats and mood 3'));

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

      final turn =
          await agent.replyMessage(client, ChatMessage.user('bench 80x5'));

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
        _writeCall(
            'c1', 'getNutrition', '{"start":"2026-01-01","end":"2026-01-01"}'),
        _final('You logged 0 meals.'),
      ]);
      final agent = agentWith(client, onToolRun: ran.add);

      final turn =
          await agent.replyMessage(client, ChatMessage.user('what did I eat'));

      expect(turn.isPaused, isFalse);
      expect(turn.reply, 'You logged 0 meals.');
      expect(ran, ['getNutrition']);
      expect(client.calls, 2, reason: 'the query must run without a pause');
      final toolMessage =
          client.sent.last.lastWhere((m) => m.role == ChatMessage.roleTool);
      expect(toolMessage.content, contains('mealCount'));
    });

    test('a read and a write in the same turn: read runs, write waits',
        () async {
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

    test(
        'trimming cuts on turn boundaries: the request starts with a user '
        'message and never orphans a tool result', () async {
      // 12 turns of (user, assistant with 4 tool calls, 4 tool results, final)
      // = 84 messages, well past the 60-message cap. Trimming by raw count
      // used to leave a tool result at the head of the request.
      final script = <ChatResult>[];
      for (var turn = 0; turn < 12; turn++) {
        script.add(ChatResult(null, [
          for (var i = 0; i < 4; i++)
            ToolCall('t${turn}c$i', 'getNutrition',
                '{"start":"2026-01-01","end":"2026-01-01"}'),
        ]));
        script.add(_final('turn $turn done'));
      }
      final client = _ScriptedClient(script);
      final agent = agentWith(client);

      for (var turn = 0; turn < 12; turn++) {
        await agent.replyMessage(client, ChatMessage.user('question $turn'));
      }

      expect(client.sent, hasLength(24));
      for (final sent in client.sent) {
        // _loop prepends the system prompt; the conversation itself must open
        // with a user message.
        final history =
            sent.where((m) => m.role != ChatMessage.roleSystem).toList();
        expect(history.first.role, ChatMessage.roleUser,
            reason: 'every request must open with a user message');
        // A tool result may only follow the assistant message whose tool_calls
        // it answers; a user message starts a fresh turn.
        final answered = <String>{};
        for (var i = 0; i < history.length; i++) {
          final m = history[i];
          if (m.role == ChatMessage.roleAssistant) {
            answered.addAll(m.toolCalls.map((c) => c.id));
          } else if (m.role == ChatMessage.roleTool) {
            expect(answered, contains(m.toolCallId),
                reason: 'tool ${m.toolCallId} at index $i has no preceding '
                    'assistant tool_calls message');
          } else if (m.role == ChatMessage.roleUser) {
            answered.clear();
          }
        }
      }

      // The trim did run, and it kept the history near the cap instead of
      // dropping messages one at a time.
      final last = client.sent.last
          .where((m) => m.role != ChatMessage.roleSystem)
          .toList();
      expect(last.length, lessThan(84), reason: 'the cap must still apply');
      expect(last.length, lessThanOrEqualTo(66),
          reason: 'at most one turn (7 messages) may be kept past the cap');
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

    test(
        'an oversized turn is clamped and history stays bounded across 40 '
        'turns', () async {
      // The model asks for 100 tool calls on every one of the 8 iterations, so
      // the turn alone would be 1 + 8 * (1 + 100) + 1 = 810 messages. Nothing
      // used to cap calls per iteration, and _trim bailed out when the walk
      // found no user boundary at or before the cap index, so the history grew
      // to ~2x the cap and stayed there for dozens of turns.
      await store.addMeal(Meal(
        id: 0,
        timestamp: DateTime(2026, 1, 1, 12).millisecondsSinceEpoch,
        imagePath: '',
        dish: 'Chicken bowl',
        calories: 620,
        protein: 40,
        carbs: 61,
        fat: 18,
      ));
      final script = <ChatResult>[
        for (var iteration = 0; iteration < 8; iteration++)
          ChatResult(null, [
            for (var i = 0; i < 100; i++)
              ToolCall('i${iteration}c$i', 'getNutrition',
                  '{"start":"2026-01-01","end":"2026-01-01"}'),
          ]),
        _final('done'),
      ];
      final client = _ScriptedClient(script);
      final agent = agentWith(client);

      await agent.replyMessage(client, ChatMessage.user('huge turn'));
      for (var turn = 0; turn < 40; turn++) {
        await agent.replyMessage(client, ChatMessage.user('question $turn'));
      }

      // _maxHistory is 60. Every request must stay at or under it: the clamp
      // bounds a turn, and _trim drops whole turns when the head has no
      // boundary to cut at.
      var peak = 0;
      for (final sent in client.sent) {
        final history =
            sent.where((m) => m.role != ChatMessage.roleSystem).toList();
        if (history.length > peak) peak = history.length;

        expect(history.first.role, ChatMessage.roleUser,
            reason: 'every request must open with a user message');
        final answered = <String>{};
        for (var i = 0; i < history.length; i++) {
          final m = history[i];
          if (m.role == ChatMessage.roleAssistant) {
            answered.addAll(m.toolCalls.map((c) => c.id));
          } else if (m.role == ChatMessage.roleTool) {
            expect(answered, contains(m.toolCallId),
                reason: 'tool ${m.toolCallId} at index $i has no preceding '
                    'assistant tool_calls message');
          } else if (m.role == ChatMessage.roleUser) {
            answered.clear();
          }
        }
      }

      expect(peak, lessThanOrEqualTo(60),
          reason: 'peak history must stay within _maxHistory (60)');
    });

    test('tool calls beyond the per-iteration cap are dropped and reported',
        () async {
      final client = _ScriptedClient([
        ChatResult('Looking that up.', [
          for (var i = 0; i < 20; i++)
            ToolCall('c$i', 'getNutrition',
                '{"start":"2026-01-01","end":"2026-01-01"}'),
        ]),
        _final('done'),
      ]);
      final agent = agentWith(client);

      await agent.replyMessage(client, ChatMessage.user('many calls'));

      // The assistant message the model is shown carries only the calls that
      // actually ran, so no tool_call_id is left dangling.
      final first = client.sent[1]
          .where((m) => m.role != ChatMessage.roleSystem)
          .toList();
      final assistant =
          first.firstWhere((m) => m.role == ChatMessage.roleAssistant);
      expect(assistant.toolCalls, hasLength(5),
          reason: 'at most 5 calls may run per iteration');
      expect(
          assistant.toolCalls.map((c) => c.id), ['c0', 'c1', 'c2', 'c3', 'c4']);
      expect(assistant.content, contains('15 more tool calls skipped'));
      expect(
          first
              .where((m) => m.role == ChatMessage.roleTool)
              .map((m) => m.toolCallId),
          ['c0', 'c1', 'c2', 'c3', 'c4'],
          reason: 'every kept call gets exactly one result');
    });

    test('the skip note reaches the user when writes are dropped', () async {
      // 8 logMeal calls: 5 are proposed, 3 are dropped. The approval card must
      // say so — otherwise the user approves a batch believing it is complete
      // and the 3 dropped writes are silently lost if the model answers instead
      // of re-issuing them.
      final client = _ScriptedClient([
        _writes('c', count: 8),
        _final('All done.'),
      ]);
      final agent = agentWith(client);

      final turn = await agent.replyMessage(client, ChatMessage.user('log 8'));

      expect(turn.isPaused, isTrue);
      expect(turn.pending!.changes, hasLength(5));
      expect(turn.note, isNotNull,
          reason: 'the user must be told that calls were skipped');
      expect(turn.note, contains('3 more tool calls skipped'));
      expect(turn.note, contains('On it.'),
          reason: 'the model text is kept alongside the skip note');
      expect(turn.note, isNot(contains('Ask again if you still need them')),
          reason: 'the model-directed sentence must not leak into the user '
              'bubble');
      // The model sees the same skip count plus the instruction to re-issue
      // the dropped calls; the user-facing note deliberately omits it.
      await agent.approve(client);
      final sent = client.sent.last
          .where((m) => m.role != ChatMessage.roleSystem)
          .toList();
      final assistant =
          sent.lastWhere((m) => m.role == ChatMessage.roleAssistant);
      expect(assistant.content, contains('3 more tool calls skipped'),
          reason: 'the wire note must still tell the model calls were dropped');
      expect(assistant.content, contains('On it.'),
          reason: 'the model text is kept on the wire');
      expect(assistant.content, contains('Ask again if you still need them'),
          reason: 'the model needs the instruction to re-issue dropped calls');
      expect(assistant.content, isNot(turn.note),
          reason: 'the user note and the wire note are intentionally different '
              'when calls are dropped');
    });

    test('a single approval round peaks at the documented 91-message request',
        () async {
      // Worst case for one approval round: pause on the last iteration, so the
      // turn carries 7 full read iterations before the pause and 8 after the
      // approval. 98 messages in memory, 91 on the wire (the final fallback is
      // never sent). This is the bound documented on
      // _maxToolCallsPerIteration; the old comment claimed 56.
      final script = <ChatResult>[
        for (var i = 0; i < 7; i++) _reads('r$i', count: 8),
        _writes('w', count: 8),
        for (var i = 0; i < 8; i++) _reads('a$i', count: 8),
        _final('done'),
      ];
      final client = _ScriptedClient(script);
      final agent = agentWith(client);

      final paused = await agent.replyMessage(client, ChatMessage.user('go'));
      expect(paused.isPaused, isTrue);
      expect(paused.pending!.changes, hasLength(5));

      final resumed = await agent.approve(client);
      expect(resumed.reply, contains('step limit'),
          reason: 'the 8 post-approval iterations exhaust the loop');

      expect(agent.historyLength, 98,
          reason: 'one approval round is 98 messages in memory');
      expect(_peakSent(client), 91,
          reason: 'the largest request sent is 91 messages');
    });

    test(
        'two approval rounds peak at 98 + 48 = 146 in memory / 139 on the wire',
        () async {
      // k approval rounds cost 98 + 48*(k-1) messages: each extra round adds 7
      // read iterations (42 messages) plus its own pause step (1 assistant + 5
      // approved results = 6) before the final 8 iterations. The turn is not
      // bounded by _maxHistory; _trim keeps it whole and the next user message
      // drops it.
      final script = <ChatResult>[
        for (var i = 0; i < 7; i++) _reads('r$i', count: 8),
        _writes('w1', count: 8),
        for (var i = 0; i < 7; i++) _reads('a$i', count: 8),
        _writes('w2', count: 8),
        for (var i = 0; i < 8; i++) _reads('b$i', count: 8),
        _final('done'),
      ];
      final client = _ScriptedClient(script);
      final agent = agentWith(client);

      final first = await agent.replyMessage(client, ChatMessage.user('go'));
      expect(first.isPaused, isTrue);

      final second = await agent.approve(client);
      expect(second.isPaused, isTrue,
          reason: 'the second round pauses again for approval');

      final third = await agent.approve(client);
      expect(third.reply, contains('step limit'));

      expect(agent.historyLength, 146,
          reason: 'k=2 is 98 + 48*(2-1) = 146 messages in memory');
      expect(_peakSent(client), 139,
          reason: 'the largest request sent is 139 messages');

      // The oversized turn is kept whole, then dropped by the next user
      // message: the request after it carries only the new user message.
      await agent.replyMessage(client, ChatMessage.user('next question'));
      final after = client.sent.last
          .where((m) => m.role != ChatMessage.roleSystem)
          .toList();
      expect(after, hasLength(1),
          reason: 'the oversized turn must be dropped, not trimmed mid-turn');
      expect(after.single.role, ChatMessage.roleUser);
    });

    test('the step-limit fallback is trimmed like every other exit path',
        () async {
      // Five prior turns of 4 read calls each leave the history at 35 messages.
      // The fallback turn then adds a user message and 8 iterations of 2 calls
      // (24 messages), reaching 60, and the fallback assistant message makes 61
      // — one over the cap. Without _trim() on that path the history stays at
      // 61 until the next turn; with it the oldest turn (7 messages) is dropped
      // and the history is 54.
      final script = <ChatResult>[
        for (var turn = 0; turn < 5; turn++) ...[
          _reads('p${turn}_', count: 4),
          _final('turn $turn done'),
        ],
        for (var i = 0; i < 8; i++) _reads('r$i', count: 2),
        _final('unused'),
      ];
      final client = _ScriptedClient(script);
      final agent = agentWith(client);

      for (var turn = 0; turn < 5; turn++) {
        await agent.replyMessage(client, ChatMessage.user('question $turn'));
      }
      expect(agent.historyLength, 35, reason: '5 turns of 7 messages');

      final turn = await agent.replyMessage(client, ChatMessage.user('go'));
      expect(turn.reply, contains('step limit'));
      expect(agent.historyLength, 54,
          reason: 'the fallback path must trim: without it the history is 61, '
              'one message over the cap');
    });
  });

  group('approval card', () {
    Future<void> pumpCard(WidgetTester tester, PendingApproval pending,
        {required VoidCallback onApprove,
        required VoidCallback onCancel}) async {
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
