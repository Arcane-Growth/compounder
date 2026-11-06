import 'dart:convert';

import '../llm/llm.dart';

/// A tool the coach agent can invoke.
abstract class CoachTool {
  ToolSpec get spec;

  /// True when [run] mutates stored data. Write tools are never executed on the
  /// model's turn: the agent proposes them and waits for the user's approval.
  bool get isWrite => false;

  /// Plain-language description of what [run] would change, shown in the
  /// approval card. Only meaningful for write tools.
  String summarize(Map<String, Object?> args) => spec.name;

  Future<String> run(Map<String, Object?> args);
}

/// A write the model asked for but that has not run yet.
class ProposedChange {
  final String toolCallId;
  final String toolName;
  final String summary;
  final Map<String, Object?> args;

  const ProposedChange({
    required this.toolCallId,
    required this.toolName,
    required this.summary,
    required this.args,
  });
}

/// One or more writes awaiting the user's approval. Batched so a single turn
/// that emits several writes needs exactly one decision.
class PendingApproval {
  final List<ProposedChange> changes;
  const PendingApproval(this.changes);

  List<String> get summaries => [for (final c in changes) c.summary];
}

/// Result of one agent step: either a final answer, or a pause for approval.
class CoachTurn {
  /// Assistant text produced alongside the pending tool calls, if any.
  final String? note;

  /// Final assistant answer. Null when the turn paused for approval.
  final String? reply;

  /// Writes waiting for the user. Null when the turn finished.
  final PendingApproval? pending;

  const CoachTurn({this.note, this.reply, this.pending});

  bool get isPaused => pending != null;
}

/// Runs the tool-calling loop until the model produces a final answer.
///
/// Read-only tools run inline. Write tools are never run on the model's turn:
/// the loop stops, returns a [PendingApproval] to the caller, and only
/// [approve] executes them. [decline] discards them and tells the model the
/// user said no.
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
- getHealthOverview(start, end): Health Connect summary — sleep, heart rate, activity, body and vitals.
- getSleep(start, end): per-night sleep stages, bedtime, wake time and efficiency.
- getHeartRate(start, end, includeHourly): daily heart rate, resting HR, HRV and optional hourly averages.
- getHealthMetric(metric, start, end): any imported Health Connect metric (steps, weight, SpO2, glucose, etc.).
- getHealthWorkouts(start, end): exercise sessions imported from Health Connect.
- getHealthSyncStatus(): whether Health Connect is connected, last sync and available metrics.
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
- Health Connect data is imported from the user's Android device. For recovery, sleep, training readiness
  and heart questions, fetch health tools first. Sleep is reported in minutes/hours, heart rate in bpm,
  distance in metres and energy in kcal. If health data is missing or stale, say so and suggest
  connecting or syncing Health Connect in Settings; never invent health figures.
- Be concise and concrete: summarize totals and trends, and give one actionable suggestion with reasons.
- Write tools (logMeal, logMood, startWorkout, addSet, setReminder, cancelReminder) are shown to the
  user for approval before they run, so you do not need to ask permission first: briefly say what you
  are about to write, then call the tool. If the user declines, nothing was written — acknowledge it
  and offer an alternative.
