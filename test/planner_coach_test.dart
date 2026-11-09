import 'dart:convert';

import 'package:compounder/coach/agent.dart';
import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature proofs for the coach planner tools: the coach can read a day's plan,
/// add, move, check off and delete blocks, every tool rejects bad input with a
/// JSON error instead of throwing, and every tool is registered in the agent
/// loop and documented in the system prompt.

class _ScriptedClient extends ChatClient {
  final List<ChatResult> script;
  final List<List<ChatMessage>> sent = [];
  int calls = 0;

  _ScriptedClient(this.script) : super('http://localhost', 'key', 'model');

  @override
  Future<ChatResult> chat(
      List<ChatMessage> messages, List<ToolSpec> tools) async {
    sent.add(messages);
    final result = script[calls < script.length ? calls : script.length - 1];
    calls++;
    return result;
  }
}

/// Runs one tool call through the agent loop. Read tools execute inline and the
/// turn finishes; write tools pause for approval, which the caller resolves.
Future<CoachTurn> _dispatch(
    CoachAgent agent, String name, Map<String, Object?> args) async {
  final client = _ScriptedClient([
    ChatResult(null, [ToolCall('call-1', name, jsonEncode(args))]),
    ChatResult('done', const []),
  ]);
  final turn = await agent.replyMessage(client, ChatMessage.user('go'));
  if (turn.isPaused) {
    expect(turn.pending!.changes.single.toolName, name);
    return agent.approve(client);
  }
  return turn;
}

