import 'dart:convert';

import 'package:compounder/coach/agent.dart';
import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/habits.dart';
import 'package:compounder/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature 4 proofs for the coach habit tools: every tool rejects bad cadence,
/// target and date input with a JSON error instead of throwing, and every tool
/// is registered in the agent loop and dispatches by name.

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
        'compounder_habits_coach_test.db';
    await databaseFactory.deleteDatabase(path);
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(path);
  });

  List<CoachTool> habitTools() => [
        ListHabitsTool(store),
        CreateHabitTool(store),
        UpdateHabitTool(store),
        DeleteHabitTool(store),
        LogHabitCompletionTool(store),
        HabitStatusTool(store),
      ];

  /// Asserts [result] is a JSON object carrying an `error` key.
  void expectError(String result) {
    final decoded = jsonDecode(result);
    expect(decoded, isA<Map<String, Object?>>());
    expect((decoded as Map<String, Object?>)['error'], isNotNull,
        reason: 'expected a JSON error, got: $result');
  }

  group('argument validation returns JSON errors, never throws', () {
    test('create_habit rejects a missing name, bad cadence and bad target',
        () async {
      final tool = CreateHabitTool(store);
      expectError(await tool.run({}));
      expectError(await tool.run({'name': 'Read', 'cadence': 'yearly'}));
      expectError(
          await tool.run({'name': 'Read', 'cadence': 'daily', 'target': 0}));
      expectError(
          await tool.run({'name': 'Read', 'cadence': 'daily', 'target': -3}));
      // A non-string name must not raise a _TypeError.
      expectError(await tool.run({'name': 42, 'cadence': 'daily'}));
      expectError(await tool.run({'name': 'Read', 'cadence': 7}));
      // A numeric string is not an integer: reject it instead of silently
      // creating the habit with target 1 (review habit MINOR-1).
      expectError(
          await tool.run({'name': 'Read', 'cadence': 'daily', 'target': '3'}));
      expectError(
          await tool.run({'name': 'Read', 'cadence': 'daily', 'target': true}));
      expect(store.habits, isEmpty);
    });

    test('create_habit defaults the target to 1 only when it is absent',
        () async {
      final tool = CreateHabitTool(store);
      final created = jsonDecode(
          await tool.run({'name': 'Read', 'cadence': 'daily'})) as Map;
      expect(created['target'], 1);
      expect(store.habits.single.target, 1);
      // The approval preview must not claim the default when the argument is
      // present but mistyped.
      expect(
          await tool.summarize(
              {'name': 'Read', 'cadence': 'daily', 'target': '3'}),
          contains('?×'));
    });

    test('update_habit rejects missing/unknown ids and bad fields', () async {
      final tool = UpdateHabitTool(store);
      expectError(await tool.run({}));
      expectError(await tool.run({'id': 99, 'name': 'Read'}));
      final id = await store.createHabit('Read', 'daily', 1);
      expectError(await tool.run({'id': id}));
      expectError(await tool.run({'id': id, 'cadence': 'hourly'}));
      expectError(await tool.run({'id': id, 'target': 0}));
      expectError(await tool.run({'id': id, 'name': '   '}));
      expectError(await tool.run({'id': id, 'archived': 'yes'}));
      expect(store.habits.single.name, 'Read');
    });

    test('delete_habit rejects a missing or unknown id', () async {
      final tool = DeleteHabitTool(store);
      expectError(await tool.run({}));
      expectError(await tool.run({'id': 99}));
      expect(store.habits, isEmpty);
    });

    test('log_habit_completion rejects bad ids, dates and done values',
        () async {
      final tool = LogHabitCompletionTool(store);
      expectError(await tool.run({}));
      expectError(await tool.run({'habitId': 99}));
      final id = await store.createHabit('Read', 'daily', 1);
      for (final bad in ['2026-02-30', '08/11/2026', '2026-11-8', 'tomorrow']) {
        expectError(await tool.run({'habitId': id, 'date': bad}));
      }
      expectError(await tool.run({'habitId': id, 'done': 'yes'}));
      expect(store.habitCompletions, isEmpty);
    });

    test('habit_status rejects a bad date and an unknown habit id', () async {
      final tool = HabitStatusTool(store);
      expectError(await tool.run({'date': '2026-13-01'}));
      expectError(await tool.run({'habitId': 99}));
      expectError(await tool.run({'habitId': 'one'}));
    });

    test('list_habits tolerates junk arguments', () async {
      final tool = ListHabitsTool(store);
      final result = await tool.run({'includeArchived': 'yes'});
      expect(jsonDecode(result), isA<Map<String, Object?>>());
    });
  });

  group('happy path', () {
    test('create, list, log, status, update and delete through the tools',
        () async {
      final create = CreateHabitTool(store);
      final created = jsonDecode(await create
          .run({'name': 'Read', 'cadence': 'weekly', 'target': 3})) as Map;
      expect(created['ok'], isTrue);
      final id = created['id'] as int;

      final listed = jsonDecode(await ListHabitsTool(store).run({})) as Map;
      expect((listed['habits'] as List), hasLength(1));
      expect((listed['habits'] as List).single['name'], 'Read');

      // Log inside the *current* period: completedDays is progress in the
      // period containing today, so a hardcoded date falls out of the week as
      // soon as the calendar moves past it.
      final day = habitDayKey(DateTime.now());

      final logged = jsonDecode(await LogHabitCompletionTool(store).run({
        'habitId': id,
        'date': day,
        'done': true,
      })) as Map;
      expect(logged['ok'], isTrue);
      expect(logged['done'], isTrue);
      expect(logged['completedDays'], 1);

      final status = jsonDecode(await HabitStatusTool(store).run({
        'habitId': id,
        'date': day,
      })) as Map;
      expect((status['habits'] as List).single['streak'], 0,
          reason: 'one day of a three-day week is not a met period');

      final updated = jsonDecode(await UpdateHabitTool(store).run({
        'id': id,
        'name': 'Read books',
        'cadence': 'monthly',
        'target': 2,
      })) as Map;
      expect(updated['ok'], isTrue);
      expect(updated['name'], 'Read books');
      expect(updated['cadence'], 'monthly');
      expect(updated['target'], 2);

      // Unchecking clears the day.
      final cleared = jsonDecode(await LogHabitCompletionTool(store).run({
        'habitId': id,
        'date': day,
        'done': false,
      })) as Map;
      expect(cleared['done'], isFalse);
      expect(store.habitCompletions, isEmpty);

      final deleted =
          jsonDecode(await DeleteHabitTool(store).run({'id': id})) as Map;
      expect(deleted['ok'], isTrue);
      expect(store.habits, isEmpty);
    });

    test('archiving hides a habit from the default list but keeps history',
        () async {
      final id = await store.createHabit('Read', 'daily', 1);
      await store.setHabitCompletion(id, DateTime(2026, 11, 8), true);
      await UpdateHabitTool(store).run({'id': id, 'archived': true});

      final active = jsonDecode(await ListHabitsTool(store).run({})) as Map;
      expect(active['habits'], isEmpty);
      final all =
          jsonDecode(await ListHabitsTool(store).run({'includeArchived': true}))
              as Map;
      expect((all['habits'] as List).single['archived'], isTrue);
      expect(store.habitCompletions, hasLength(1));
    });
  });

  group('agent loop dispatch', () {
    test('all six habit tools are registered by name', () {
      final agent = CoachAgent(toolList: habitTools());
      expect(
          agent.tools.keys,
          containsAll(<String>[
            'list_habits',
            'create_habit',
            'update_habit',
            'delete_habit',
            'log_habit_completion',
            'habit_status',
          ]));
      expect(agent.tools, hasLength(6));
    });

    test('list_habits and habit_status run inline through the loop', () async {
      await store.createHabit('Read', 'daily', 1);
      final agent = CoachAgent(toolList: habitTools());

      final listClient = _ScriptedClient([
        ChatResult(null, [ToolCall('c1', 'list_habits', '{}')]),
        ChatResult('done', const []),
      ]);
      final listTurn =
          await agent.replyMessage(listClient, ChatMessage.user('habits'));
      expect(listTurn.reply, 'done');
      final listResult = _toolResult(listClient);
      expect(listResult, isNot(contains('Unknown tool')));
      expect(jsonDecode(listResult), isA<Map<String, Object?>>());
      expect((jsonDecode(listResult) as Map)['habits'], hasLength(1));

      final statusClient = _ScriptedClient([
        ChatResult(null, [ToolCall('c2', 'habit_status', '{}')]),
        ChatResult('done', const []),
      ]);
      final statusTurn =
          await agent.replyMessage(statusClient, ChatMessage.user('status'));
      expect(statusTurn.reply, 'done');
      final statusResult = _toolResult(statusClient);
      expect(statusResult, isNot(contains('Unknown tool')));
      expect((jsonDecode(statusResult) as Map)['habits'], hasLength(1));
    });

    test('create_habit pauses for approval and writes on approve', () async {
      final agent = CoachAgent(toolList: habitTools());
      final client = _ScriptedClient([
        ChatResult(null, [
          ToolCall('c1', 'create_habit',
              '{"name":"Read","cadence":"daily","target":1}')
        ]),
        ChatResult('Created.', const []),
      ]);
      final turn =
          await agent.replyMessage(client, ChatMessage.user('add a habit'));
      expect(turn.isPaused, isTrue);
      expect(turn.pending!.changes.single.toolName, 'create_habit');
      expect(turn.pending!.changes.single.summary, contains('Read'));
      expect(store.habits, isEmpty, reason: 'nothing written before approval');

      final approved = await agent.approve(client);
      expect(approved.reply, 'Created.');
      expect(store.habits, hasLength(1));
      expect(_toolResult(client), isNot(contains('Unknown tool')));
    });

    test('update_habit, log_habit_completion and delete_habit dispatch',
        () async {
      final id = await store.createHabit('Read', 'daily', 1);
      final agent = CoachAgent(toolList: habitTools());

      await _dispatch(agent, 'update_habit', {'id': id, 'name': 'Read books'});
      expect(store.habits.single.name, 'Read books');

      await _dispatch(agent, 'log_habit_completion', {
        'habitId': id,
        'date': '2026-11-08',
        'done': true,
      });
      expect(store.habitCompletions, hasLength(1));

      await _dispatch(agent, 'delete_habit', {'id': id});
      expect(store.habits, isEmpty);
      expect(store.habitCompletions, isEmpty);
    });
  });
}