- Format answers in markdown (headers, bullets, tables for financial projections) — the app renders it.
- If a tool returns an error, explain it to the user and ask how they'd like to proceed.
''';

  static const _maxIterations = 8;
  static const _maxHistory = 60;

  final Map<String, CoachTool> tools;
  final void Function(String toolName)? onToolRun;
  final String systemPrompt;
  final List<ChatMessage> _history = [];
  PendingApproval? _pending;

  CoachAgent(
      {required List<CoachTool> toolList,
      this.onToolRun,
      this.systemPrompt = defaultSystemPrompt})
      : tools = {for (final t in toolList) t.spec.name: t};

  /// Writes waiting for the user's decision, if the last turn paused.
  PendingApproval? get pending => _pending;

  void reset() {
    _history.clear();
    _pending = null;
  }

  Future<CoachTurn> replyMessage(ChatClient client, ChatMessage message) async {
    _pending = null;
    _history.add(message);
    _trim();
    return _loop(client);
  }

  /// Runs the pending writes, feeds their results back to the model and
  /// continues the conversation. Throws [StateError] when nothing is pending,
  /// so a double tap cannot write twice.
  Future<CoachTurn> approve(ChatClient client) async {
    final pending = _pending;
    if (pending == null) {
      throw StateError('No pending change to approve');
    }
    _pending = null;
    for (final change in pending.changes) {
      final tool = tools[change.toolName];
      final result = tool == null
          ? '{"error":"Unknown tool ${change.toolName}"}'
          : await _runTool(tool, change.args);
      _history.add(ChatMessage.tool(change.toolCallId, result));
    }
    _trim();
    return _continue(client, applied: pending.changes.length);
  }

  /// Discards the pending writes without touching the store and tells the model
  /// the user declined, so it can respond sensibly.
  Future<CoachTurn> decline(ChatClient client) async {
    final pending = _pending;
    if (pending == null) {
      throw StateError('No pending change to decline');
    }
    _pending = null;
    for (final change in pending.changes) {
      _history.add(ChatMessage.tool(
        change.toolCallId,
        jsonEncode({
          'ok': false,
          'declined': true,
          'message': 'The user declined this change. Nothing was written.',
        }),
      ));
    }
    _trim();
    return _continue(client, applied: 0);
  }

  /// Resumes the loop after a decision. The writes have already been applied
  /// (or declined), so a failure to reach the model must not surface as a bare
  /// error: the user needs to know the change landed.
  Future<CoachTurn> _continue(ChatClient client, {required int applied}) async {
    try {
      return await _loop(client);
    } catch (e) {
      final text = applied > 0
          ? 'Saved ${applied == 1 ? 'your change' : '$applied changes'}, but I could not reach the AI endpoint to continue: $e'
          : 'Nothing was written. I could not reach the AI endpoint to continue: $e';
      _history.add(ChatMessage.assistant(text));
      _trim();
      return CoachTurn(reply: text);
    }
  }

  Future<CoachTurn> _loop(ChatClient client) async {
    for (var i = 0; i < _maxIterations; i++) {
      final result = await client.chat(
        [ChatMessage.system(systemPrompt), ..._history],
        tools.values.map((t) => t.spec).toList(),
      );

      if (result.toolCalls.isEmpty) {
        final text = (result.content?.trim().isNotEmpty ?? false)
            ? result.content!
            : 'Done.';
        _history.add(ChatMessage.assistant(text));
        _trim();
        return CoachTurn(reply: text);
      }

      _history.add(ChatMessage.assistant(result.content, result.toolCalls));
      final proposals = <ProposedChange>[];
      for (final call in result.toolCalls) {
        final tool = tools[call.name];
        if (tool == null) {
          _history.add(
              ChatMessage.tool(call.id, '{"error":"Unknown tool ${call.name}"}'));
          continue;
        }
        Map<String, Object?> args;
        try {
          args = call.arguments.isEmpty
              ? {}
              : (jsonDecode(call.arguments) as Map).cast<String, Object?>();
        } catch (e) {
          _history
              .add(ChatMessage.tool(call.id, '{"error":"Invalid arguments: $e"}'));
          continue;
        }
        if (!tool.isWrite) {
          onToolRun?.call(call.name);
          _history.add(ChatMessage.tool(call.id, await _runTool(tool, args)));
          continue;
        }
        proposals.add(ProposedChange(
          toolCallId: call.id,
          toolName: call.name,
          summary: tool.summarize(args),
          args: args,
        ));
      }
      _trim();

      if (proposals.isNotEmpty) {
        _pending = PendingApproval(proposals);
        return CoachTurn(note: result.content, pending: _pending);
      }
    }

    const fallback =
        'I hit the step limit while working on that. Could you make the request a bit more specific?';
    _history.add(ChatMessage.assistant(fallback));
    return const CoachTurn(reply: fallback);
  }

  Future<String> _runTool(CoachTool tool, Map<String, Object?> args) async {
    try {
      return await tool.run(args);
    } catch (e) {
      return '{"error":"${e.toString().replaceAll('"', "'")}"}';
    }
  }

  /// Drops the oldest turns once the history exceeds [_maxHistory].
  ///
  /// The cut is made only at a turn boundary — an index whose message has
  /// role `user` — so the request always starts with a user message and no
  /// `tool` message is ever separated from the assistant `tool_calls` message
  /// it answers. OpenAI-compatible endpoints reject both shapes.
  void _trim() {
    if (_history.length <= _maxHistory) return;

    // Walk back from the newest index that would satisfy the size cap to the
    // nearest turn boundary at or before it.
    var start = _history.length - _maxHistory;
    while (start > 0 && _history[start].role != ChatMessage.roleUser) {
      start--;
    }
    // A single turn longer than the cap has no boundary to cut at: keep it
    // whole rather than orphan a tool result. Growth is bounded by
    // _maxIterations and the tools per turn.
    if (start == 0) return;
    _history.removeRange(0, start);
  }
}