/// The tool result the model was shown on the second request.
String _toolResult(_ScriptedClient client) =>
    client.sent[1].lastWhere((m) => m.role == ChatMessage.roleTool).content!;

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;
  late String path;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    path = '${await databaseFactory.getDatabasesPath()}/'
        'compounder_planner_coach_test.db';
    await databaseFactory.deleteDatabase(path);
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(path);
  });

  List<CoachTool> plannerTools({DateTime Function()? now}) => [
        GetPlanTool(store, now: now),
        CreatePlanBlockTool(store),
        UpdatePlanBlockTool(store),
        DeletePlanBlockTool(store),
      ];

  /// Asserts [result] is a JSON object carrying an `error` key.
  void expectError(String result) {
    final decoded = jsonDecode(result);
    expect(decoded, isA<Map<String, Object?>>());
    expect((decoded as Map<String, Object?>)['error'], isNotNull,
        reason: 'expected a JSON error, got: $result');
  }

  final day = DateTime(2026, 11, 9);

  group('get_plan', () {
    test('reads a day in chronological order with times and done flags',
        () async {
      await store.createPlanBlock(
          day: day, title: 'Gym', startMin: 14 * 60, endMin: 15 * 60);
      final deepWork = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 9 * 60, endMin: 10 * 60);
      await store.setPlanBlockDone(deepWork, true);

      final result = jsonDecode(
          await GetPlanTool(store, now: () => DateTime(2026, 11, 10, 12))
              .run({'date': '2026-11-09'})) as Map;
      expect(result['date'], '2026-11-09');
      expect(result['blockCount'], 2);
      expect(result['doneCount'], 1);
      final blocks = (result['blocks'] as List).cast<Map>();
      expect(blocks.map((b) => b['title']), ['Deep work', 'Gym']);
      expect(blocks.first['start'], '09:00');
      expect(blocks.first['end'], '10:00');
      expect(blocks.first['durationMinutes'], 60);
      expect(blocks.first['done'], isTrue);
      expect(blocks.last['done'], isFalse);
      // A past/future day has no "now" marker.
      expect(result.containsKey('current'), isFalse);
      expect(result.containsKey('next'), isFalse);
    });

    test('reports the current and next block for today', () async {
      final now = DateTime(2026, 11, 9, 12);
      await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 11 * 60, endMin: 13 * 60);
      await store.createPlanBlock(
          day: day, title: 'Gym', startMin: 14 * 60, endMin: 15 * 60);

      final result = jsonDecode(await GetPlanTool(store, now: () => now)
          .run({'date': '2026-11-09'})) as Map;
      expect((result['current'] as Map)['title'], 'Deep work');
      expect((result['next'] as Map)['title'], 'Gym');
    });

    test('defaults to today and rejects a malformed date', () async {
      await store.createPlanBlock(
          day: DateTime.now(),
          title: 'Today',
          startMin: 9 * 60,
          endMin: 10 * 60);
      final today = jsonDecode(await GetPlanTool(store).run({})) as Map;
      expect(today['blockCount'], 1);
      expect((today['blocks'] as List).single['title'], 'Today');

      final tool = GetPlanTool(store);
      expectError(await tool.run({'date': '2026-02-30'}));
      expectError(await tool.run({'date': '09/11/2026'}));
      expectError(await tool.run({'date': 20261109}));
    });
  });

  group('create_plan_block', () {
    test('writes a block and returns its id and fields', () async {
      final result = jsonDecode(await CreatePlanBlockTool(store).run({
        'date': '2026-11-09',
        'title': 'Deep work',
        'start': '09:00',
        'end': '10:30',
      })) as Map;
      expect(result['ok'], isTrue);
      expect(result['date'], '2026-11-09');
      expect(result['title'], 'Deep work');
      expect(result['start'], '09:00');
      expect(result['end'], '10:30');
      expect(result['durationMinutes'], 90);

      final blocks = await store.planBlocksForDay(day);
      expect(blocks.single.id, result['id']);
      expect(blocks.single.title, 'Deep work');
    });

    test('defaults the date to today', () async {
      await CreatePlanBlockTool(store)
          .run({'title': 'Walk', 'start': '07:00', 'end': '07:30'});
      final blocks = await store.planBlocksForDay(DateTime.now());
      expect(blocks.single.title, 'Walk');
    });

    test('accepts a bare minute offset as a time', () async {
      final result = jsonDecode(await CreatePlanBlockTool(store).run({
        'date': '2026-11-09',
        'title': 'Lunch',
        'start': 720,
        'end': 780,
      })) as Map;
      expect(result['start'], '12:00');
      expect(result['end'], '13:00');
    });

    test('rejects bad input with a JSON error and writes nothing', () async {
      final tool = CreatePlanBlockTool(store);
      expectError(await tool.run({'start': '09:00', 'end': '10:00'}));
      expectError(
          await tool.run({'title': '   ', 'start': '09:00', 'end': '10:00'}));
      expectError(
          await tool.run({'title': 'X', 'start': '9am', 'end': '10:00'}));
      expectError(
          await tool.run({'title': 'X', 'start': '09:00', 'end': '25:00'}));
      expectError(
          await tool.run({'title': 'X', 'start': '10:00', 'end': '09:00'}));
      expectError(
          await tool.run({'title': 'X', 'start': '09:00', 'end': '09:00'}));
      expectError(await tool.run({
        'date': '2026-02-30',
        'title': 'X',
        'start': '09:00',
        'end': '10:00',
      }));
      expectError(
          await tool.run({'title': 42, 'start': '09:00', 'end': '10:00'}));
      expect(await store.planBlocksForDay(day), isEmpty);
    });

    test('the approval summary names the title and the times', () async {
      final summary = await CreatePlanBlockTool(store).summarize({
        'date': '2026-11-09',
        'title': 'Deep work',
        'start': '09:00',
        'end': '10:00',
      });
      expect(summary, contains('Deep work'));
      expect(summary, contains('09:00–10:00'));
      expect(summary, contains('2026-11-09'));
      // Bad input must not throw out of the approval card.
      expect(await CreatePlanBlockTool(store).summarize({}), contains('?'));
    });

    test('rejects a non-finite numeric time instead of throwing', () async {
      final tool = CreatePlanBlockTool(store);
      // jsonDecode('1e999') yields Infinity; Infinity.toInt() throws
      // UnsupportedError, and summarize runs outside the tool loop's catch.
      expectError(await tool.run({'title': 'X', 'start': 1e999, 'end': 600}));
      expectError(
          await tool.run({'title': 'X', 'start': 600, 'end': double.infinity}));
      expectError(
          await tool.run({'title': 'X', 'start': double.nan, 'end': 600}));
      expect(await store.planBlocksForDay(day), isEmpty);
      // The approval card must not throw on the same input.
      expect(await tool.summarize({'title': 'X', 'start': 1e999, 'end': 600}),
          contains('?'));
    });
  });

  group('update_plan_block', () {
    test('moves a block and marks it done', () async {
      final id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 9 * 60, endMin: 10 * 60);
      final tool = UpdatePlanBlockTool(store);

      final moved = jsonDecode(await tool.run({
        'id': id,
        'start': '13:00',
        'end': '14:30',
      })) as Map;
      expect(moved['ok'], isTrue);
      expect(moved['start'], '13:00');
      expect(moved['end'], '14:30');
      expect(moved['durationMinutes'], 90);

      final done = jsonDecode(await tool.run({'id': id, 'done': true})) as Map;
      expect(done['done'], isTrue);
      final stored = await store.planBlockById(id);
      expect(stored!.done, isTrue);
      expect(stored.startMin, 13 * 60);
      expect(stored.title, 'Deep work');
    });

    test('renames without touching the times', () async {
      final id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 9 * 60, endMin: 10 * 60);
      final result = jsonDecode(await UpdatePlanBlockTool(store)
          .run({'id': id, 'title': 'Deep work (writing)'})) as Map;
      expect(result['title'], 'Deep work (writing)');
      expect(result['start'], '09:00');
    });

    test('rejects bad input with a JSON error and leaves the row intact',
        () async {
      final id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 9 * 60, endMin: 10 * 60);
      final tool = UpdatePlanBlockTool(store);
      expectError(await tool.run({}));
      expectError(await tool.run({'id': '7', 'done': true}));
      expectError(await tool.run({'id': 1e999, 'done': true}));
      expectError(await tool.run({'id': 9999, 'done': true}));
      expectError(await tool.run({'id': id}));
      expectError(await tool.run({'id': id, 'title': '  '}));
      expectError(await tool.run({'id': id, 'start': 'noon'}));
      expectError(await tool.run({'id': id, 'start': 1e999}));
      expectError(await tool.run({'id': id, 'done': 'yes'}));
      // A move that would invert the block is rejected before any write.
      expectError(await tool.run({'id': id, 'start': '11:00'}));
      final stored = await store.planBlockById(id);
      expect(stored!.title, 'Deep work');
      expect(stored.startMin, 9 * 60);
      expect(stored.endMin, 10 * 60);
      expect(stored.done, isFalse);
    });

    test('the approval summary describes the move', () async {
      final id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 9 * 60, endMin: 10 * 60);
      final summary = await UpdatePlanBlockTool(store)
          .summarize({'id': id, 'start': '13:00', 'done': true});
      expect(summary, contains('#$id'));
      expect(summary, contains('Deep work'));
      expect(summary, contains('13:00'));
      expect(summary, contains('mark done'));
      expect(await UpdatePlanBlockTool(store).summarize({}), contains('?'));
    });
  });

  group('delete_plan_block', () {
    test('deletes a block and reports what was removed', () async {
      final id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 9 * 60, endMin: 10 * 60);
      final result =
          jsonDecode(await DeletePlanBlockTool(store).run({'id': id})) as Map;
      expect(result['ok'], isTrue);
      expect(result['deleted'], id);
      expect(result['title'], 'Deep work');
      expect(await store.planBlocksForDay(day), isEmpty);
    });

    test('rejects a missing or unknown id', () async {
      final tool = DeletePlanBlockTool(store);
      expectError(await tool.run({}));
      expectError(await tool.run({'id': '7'}));
      expectError(await tool.run({'id': 1e999}));
      expectError(await tool.run({'id': 42}));
    });

    test('the approval summary names the block being deleted', () async {
      final id = await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 9 * 60, endMin: 10 * 60);
      final summary = await DeletePlanBlockTool(store).summarize({'id': id});
      expect(summary, contains('#$id'));
      expect(summary, contains('Deep work'));
      expect(await DeletePlanBlockTool(store).summarize({}), contains('?'));
    });
  });

  group('day isolation', () {
    test('reads, updates and deletes only touch the requested day', () async {
      final dayA = DateTime(2026, 11, 9);
      final dayB = DateTime(2026, 11, 10);
      final a = await store.createPlanBlock(
          day: dayA, title: 'Day A', startMin: 9 * 60, endMin: 10 * 60);
      final b = await store.createPlanBlock(
          day: dayB, title: 'Day B', startMin: 9 * 60, endMin: 10 * 60);

      // get_plan(A) must not leak B.
      final read = jsonDecode(
          await GetPlanTool(store, now: () => DateTime(2026, 11, 11, 12))
              .run({'date': '2026-11-09'})) as Map;
      expect((read['blocks'] as List).map((x) => x['title']), ['Day A']);

      // Updating an A block must leave B untouched.
      await UpdatePlanBlockTool(store).run({
        'id': a,
        'title': 'Day A moved',
        'start': '11:00',
        'end': '12:00',
      });
      final bAfterUpdate = await store.planBlockById(b);
      expect(bAfterUpdate!.title, 'Day B');
      expect(bAfterUpdate.startMin, 9 * 60);
      expect(bAfterUpdate.endMin, 10 * 60);

      // Deleting an A block must leave B intact.
      await DeletePlanBlockTool(store).run({'id': a});
      expect(await store.planBlocksForDay(dayA), isEmpty);
      final bAfterDelete = await store.planBlockById(b);
      expect(bAfterDelete, isNotNull);
      expect(bAfterDelete!.title, 'Day B');
      expect((await store.planBlocksForDay(dayB)).single.id, b);
    });
  });

  group('agent wiring', () {
    test('every planner tool is registered and dispatches by name', () async {
      final agent = CoachAgent(toolList: plannerTools());
      expect(
          agent.tools.keys,
          containsAll([
            'get_plan',
            'create_plan_block',
            'update_plan_block',
            'delete_plan_block'
          ]));

      final client = _ScriptedClient([
        ChatResult(null, [
          ToolCall('c1', 'create_plan_block',
              '{"date":"2026-11-09","title":"Deep work","start":"09:00","end":"10:00"}'),
        ]),
        ChatResult('done', const []),
      ]);
      final turn = await agent.replyMessage(client, ChatMessage.user('plan'));
      expect(turn.isPaused, isTrue);
      expect(turn.pending!.changes.single.summary, contains('Deep work'));
      expect(await store.planBlocksForDay(day), isEmpty,
          reason: 'nothing may be written before approval');

      await agent.approve(client);
      expect(await store.planBlocksForDay(day), hasLength(1));
      final result = jsonDecode(_toolResult(client)) as Map;
      expect(result['ok'], isTrue);
    });

    test('get_plan runs inline without an approval round', () async {
      await store.createPlanBlock(
          day: day, title: 'Deep work', startMin: 9 * 60, endMin: 10 * 60);
      final agent = CoachAgent(toolList: plannerTools());
      final turn = await _dispatch(agent, 'get_plan', {'date': '2026-11-09'});
      expect(turn.isPaused, isFalse);
      expect(turn.reply, 'done');
    });

    test('the system prompt documents every planner tool', () {
      for (final name in [
        'get_plan',
        'create_plan_block',
        'update_plan_block',
        'delete_plan_block',
      ]) {
        expect(CoachAgent.defaultSystemPrompt, contains(name),
            reason: '$name is registered but the model is never told about it');
      }
    });
  });
}
