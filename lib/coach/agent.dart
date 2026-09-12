import 'dart:convert';

import '../llm/llm.dart';

/// A tool the coach agent can invoke.
abstract class CoachTool {
  ToolSpec get spec;
  Future<String> run(Map<String, Object?> args);
}

/// Runs the tool-calling loop until the model produces a final answer.
class CoachAgent {
  static const defaultSystemPrompt = '''
You are Compounder's personal life coach. Compounder compounds four areas of life:
health (lifting + nutrition), wealth (accounts and net worth), and mind (mood, meditation, thought records).
Help the user understand and improve all of them using only the data you fetch from tools.

TOOLS
- getNutrition(start, end): every logged meal with calories/protein/carbs/fat.
- getWorkouts(start, end): all finished workouts with exercises, sets (kg), and volume.
- getExerciseProgress(exerciseName, start, end): best estimated 1RM per session for one exercise.
- getNetWorth(): current accounts, balances and total net worth.
- getNetWorthHistory(): monthly net worth trend from balance snapshots.
- projectUpside(mode grow|payoff, ...): future-value projections and debt payoff math.
- getMindLog(start, end): mood check-ins, meditation minutes and thought records.
- setReminder(text, when|inMinutes) / listReminders() / cancelReminder(id): device reminders.
- logMeal(dish, calories, protein, carbs, fat, date): add a nutrition entry (date YYYY-MM-DD).
- logMood(mood, note, date): log a mood check-in (mood is 1 rough .. 5 great).
- startWorkout(name): create a new active workout.
- addSet(exerciseName, weightKg, reps, isWarmup, workoutId): add a completed set.

ATTACHMENTS
- The user can attach files to their messages: photos, PDFs (rendered as page images) and
  text files like CSV. When a message contains attached content, read it carefully and base
  your answer on it. For CSVs, parse the columns before summarizing.

RULES
- Always fetch real data before giving numbers or advice; never invent figures.
- Dates are YYYY-MM-DD. If no range is given, use a sensible default (today or the last 7 days).
- Weights are stored and reported in kg. Note the unit when quoting them.
- Be concise and concrete: summarize totals and trends, and give one actionable suggestion with reasons.
- Before any write tool (logMeal, logMood, startWorkout, addSet, setReminder), first briefly tell
  the user what you're about to do and confirm with them before calling it. After writing, confirm the change.
- Format answers in markdown (headers, bullets, tables for financial projections) — the app renders it.
- If a tool returns an error, explain it to the user and ask how they'd like to proceed.
''';

  static const _maxIterations = 8;
  static const _maxHistory = 60;

  final Map<String, CoachTool> tools;
  final void Function(String toolName)? onToolRun;
  final String systemPrompt;
  final List<ChatMessage> _history = [];

  CoachAgent({required List<CoachTool> toolList, this.onToolRun, this.systemPrompt = defaultSystemPrompt})
      : tools = {for (final t in toolList) t.spec.name: t};

  void reset() => _history.clear();

  Future<String> replyMessage(ChatClient client, ChatMessage message) async {
    _history.add(message);
    _trim();

    for (var i = 0; i < _maxIterations; i++) {
      final result = await client.chat(
        [ChatMessage.system(systemPrompt), ..._history],
        tools.values.map((t) => t.spec).toList(),
      );

      if (result.toolCalls.isEmpty) {
        final text = (result.content?.trim().isNotEmpty ?? false) ? result.content! : 'Done.';
        _history.add(ChatMessage.assistant(text));
        _trim();
        return text;
      }

      _history.add(ChatMessage.assistant(null, result.toolCalls));
      for (final call in result.toolCalls) {
        onToolRun?.call(call.name);
        _history.add(ChatMessage.tool(call.id, await _execute(call)));
      }
      _trim();
    }

    const fallback = 'I hit the step limit while working on that. Could you make the request a bit more specific?';
    _history.add(ChatMessage.assistant(fallback));
    return fallback;
  }

  Future<String> _execute(ToolCall call) async {
    final tool = tools[call.name];
    if (tool == null) return '{"error":"Unknown tool ${call.name}"}';
    Map<String, Object?> args;
    try {
      args = call.arguments.isEmpty
          ? {}
          : (jsonDecode(call.arguments) as Map).cast<String, Object?>();
    } catch (e) {
      return '{"error":"Invalid arguments: $e"}';
    }
    try {
      return await tool.run(args);
    } catch (e) {
      return '{"error":"${e.toString().replaceAll('"', "'")}"}';
    }
  }

  void _trim() {
    while (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
  }
}
