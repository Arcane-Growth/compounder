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
You are Compounder's personal life coach. Compounder tracks five pillars — workout,
nutrition, mind (mood, meditation, thought records), habits and planning (the day's
timed blocks) — plus wealth (accounts and net worth).
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
- list_habits(includeArchived): habits with cadence, target, progress and streak.
- create_habit(name, cadence, target): add a daily/weekly/monthly habit (target = days per period).
- update_habit(id, name, cadence, target, archived): change or archive a habit.
- delete_habit(id): delete a habit and its history.
- log_habit_completion(habitId, date, done): check a habit off (done true) or clear it (done false) for a day.
- habit_status(habitId, date): progress and streak for one habit or all of them.
- get_plan(date): the day's timed blocks (id, title, start/end HH:MM, done), plus the block happening now and the next one.
- create_plan_block(date, title, start, end): add a timed block to a day plan (times HH:MM, 24-hour).
- update_plan_block(id, title, start, end, done): rename, move or check off a plan block.
- delete_plan_block(id): remove a plan block.

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
- Write tools (logMeal, logMood, startWorkout, addSet, setReminder, cancelReminder, create_habit,
  update_habit, delete_habit, log_habit_completion, create_plan_block, update_plan_block,
  delete_plan_block) are shown to the
  user for approval before they run, so you do not need to ask permission first: briefly say what you
  are about to write, then call the tool. If the user declines, nothing was written — acknowledge it
  and offer an alternative.
- Format answers in markdown (headers, bullets, tables for financial projections) — the app renders it.
- If a tool returns an error, explain it to the user and ask how they'd like to proceed.
''';

  static const _maxIterations = 8;
  static const _maxHistory = 60;

  /// Hard ceiling on the tool calls kept from one model step.
  ///
  /// [_maxIterations] bounds how many steps one approval round may take, but
  /// nothing bounds how many calls a single step may return: a model can emit
  /// dozens. Without this clamp one turn could add hundreds of messages and
  /// dwarf [_maxHistory] on its own.
  ///
  /// The clamp does not keep a turn under [_maxHistory]. A turn is bounded per
  /// approval round, not in total: every [approve] re-enters the loop for up to
  /// [_maxIterations] more steps. Worst case for one approval round is a pause
  /// on the last step, which carries 7 full read steps before the pause and 8
  /// full steps after it: 1 user + 7 * (1 assistant + 5 results) + 1 assistant
  /// with 5 proposals + 5 approved results + 8 * (1 assistant + 5 results) + 1
  /// fallback = 98 messages in memory (91 on the wire: the last request is sent
  /// before the final step's assistant message, its 5 results and the fallback
  /// are added). With k approval rounds it is 98 + 48 * (k - 1) messages,
  /// unbounded in k. [_trim] keeps a single turn whole and the next user
  /// message drops it.
  static const _maxToolCallsPerIteration = 5;

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

  /// Number of messages currently held in the conversation history.
  ///
  /// Exposed so tests can assert the history bound directly: every request is
  /// preceded by a trim, so the transient over-cap state after a step-limit
  /// fallback is invisible in the sent message lists.
  int get historyLength => _history.length;

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

      // A single model step may return far more calls than the loop can
      // usefully run. Keep only the first [_maxToolCallsPerIteration] and record
      // them on the assistant message, so every tool_call_id that reaches the
      // wire is answered by exactly one tool result below. Dropped calls are
      // never sent, so no id is left dangling, and the turn keeps a hard
      // message ceiling instead of growing with the model's output.
      final calls = result.toolCalls.length > _maxToolCallsPerIteration
          ? result.toolCalls.sublist(0, _maxToolCallsPerIteration)
          : result.toolCalls;
      final dropped = result.toolCalls.length - calls.length;
      // The model needs to know it may re-issue the dropped calls; the user
      // needs to know the batch is incomplete. One sentence cannot serve both:
      // "Ask again if you still need them" is addressed to the model and reads
      // as nonsense in the user's bubble (review coach-history-followup
      // MINOR-1). Keep the model-facing variant on the wire and hand the user
      // a note without the model-directed instruction.
      final modelNote = dropped == 0
          ? result.content
          : [
              if (result.content?.trim().isNotEmpty ?? false)
                result.content!.trim(),
              '($dropped more tool call${dropped == 1 ? '' : 's'} skipped: at '
                  'most $_maxToolCallsPerIteration run per step. Ask again if '
                  'you still need them.)',
            ].join('\n\n');
      final userNote = dropped == 0
          ? result.content
          : [
              if (result.content?.trim().isNotEmpty ?? false)
                result.content!.trim(),
              '($dropped more tool call${dropped == 1 ? '' : 's'} skipped: at '
                  'most $_maxToolCallsPerIteration run per step.)',
            ].join('\n\n');
      _history.add(ChatMessage.assistant(modelNote, calls));
      final proposals = <ProposedChange>[];
      for (final call in calls) {
        final tool = tools[call.name];
        if (tool == null) {
          _history.add(ChatMessage.tool(
              call.id, '{"error":"Unknown tool ${call.name}"}'));
          continue;
        }
        Map<String, Object?> args;
        try {
          args = call.arguments.isEmpty
              ? {}
              : (jsonDecode(call.arguments) as Map).cast<String, Object?>();
        } catch (e) {
          _history.add(
              ChatMessage.tool(call.id, '{"error":"Invalid arguments: $e"}'));
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
        // Show the user the note without the model-directed sentence: when the
        // step returned more calls than the clamp allows, [userNote] carries
        // the "N more tool calls skipped" line. Passing [result.content] here
        // would hide dropped writes from the approval card.
        return CoachTurn(note: userNote, pending: _pending);
      }
    }

    const fallback =
        'I hit the step limit while working on that. Could you make the request a bit more specific?';
    _history.add(ChatMessage.assistant(fallback));
    _trim();
    return const CoachTurn(reply: fallback);
  }

  Future<String> _runTool(CoachTool tool, Map<String, Object?> args) async {
    try {
      return await tool.run(args);
    } catch (e) {
      return '{"error":"${e.toString().replaceAll('"', "'")}"}';
    }
  }

  /// Drops the oldest turns until the history fits [_maxHistory].
  ///
  /// The cut is made only at a turn boundary — an index whose message has
  /// role `user` — so the request always starts with a user message and no
  /// `tool` message is ever separated from the assistant `tool_calls` message
  /// it answers. OpenAI-compatible endpoints reject both shapes.
  ///
  /// The nearest boundary at or before the cap index is preferred, so the
  /// request keeps as much recent context as possible. When there is no such
  /// boundary the oldest turn alone reaches past the cap index; that whole turn
  /// is dropped instead of leaving the history unbounded.
  ///
  /// A history that is a single turn is kept whole rather than orphan a tool
  /// result. That turn is bounded by [_maxIterations] and
  /// [_maxToolCallsPerIteration] per approval round, so it only exceeds the cap
  /// when the user approves several rounds inside one turn — a user-driven,
  /// finite amount, not model-driven growth.
  void _trim() {
    while (_history.length > _maxHistory) {
      var start = _history.length - _maxHistory;
      while (start > 0 && _history[start].role != ChatMessage.roleUser) {
        start--;
      }
      if (start == 0) {
        start = _history.indexWhere((m) => m.role == ChatMessage.roleUser, 1);
      }
      if (start <= 0) return;
      _history.removeRange(0, start);
    }
  }
}
