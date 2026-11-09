import 'dart:convert';

import '../data/models.dart';
import '../services/notify.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import '../domain/habits.dart';
import '../domain/plan.dart';
import '../llm/llm.dart';
import 'agent.dart';

/// Inclusive day range for a coach tool call.
///
/// [now] is injectable so the DST regression tests can pin the default window
/// without depending on the wall clock.
({int from, int to}) dateRange(Map<String, Object?> args, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final startRaw = args['start'] as String?;
  final start = DateTime.tryParse(startRaw ?? '') ?? today;
  final end = DateTime.tryParse(args['end'] as String? ?? '') ?? (startRaw == null ? today : start);
  final lo = end.isBefore(start) ? end : start;
  final hi = end.isBefore(start) ? start : end;
  return (
    from: DateTime(lo.year, lo.month, lo.day).millisecondsSinceEpoch,
    to: DateTime(hi.year, hi.month, hi.day + 1).millisecondsSinceEpoch,
  );
}

String isoDate(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Default window for [MindLogTool] when the model omits both dates: local
/// midnight six calendar days back up to local midnight tomorrow, exclusive.
///
/// Calendar arithmetic, not `Duration(days: 6)`: a 144-hour subtraction from
/// midnight lands on 23:00/01:00 across a DST boundary. Extracted so the DST
/// regression tests can pin it (audit m3-dst MINOR-4).
({int from, int to}) mindLogWindow(DateTime now) => (
      from: DateTime(now.year, now.month, now.day - 6).millisecondsSinceEpoch,
      to: DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch,
    );

String num1(double v) => trimZero(v);

/// Reads a numeric argument without throwing when the model omits or mistypes
/// it; summaries must never fail on bad input.
///
/// `args[key] as num?` would throw a `_TypeError` on a string, and
/// [CoachTool.summarize] runs outside the tool loop's try/catch, so a mistyped
/// argument would surface as a raw error string in the user's chat bubble
/// (review b2b3b4m1 NIT-5).
double? _num(Map<String, Object?> args, String key) {
  final value = args[key];
  return value is num ? value.toDouble() : null;
}

int? _int(Map<String, Object?> args, String key) {
  final value = args[key];
  // `jsonDecode('1e999')` yields Infinity; `Infinity.toInt()` throws
  // UnsupportedError, and [CoachTool.summarize] runs outside the tool loop's
  // try/catch, so a non-finite number must read as "absent" here.
  if (value is! num || !value.isFinite) return null;
  return value.toInt();
}

String _text(Map<String, Object?> args, String key) =>
    (args[key] as String?)?.trim() ?? '';

final dateRangeSchema = {
  'type': 'object',
  'properties': {
    'start': {'type': 'string', 'description': 'Start date (inclusive), YYYY-MM-DD'},
    'end': {'type': 'string', 'description': 'End date (inclusive), YYYY-MM-DD. Defaults to start.'},
  },
};

class NutritionTool extends CoachTool {
  final AppStore store;
  NutritionTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('getNutrition',
      'Get nutrition (meal) data for a date range: every logged meal (dish, calories, protein, carbs, fat) and totals. Dates YYYY-MM-DD; omitted = today.',
      dateRangeSchema);

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = dateRange(args);
    final meals = store.meals.where((m) => m.timestamp >= r.from && m.timestamp < r.to).toList();
    return jsonEncode({
      'from': isoDate(r.from),
      'to': isoDate(r.to - 1),
      'mealCount': meals.length,
      'totals': {
        'calories': num1(meals.fold(0.0, (a, m) => a + m.calories)),
        'protein': num1(meals.fold(0.0, (a, m) => a + m.protein)),
        'carbs': num1(meals.fold(0.0, (a, m) => a + m.carbs)),
        'fat': num1(meals.fold(0.0, (a, m) => a + m.fat)),
      },
      'meals': meals
          .map((m) => {
                'date': isoDate(m.timestamp),
                'dish': m.dish,
                'calories': num1(m.calories),
                'protein': num1(m.protein),
                'carbs': num1(m.carbs),
                'fat': num1(m.fat),
              })
          .toList(),
    });
  }
}

class WorkoutTool extends CoachTool {
  final AppStore store;
  WorkoutTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('getWorkouts',
      'Get finished workouts for a date range: each with exercises, sets (weight kg, reps, warmup) and total volume. Dates YYYY-MM-DD; omitted = today.',
      dateRangeSchema);

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = dateRange(args);
    final rows = await store.finishedWorkoutRows(r.from, r.to);
    final workouts = <Map<String, Object?>>[];
    for (final w in rows) {
      final exerciseRows = await store.workoutExerciseRows(w['id'] as int);
      var volume = 0.0;
      final byName = <String, List<Map<String, Object?>>>{};
      for (final s in exerciseRows) {
        final warmup = (s['is_warmup'] as int) == 1;
        final kg = (s['weight_kg'] as num).toDouble();
        final reps = s['reps'] as int;
        if (!warmup) volume += kg * reps;
        byName
            .putIfAbsent(s['name'] as String, () => [])
            .add({'weightKg': num1(kg), 'reps': reps, 'isWarmup': warmup});
      }
      workouts.add({
        'name': w['name'],
        'date': isoDate(w['started_at'] as int),
        'exercises': byName.entries
            .map((e) => {
                  'name': e.key,
                  'muscleGroup': exerciseRows
                      .firstWhere((r) => r['name'] == e.key)['muscle_group'],
                  'sets': e.value,
                })
            .toList(),
        'volumeKg': num1(volume),
      });
    }
    return jsonEncode({
      'from': isoDate(r.from),
      'to': isoDate(r.to - 1),
      'workoutCount': workouts.length,
      'workouts': workouts,
    });
  }
}

class ExerciseProgressTool extends CoachTool {
  final AppStore store;
  ExerciseProgressTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('getExerciseProgress',
      "Estimated 1RM progress for one exercise across sessions. Requires 'exerciseName'. Dates YYYY-MM-DD; omitted = all history.",
      {
        'type': 'object',
        'properties': {
          'exerciseName': {'type': 'string', 'description': "Exercise name, e.g. 'Barbell Bench Press'"},
          'start': {'type': 'string'},
          'end': {'type': 'string'},
        },
        'required': ['exerciseName'],
      });

  @override
  Future<String> run(Map<String, Object?> args) async {
    final name = args['exerciseName'] as String?;
    if (name == null) return '{"error":"exerciseName is required"}';
    final lower = name.toLowerCase();
    final exact = store.exercises.where((e) => e.name.toLowerCase() == lower).toList();
    final matches =
        exact.isNotEmpty ? exact : store.exercises.where((e) => e.name.toLowerCase().contains(lower)).toList();
    final exercise = matches.firstOrNull;
    if (exercise == null) return '{"error":"No exercise named \'$name\'"}';
    final r = dateRange(args);
    final all = await store.progressFor(exercise.id);
    final hasRange = args['start'] != null || args['end'] != null;
    final points = hasRange
        ? all.where((p) => p.date >= r.from && p.date < r.to).toList()
        : all;
    return jsonEncode({
      'exercise': exercise.name,
      'sessions': [
        for (final p in points) {'date': isoDate(p.date), 'e1rmKg': num1(p.valueKg)}
      ],
    });
  }
}

class NetWorthTool extends CoachTool {
  final AppStore store;
  NetWorthTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec('getNetWorth',
      'All tracked accounts (name, type, balance, currency) plus total net worth, assets and liabilities. No date range needed.',
      {'type': 'object'});

  @override
  Future<String> run(Map<String, Object?> args) async {
    final entries = store.accounts.map((a) => (a.balance, a.isLiability)).toList();
    return jsonEncode({
      'accounts': store.accounts
          .map((a) => {
                'name': a.name,
                'type': a.type,
                'balance': num1(a.balance),
                'currency': a.currency,
                'updated': isoDate(a.updatedAt),
              })
          .toList(),
      'netWorth': num1(Wealth.netWorth(entries)),
      'totalAssets': num1(Wealth.totalAssets(entries)),
      'totalLiabilities': num1(Wealth.totalLiabilities(entries)),
    });
  }
}

class MindLogTool extends CoachTool {
  final AppStore store;
  MindLogTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('getMindLog',
      'Mental wellbeing data for a date range: mood check-ins (1 rough .. 5 great) with notes, meditation minutes, and thought records. Dates YYYY-MM-DD; omitted = last 7 days.',
      dateRangeSchema);

  @override
  Future<String> run(Map<String, Object?> args) async {
    var r = dateRange(args);
    if (args['start'] == null && args['end'] == null) {
      r = mindLogWindow(DateTime.now());
    }
    final moods = store.moods.where((m) => m.timestamp >= r.from && m.timestamp < r.to).toList();
    final meditations = store.meditations
        .where((m) => m.timestamp >= r.from && m.timestamp < r.to)
        .toList();
    final thoughts = store.thoughts
        .where((t) => t.timestamp >= r.from && t.timestamp < r.to)
        .toList();
    return jsonEncode({
      'from': isoDate(r.from),
      'to': isoDate(r.to - 1),
      'averageMood': Mind.averageMood(moods.map((m) => m.mood).toList()),
      'checkinCount': moods.length,
      'moods': moods
          .map((m) => {'date': isoDate(m.timestamp), 'mood': m.mood, 'note': m.note})
          .toList(),
      'meditationMinutes': meditations.fold(0, (a, m) => a + m.minutes),
      'thoughtRecords': thoughts
          .map((t) => {
                'date': isoDate(t.timestamp),
                'situation': t.situation,
                'thought': t.thought,
                'reframe': t.reframe,
              })
          .toList(),
    });
  }
}

class LogMealTool extends CoachTool {
  final AppStore store;
  LogMealTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('logMeal',
      "Log a meal (calories, protein/carbs/fat grams). 'date' YYYY-MM-DD optional. Returns the logged dish and calories.",
      {
        'type': 'object',
        'properties': {
          'dish': {'type': 'string'},
          'calories': {'type': 'number'},
          'protein': {'type': 'number'},
          'carbs': {'type': 'number'},
          'fat': {'type': 'number'},
          'date': {'type': 'string'},
        },
        'required': ['dish', 'calories'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final dish = _text(args, 'dish');
    final calories = _num(args, 'calories');
    final date = _text(args, 'date');
    final macros = [
      if (calories != null) '${num1(calories)} kcal',
      if (_num(args, 'protein') != null) '${num1(_num(args, 'protein')!)}g protein',
      if (_num(args, 'carbs') != null) '${num1(_num(args, 'carbs')!)}g carbs',
      if (_num(args, 'fat') != null) '${num1(_num(args, 'fat')!)}g fat',
    ].join(', ');
    return 'Log a meal: ${dish.isEmpty ? 'meal' : dish}'
        '${macros.isEmpty ? '' : ' — $macros'}'
        '${date.isEmpty ? '' : ' ($date)'}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final dish = args['dish'] as String?;
    if (dish == null) return '{"error":"dish is required"}';
    final ts = DateTime.tryParse(args['date'] as String? ?? '') ?? DateTime.now();
    final calories = (args['calories'] as num?)?.toDouble();
    if (calories == null) return '{"error":"calories is required"}';
    await store.addMeal(Meal(
      id: 0,
      timestamp: ts.millisecondsSinceEpoch,
      imagePath: '',
      dish: dish,
      calories: calories,
      protein: (args['protein'] as num?)?.toDouble() ?? 0,
      carbs: (args['carbs'] as num?)?.toDouble() ?? 0,
      fat: (args['fat'] as num?)?.toDouble() ?? 0,
      isAuto: true,
    ));
    return jsonEncode({'ok': true, 'dish': dish, 'calories': num1(calories)});
  }
}

class LogMoodTool extends CoachTool {
  final AppStore store;
  LogMoodTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('logMood',
      'Log a mood check-in. mood: 1 rough, 2 low, 3 okay, 4 good, 5 great. Optional short note and date YYYY-MM-DD.',
      {
        'type': 'object',
        'properties': {
          'mood': {'type': 'integer', 'minimum': 1, 'maximum': 5},
          'note': {'type': 'string'},
          'date': {'type': 'string'},
        },
        'required': ['mood'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final mood = _int(args, 'mood');
    final note = _text(args, 'note');
    final date = _text(args, 'date');
    return 'Log a mood check-in: ${mood == null ? 'mood' : '$mood/5'}'
        '${note.isEmpty ? '' : ' — "$note"'}'
        '${date.isEmpty ? '' : ' ($date)'}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final mood = (args['mood'] as num?)?.toInt();
    if (mood == null) return '{"error":"mood is required"}';
    final ts = DateTime.tryParse(args['date'] as String? ?? '') ?? DateTime.now();
    await store.logMood(mood, (args['note'] as String?) ?? '', timestamp: ts.millisecondsSinceEpoch);
    return jsonEncode({'ok': true, 'mood': mood.clamp(1, 5)});
  }
}

class StartWorkoutTool extends CoachTool {
  final AppStore store;
  StartWorkoutTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('startWorkout',
      'Start a new workout session and make it active. Returns the workout id for addSet.',
      {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': "Workout name, e.g. 'Push Day'"},
        },
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final name = _text(args, 'name');
    return 'Start a workout: ${name.isEmpty ? 'Workout' : name}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final name = (args['name'] as String?)?.trim();
    final id = await store.createWorkout(name == null || name.isEmpty ? 'Workout' : name);
    return jsonEncode({'ok': true, 'workoutId': id, 'name': name});
  }
}

class AddSetTool extends CoachTool {
  final AppStore store;
  AddSetTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('addSet',
      'Add a completed working set to the active workout (started automatically if none). Exercise is added to the workout if missing. Weight in kg.',
      {
        'type': 'object',
        'properties': {
          'exerciseName': {'type': 'string'},
          'weightKg': {'type': 'number'},
          'reps': {'type': 'integer'},
          'isWarmup': {'type': 'boolean'},
          'workoutId': {'type': 'integer'},
        },
        'required': ['exerciseName', 'weightKg', 'reps'],
      });

  @override
  bool get isWrite => true;

  /// The store accepts any weight/reps, but the summary math ([epley],
  /// [volumeOf]) only tolerates weight >= 0 and reps >= 0. The model can send
  /// anything, so clamp here — the single write boundary for coach-added sets
  /// (review F3/F4 on c3d71cd).
  ///
  /// Non-finite input is normalised to 0: JSON `1e999` decodes to `Infinity`
  /// and `NaN` propagates through [volumeOf] and [trimZero] as "NaN" in the
  /// tool JSON (review b2b3b4m1 NIT-2). `-0.0` is normalised to `0.0` so the
  /// JSON does not report "-0" (NIT-1).
  static double clampWeightKg(double weightKg) {
    if (!weightKg.isFinite) return 0.0;
    return weightKg <= 0 ? 0.0 : weightKg;
  }

  /// Clamps a negative rep count to 1: a negative value is a model error, and
  /// a set that was logged at all carries at least one rep. `reps: 0` is
  /// passed through unchanged — it is a legal store value (audit B4), and
  /// mapping it to 1 would write a rep the model never asked for (review
  /// b2b3b4m1 MINOR-2).
  static int clampReps(int reps) => reps < 0 ? 1 : reps;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final name = _text(args, 'exerciseName');
    final rawWeight = _num(args, 'weightKg');
    final rawReps = _int(args, 'reps');
    // Describe what will actually be written, not the model's raw numbers.
    final weight = rawWeight == null ? null : clampWeightKg(rawWeight);
    final reps = rawReps == null ? null : clampReps(rawReps);
    final warmup = args['isWarmup'] == true;
    final workoutId = _int(args, 'workoutId');
    return 'Add a set: ${name.isEmpty ? 'exercise' : name} '
        '${weight == null ? '?' : num1(weight)} kg × ${reps ?? '?'} reps'
        '${warmup ? ' (warm-up)' : ''}'
        '${workoutId == null ? ' to the active workout' : ' to workout #$workoutId'}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final name = args['exerciseName'] as String?;
    final rawWeightKg = (args['weightKg'] as num?)?.toDouble();
    final rawReps = (args['reps'] as num?)?.toInt();
    if (name == null || rawWeightKg == null || rawReps == null) {
      return '{"error":"exerciseName, weightKg and reps are required"}';
    }
    // Clamp before the write: a negative weight reaches epley() through the
    // workout summary and throws "weight must be non-negative"; negative reps
    // make volumeOf() return negative totals (review F3/F4 on c3d71cd).
    final weightKg = clampWeightKg(rawWeightKg);
    final reps = clampReps(rawReps);
    final lower = name.toLowerCase();
    final exercise = store.exercises.where((e) => e.name.toLowerCase() == lower).firstOrNull ??
        store.exercises.where((e) => e.name.toLowerCase().contains(lower)).firstOrNull;
    if (exercise == null) return '{"error":"No exercise named \'$name\'"}';

    var workout = await store.activeWorkout();
    final requested = (args['workoutId'] as num?)?.toInt();
    if (requested != null) {
      final detail = await store.workoutDetail(requested);
      workout = detail?.workout;
    }
    if (workout == null) {
      final id = await store.createWorkout('Workout');
      final created = await store.activeWorkout();
      workout = created ?? Workout(id: id, name: 'Workout', startedAt: DateTime.now().millisecondsSinceEpoch);
    }

    final detail = await store.workoutDetail(workout.id);
    if (detail == null) return '{"error":"workout not found"}';
    var view = detail.exercises.where((v) => v.exercise.id == exercise.id).firstOrNull;
    final entryId = view != null
        ? view.entry.id
        : await store.addExerciseToWorkout(workout.id, exercise.id);
    await store.addSet(entryId, weightKg, reps, warmup: args['isWarmup'] == true);
    return jsonEncode({
      'ok': true,
      'workoutId': workout.id,
      'workoutName': workout.name,
      'exerciseName': exercise.name,
      'weightKg': num1(weightKg),
      'reps': reps,
    });
  }
}

class NetWorthHistoryTool extends CoachTool {
  final AppStore store;
  NetWorthHistoryTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec('getNetWorthHistory',
      'Net worth over time from balance snapshots (recorded whenever an account is updated). '
      'Returns one point per month: {month: YYYY-MM, netWorth}. No arguments needed.',
      {'type': 'object'});

  @override
  Future<String> run(Map<String, Object?> args) async {
    // Read the snapshots and their account types from the DB, not from the
    // cached `store.accounts` list: the cache is only as fresh as the last
    // refreshAll(), and a snapshot whose account is missing from it was
    // silently dropped (review F1 on c3d71cd). The series is built by the same
    // netWorthSeries the Wealth screen renders, from the same query, so the
    // tool and the chart describe the same series — including on
    // same-timestamp ties (review F2). They are not the same *display*: this
    // tool buckets to one point per month while the chart plots every point
    // (review b2b3b4m1 NIT-4).
    final series = netWorthSeries(await store.snapshotSeries());
    if (series.isEmpty) {
      return '{"points":[],"note":"No balance snapshots yet. Update an account to start a history."}';
    }
    // One point per month: the last snapshot in the deterministic order wins,
    // which is the month-end balance the chart also ends on.
    final byMonth = <String, double>{};
    for (final p in series) {
      final taken = DateTime.fromMillisecondsSinceEpoch(p.date);
      final month = '${taken.year}-${taken.month.toString().padLeft(2, '0')}';
      byMonth[month] = p.value;
    }
    final months = byMonth.keys.toList()..sort();
    return jsonEncode({
      'points': [for (final m in months) {'month': m, 'netWorth': num1(byMonth[m]!)}],
    });
  }
}

class ProjectUpsideTool extends CoachTool {
  final AppStore store;
  ProjectUpsideTool(this.store);

  @override
  ToolSpec get spec => ToolSpec('projectUpside',
      "Financial upside math, two modes. mode='grow': future value of principal plus monthly "
      "contributions at an annual percent (defaults to the user's current net worth as principal). "
      "mode='payoff': months needed to pay off a principal with a fixed monthly payment. "
      "All compounding is monthly; money is in the user's account currency.",
      {
        'type': 'object',
        'properties': {
          'mode': {'type': 'string', 'enum': ['grow', 'payoff']},
          'principal': {'type': 'number', 'description': 'Amount to project or debt balance. For grow, omit to use current net worth.'},
          'monthlyContribution': {'type': 'number', 'description': 'grow mode: added monthly'},
          'monthlyPayment': {'type': 'number', 'description': 'payoff mode: fixed monthly payment'},
          'annualPercent': {'type': 'number', 'description': 'grow: expected return (default 7). payoff: debt APR'},
          'years': {'type': 'integer', 'description': 'grow mode horizon (default 10)'},
        },
        'required': ['mode'],
      });

  @override
  Future<String> run(Map<String, Object?> args) async {
    final mode = (args['mode'] as String?) ?? 'grow';
    if (mode == 'payoff') {
      final principal = (args['principal'] as num?)?.toDouble();
      final payment = (args['monthlyPayment'] as num?)?.toDouble();
      if (principal == null || payment == null) {
        return '{"error":"payoff mode needs principal and monthlyPayment"}';
      }
      final months = Finance.payoffMonths(
          principal: principal, monthlyPayment: payment, annualPercent: (args['annualPercent'] as num?)?.toDouble() ?? 0);
      if (months == null) {
        return '{"error":"monthlyPayment never beats the interest"}';
      }
      return jsonEncode({
        'mode': 'payoff',
        'months': months,
        'years': double.parse((months / 12).toStringAsFixed(1)),
        'totalPaid': num1(payment * months),
        'interestPaid': num1(payment * months - principal),
      });
    }

    final entries = store.accounts.map((a) => (a.balance, a.isLiability)).toList();
    final netWorth = Wealth.netWorth(entries);
    final principal = (args['principal'] as num?)?.toDouble() ?? netWorth;
    final contribution = (args['monthlyContribution'] as num?)?.toDouble() ?? 0;
    final percent = (args['annualPercent'] as num?)?.toDouble() ?? 7;
    final years = (args['years'] as num?)?.toInt() ?? 10;
    final future = Finance.futureValue(
        principal: principal, monthlyContribution: contribution, annualPercent: percent, years: years);
    final invested = principal + contribution * years * 12;
    return jsonEncode({
      'mode': 'grow',
      'principal': num1(principal),
      'monthlyContribution': num1(contribution),
      'annualPercent': percent,
      'years': years,
      'futureValue': num1(future),
      'invested': num1(invested),
      'growth': num1(future - invested),
    });
  }
}

class SetReminderTool extends CoachTool {
  final AppStore store;
  final NotifyService notify;

  SetReminderTool(this.store, this.notify);

  @override
  ToolSpec get spec => ToolSpec('setReminder',
      'Set a reminder that fires as a device notification. Provide "text" and either "when" '
      '(local date-time YYYY-MM-DDTHH:MM) or "inMinutes" from now. The user approves it before it is created.',
      {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': 'What to remind about, e.g. "Restock protein".'},
          'when': {'type': 'string', 'description': 'YYYY-MM-DDTHH:MM local time'},
          'inMinutes': {'type': 'integer', 'description': 'Alternatively, minutes from now'},
        },
        'required': ['text'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final text = _text(args, 'text');
    final inMinutes = _int(args, 'inMinutes');
    final when = _text(args, 'when');
    final timing = inMinutes != null && inMinutes > 0
        ? 'in $inMinutes min'
        : when.isEmpty
            ? 'at an unset time'
            : 'at $when';
    return 'Set a reminder: "${text.isEmpty ? 'reminder' : text}" $timing';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final text = args['text'] as String?;
    if (text == null || text.trim().isEmpty) return '{"error":"text is required"}';
    final inMinutes = (args['inMinutes'] as num?)?.toInt();
    final when = DateTime.tryParse((args['when'] as String?) ?? '');
    int dueAt;
    if (inMinutes != null && inMinutes > 0) {
      dueAt = DateTime.now().add(Duration(minutes: inMinutes)).millisecondsSinceEpoch;
    } else if (when != null) {
      dueAt = when.millisecondsSinceEpoch;
    } else {
      return '{"error":"provide when (YYYY-MM-DDTHH:MM) or inMinutes"}';
    }
    if (dueAt <= DateTime.now().millisecondsSinceEpoch) {
      return '{"error":"reminder time is in the past"}';
    }
    final reminder = await store.addReminder(text.trim(), dueAt);
    await notify.scheduleReminder(reminder);
    return jsonEncode({'ok': true, 'id': reminder.id, 'text': reminder.text, 'due': isoDate(dueAt)});
  }
}

class ListRemindersTool extends CoachTool {
  final AppStore store;
  ListRemindersTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec('listReminders',
      'All pending reminders the app will notify about: {id, text, due}. No arguments.',
      {'type': 'object'});

  @override
  Future<String> run(Map<String, Object?> args) async => jsonEncode({
        'reminders': [
          for (final r in store.reminders)
            {'id': r.id, 'text': r.text, 'due': isoDate(r.dueAt)}
        ],
      });
}

class CancelReminderTool extends CoachTool {
  final AppStore store;
  final NotifyService notify;

  CancelReminderTool(this.store, this.notify);

  @override
  ToolSpec get spec => ToolSpec('cancelReminder',
      'Delete a pending reminder by id (use listReminders first to find it).',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final id = _int(args, 'id');
    return 'Cancel reminder ${id == null ? '' : '#$id'}'.trim();
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final id = (args['id'] as num?)?.toInt();
    if (id == null) return '{"error":"id is required"}';
    final exists = store.reminders.any((r) => r.id == id);
    if (!exists) return '{"error":"no pending reminder with id $id"}';
    await notify.cancelReminder(id);
    await store.deleteReminder(id);
    return jsonEncode({'ok': true, 'cancelled': id});
  }
}

// ---------------------------------------------------------------- habits

/// Reads a string argument without throwing when the model sends a non-string.
/// `args[key] as String?` raises a `_TypeError` on a number, and the habit
/// tools must answer with a JSON error instead of an exception.
String _safeText(Map<String, Object?> args, String key) {
  final value = args[key];
  return value is String ? value.trim() : '';
}

String _jsonError(String message) =>
    jsonEncode({'error': message.replaceAll('"', "'")});

String _cadenceWord(HabitCadence cadence) => switch (cadence) {
      HabitCadence.daily => 'per day',
      HabitCadence.weekly => 'per week',
      HabitCadence.monthly => 'per month',
    };

/// Resolves a habit by id from the store cache, or null when it is gone.
Habit? _habitById(AppStore store, int id) =>
    store.habits.where((h) => h.id == id).firstOrNull;

/// Completions for one habit, from the store cache (refreshed on every write).
List<HabitCompletion> _completionsOf(AppStore store, int habitId) =>
    store.habitCompletions.where((c) => c.habitId == habitId).toList();

Map<String, Object?> _habitJson(Habit habit, List<HabitCompletion> completions,
    DateTime today) {
  final progress = habitProgress(habit, completions, today: today);
  final cadence = HabitCadence.parse(habit.cadence) ?? HabitCadence.daily;
  return {
    'id': habit.id,
    'name': habit.name,
    'cadence': cadence.name,
    'target': habit.target,
    'archived': habit.archived,
    'completedDays': progress.completedDays,
    'targetMet': progress.met,
    'streak': progress.streak,
    'period': cadence.periodWord,
  };
}

class ListHabitsTool extends CoachTool {
  final AppStore store;
  ListHabitsTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec(
      'list_habits',
      'List every habit with its id, cadence, target days per period, archived '
          'flag, progress in the current period and streak. Archived habits are '
          'included only when includeArchived is true.',
      {
        'type': 'object',
        'properties': {
          'includeArchived': {'type': 'boolean'},
        },
      });

  @override
  Future<String> run(Map<String, Object?> args) async {
    final includeArchived = args['includeArchived'] == true;
    final today = DateTime.now();
    final habits = store.habits
        .where((h) => includeArchived || !h.archived)
        .map((h) => _habitJson(h, _completionsOf(store, h.id), today))
        .toList();
    return jsonEncode({'date': habitDayKey(today), 'habits': habits});
  }
}

class CreateHabitTool extends CoachTool {
  final AppStore store;
  CreateHabitTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec(
      'create_habit',
      'Create a habit. cadence is daily, weekly or monthly; target is the '
          'number of days per period (e.g. 3 for three times a week). Returns '
          'the new habit id.',
      {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'cadence': {
            'type': 'string',
            'enum': ['daily', 'weekly', 'monthly'],
          },
          'target': {'type': 'integer', 'minimum': 1},
        },
        'required': ['name', 'cadence'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final name = _safeText(args, 'name');
    final cadence = HabitCadence.parse(args['cadence']);
    // A mistyped target is rejected by [run]; show "?" rather than pretending
    // the habit will be created with the default of 1 (review habit MINOR-1).
    final target = args['target'] == null
        ? '1'
        : (_int(args, 'target')?.toString() ?? '?');
    return 'Create a habit: "${name.isEmpty ? 'habit' : name}" — '
        '$target× ${cadence == null ? 'per period' : _cadenceWord(cadence)}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final name = _safeText(args, 'name');
    if (name.isEmpty) return _jsonError('name is required');
    final cadence = HabitCadence.parse(args['cadence']);
    if (cadence == null) {
      return _jsonError('cadence must be daily, weekly or monthly');
    }
    final target = _int(args, 'target');
    // `_int` returns null for a JSON string ("3"), and defaulting that to 1
    // silently created a habit with the wrong target while reporting
    // `target: 1`. Only an absent key means "use the default"; a present but
    // non-integer value is an error, matching update_habit (review habit
    // MINOR-1).
    if (args['target'] != null && target == null) {
      return _jsonError('target must be an integer');
    }
    final effectiveTarget = target ?? 1;
    if (effectiveTarget < 1) return _jsonError('target must be at least 1');
    try {
      final id = await store.createHabit(name, cadence.name, effectiveTarget);
      return jsonEncode({
        'ok': true,
        'id': id,
        'name': name,
        'cadence': cadence.name,
        'target': effectiveTarget,
      });
    } on StoreException catch (e) {
      return _jsonError(e.message);
    }
  }
}

class UpdateHabitTool extends CoachTool {
  final AppStore store;
  UpdateHabitTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec(
      'update_habit',
      'Update a habit by id. Only the fields you pass change: name, cadence '
          '(daily/weekly/monthly), target days per period, or archived '
          '(true to archive, false to restore).',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'name': {'type': 'string'},
          'cadence': {
            'type': 'string',
            'enum': ['daily', 'weekly', 'monthly'],
          },
          'target': {'type': 'integer', 'minimum': 1},
          'archived': {'type': 'boolean'},
        },
        'required': ['id'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final id = _int(args, 'id');
    final habit = id == null ? null : _habitById(store, id);
    final changes = <String>[
      if (args['name'] != null) 'name "${_safeText(args, 'name')}"',
      if (args['cadence'] != null)
        'cadence ${HabitCadence.parse(args['cadence'])?.name ?? '?'}',
      if (args['target'] != null) 'target ${_int(args, 'target') ?? '?'} days',
      if (args['archived'] == true)
        'archive'
      else if (args['archived'] == false)
        'restore',
    ];
    return 'Update habit ${habit == null ? '#${id ?? '?'}' : '"${habit.name}"'}'
        '${changes.isEmpty ? '' : ': ${changes.join(', ')}'}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final id = _int(args, 'id');
    if (id == null) return _jsonError('id is required');
    final habit = _habitById(store, id);
    if (habit == null) return _jsonError('no habit with id $id');

    String? name;
    if (args['name'] != null) {
      name = _safeText(args, 'name');
      if (name.isEmpty) return _jsonError('name cannot be empty');
    }
    HabitCadence? cadence;
    if (args['cadence'] != null) {
      cadence = HabitCadence.parse(args['cadence']);
      if (cadence == null) {
        return _jsonError('cadence must be daily, weekly or monthly');
      }
    }
    int? target;
    if (args['target'] != null) {
      target = _int(args, 'target');
      if (target == null || target < 1) {
        return _jsonError('target must be at least 1');
      }
    }
    bool? archived;
    if (args['archived'] != null) {
      final raw = args['archived'];
      if (raw is! bool) return _jsonError('archived must be true or false');
      archived = raw;
    }
    if (name == null && cadence == null && target == null && archived == null) {
      return _jsonError(
          'provide at least one of name, cadence, target or archived');
    }
    try {
      await store.updateHabit(id,
          name: name, cadence: cadence?.name, target: target, archived: archived);
    } on StoreException catch (e) {
      return _jsonError(e.message);
    }
    final updated = _habitById(store, id);
    return jsonEncode({
      'ok': true,
      if (updated != null) ..._habitJson(updated, _completionsOf(store, id), DateTime.now()),
    });
  }
}

class DeleteHabitTool extends CoachTool {
  final AppStore store;
  DeleteHabitTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec(
      'delete_habit',
      'Delete a habit and its completion history by id. Use update_habit with '
          'archived true instead when the history should be kept.',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final id = _int(args, 'id');
    final habit = id == null ? null : _habitById(store, id);
    return 'Delete habit ${habit == null ? '#${id ?? '?'}' : '"${habit.name}"'}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final id = _int(args, 'id');
    if (id == null) return _jsonError('id is required');
    final habit = _habitById(store, id);
    if (habit == null) return _jsonError('no habit with id $id');
    await store.deleteHabit(id);
    return jsonEncode({'ok': true, 'deleted': id, 'name': habit.name});
  }
}

class LogHabitCompletionTool extends CoachTool {
  final AppStore store;
  LogHabitCompletionTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec(
      'log_habit_completion',
      'Check a habit off (done true, the default) or clear it (done false) for '
          'a local date YYYY-MM-DD. Omit date to use today. Returns the '
          'updated progress.',
      {
        'type': 'object',
        'properties': {
          'habitId': {'type': 'integer'},
          'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
          'done': {'type': 'boolean'},
        },
        'required': ['habitId'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final id = _int(args, 'habitId');
    final habit = id == null ? null : _habitById(store, id);
    final day = parseHabitDay(args['date']) ?? DateTime.now();
    final done = args['done'] != false;
    return '${done ? 'Check off' : 'Clear'} '
        '${habit == null ? 'habit #${id ?? '?'}' : '"${habit.name}"'} '
        'on ${habitDayKey(day)}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final id = _int(args, 'habitId');
    if (id == null) return _jsonError('habitId is required');
    final habit = _habitById(store, id);
    if (habit == null) return _jsonError('no habit with id $id');
    var day = DateTime.now();
    if (args['date'] != null) {
      final parsed = parseHabitDay(args['date']);
      if (parsed == null) return _jsonError('date must be YYYY-MM-DD');
      day = parsed;
    }
    var done = true;
    if (args['done'] != null) {
      final raw = args['done'];
      if (raw is! bool) return _jsonError('done must be true or false');
      done = raw;
    }
    try {
      await store.setHabitCompletion(id, day, done);
    } on StoreException catch (e) {
      return _jsonError(e.message);
    }
    final updated = _habitById(store, id);
    return jsonEncode({
      'ok': true,
      'habitId': id,
      'date': habitDayKey(day),
      'done': done,
      if (updated != null)
        ..._habitJson(updated, _completionsOf(store, id), DateTime.now()),
    });
  }
}

class HabitStatusTool extends CoachTool {
  final AppStore store;
  HabitStatusTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec(
      'habit_status',
      'Progress and streak for one habit (habitId) or every active habit when '
          'habitId is omitted, as of a local date YYYY-MM-DD (defaults to '
          'today).',
      {
        'type': 'object',
        'properties': {
          'habitId': {'type': 'integer'},
          'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
        },
      });

  @override
  Future<String> run(Map<String, Object?> args) async {
    var today = DateTime.now();
    if (args['date'] != null) {
      final parsed = parseHabitDay(args['date']);
      if (parsed == null) return _jsonError('date must be YYYY-MM-DD');
      today = parsed;
    }
    final id = _int(args, 'habitId');
    if (args['habitId'] != null && id == null) {
      return _jsonError('habitId must be an integer');
    }
    if (id != null) {
      final habit = _habitById(store, id);
      if (habit == null) return _jsonError('no habit with id $id');
      return jsonEncode({
        'date': habitDayKey(today),
        'habits': [_habitJson(habit, _completionsOf(store, id), today)],
      });
    }
    return jsonEncode({
      'date': habitDayKey(today),
      'habits': [
        for (final h in store.habits.where((h) => !h.archived))
          _habitJson(h, _completionsOf(store, h.id), today),
      ],
    });
  }
}

// ---------------------------------------------------------------- planner

/// Parses a coach-supplied local time into minutes from midnight.
///
/// Accepts `HH:MM` / `H:MM` (24-hour) and a bare integer minute offset. Returns
/// null for anything else, including values outside the day, so the tool
/// answers with a JSON error instead of writing a block the planner would
/// reject.
int? _parsePlanTime(Object? raw) {
  if (raw is num) {
    // `jsonDecode('{"start": 1e999}')` yields Infinity, and `Infinity.toInt()`
    // throws UnsupportedError. [summarize] is unguarded, so a non-finite time
    // must return null (a JSON error) rather than crash the approval card.
    if (!raw.isFinite) return null;
    final minutes = raw.toInt();
    if (minutes != raw) return null;
    return minutes >= 0 && minutes <= minutesPerDay ? minutes : null;
  }
  if (raw is! String) return null;
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 24 || minute > 59) return null;
  final minutes = hour * 60 + minute;
  return minutes <= minutesPerDay ? minutes : null;
}

/// Renders a coach-supplied time for an approval summary without throwing.
String _timeWord(Object? raw) {
  final minutes = _parsePlanTime(raw);
  return minutes == null ? '?' : formatPlanTime(minutes);
}

Map<String, Object?> _planBlockJson(PlanBlock block) => {
      'id': block.id,
      'title': block.title,
      'start': formatPlanTime(block.startMin),
      'end': formatPlanTime(block.endMin),
      'durationMinutes': block.durationMinutes,
      'done': block.done,
    };

/// Reads one day's plan. The coach needs this to answer "what's on my plate
/// today" and to find block ids before moving or deleting one.
class GetPlanTool extends CoachTool {
  final AppStore store;

  /// Injectable clock, like [dateRange]'s `now`: the current/next block
  /// reporting must be testable without depending on the wall clock.
  final DateTime Function()? now;

  GetPlanTool(this.store, {this.now});

  @override
  ToolSpec get spec => const ToolSpec(
          'get_plan',
          'The timed blocks planned for a local date YYYY-MM-DD (defaults to '
              'today): id, title, start/end HH:MM, duration and done flag, in '
              'chronological order. For today it also reports the block happening '
              'now and the next block.',
          {
            'type': 'object',
            'properties': {
              'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
            },
          });

  @override
  Future<String> run(Map<String, Object?> args) async {
    var day = DateTime.now();
    if (args['date'] != null) {
      final parsed = parseHabitDay(args['date']);
      if (parsed == null) return _jsonError('date must be YYYY-MM-DD');
      day = parsed;
    }
    final blocks = await store.planBlocksForDay(day);
    final clock = now?.call() ?? DateTime.now();
    final isToday = planDayKey(day) == planDayKey(clock);
    final current = isToday ? currentBlock(blocks, clock) : null;
    final next = isToday ? nextBlock(blocks, clock) : null;
    return jsonEncode({
      'date': planDayKey(day),
      'blockCount': blocks.length,
      'doneCount': blocks.where((b) => b.done).length,
      'blocks': [for (final b in blocks) _planBlockJson(b)],
      if (current != null) 'current': _planBlockJson(current),
      if (next != null) 'next': _planBlockJson(next),
    });
  }
}

class CreatePlanBlockTool extends CoachTool {
  final AppStore store;

  CreatePlanBlockTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec(
          'create_plan_block',
          'Add a timed block to a day plan. date is YYYY-MM-DD (defaults to '
              'today); start and end are local times HH:MM (24-hour). Returns the '
              'new block id.',
          {
            'type': 'object',
            'properties': {
              'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
              'title': {'type': 'string'},
              'start': {'type': 'string', 'description': 'HH:MM'},
              'end': {'type': 'string', 'description': 'HH:MM'},
            },
            'required': ['title', 'start', 'end'],
          });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final title = _safeText(args, 'title');
    final date = parseHabitDay(args['date']);
    return 'Add a plan block: "${title.isEmpty ? 'block' : title}" '
        '${_timeWord(args['start'])}–${_timeWord(args['end'])}'
        '${date == null ? '' : ' on ${planDayKey(date)}'}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final title = _safeText(args, 'title');
    if (title.isEmpty) return _jsonError('title is required');
    final start = _parsePlanTime(args['start']);
    if (start == null) return _jsonError('start must be HH:MM');
    final end = _parsePlanTime(args['end']);
    if (end == null) return _jsonError('end must be HH:MM');
    var day = DateTime.now();
    if (args['date'] != null) {
      final parsed = parseHabitDay(args['date']);
      if (parsed == null) return _jsonError('date must be YYYY-MM-DD');
      day = parsed;
    }
    try {
      final id = await store.createPlanBlock(
          day: day, title: title, startMin: start, endMin: end);
      final created = await store.planBlockById(id);
      // `_planBlockJson` already carries `id`; adding it again would emit the
      // same key twice in the literal (review Nit 1).
      final payload = <String, Object?>{
        'ok': true,
        'date': planDayKey(day),
        'id': id,
      };
      if (created != null) payload.addAll(_planBlockJson(created));
      return jsonEncode(payload);
    } on StoreException catch (e) {
      return _jsonError(e.message);
    }
  }
}

class UpdatePlanBlockTool extends CoachTool {
  final AppStore store;

  UpdatePlanBlockTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec(
          'update_plan_block',
          'Update a plan block by id. Only the fields you pass change: title, '
              'start/end (local HH:MM, 24-hour) to move it, or done (true to check '
              'it off, false to clear). Use get_plan to find block ids.',
          {
            'type': 'object',
            'properties': {
              'id': {'type': 'integer'},
              'title': {'type': 'string'},
              'start': {'type': 'string', 'description': 'HH:MM'},
              'end': {'type': 'string', 'description': 'HH:MM'},
              'done': {'type': 'boolean'},
            },
            'required': ['id'],
          });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final id = _int(args, 'id');
    final block = id == null ? null : await store.planBlockById(id);
    final changes = <String>[
      if (args['title'] != null) 'title "${_safeText(args, 'title')}"',
      if (args['start'] != null) 'start ${_timeWord(args['start'])}',
      if (args['end'] != null) 'end ${_timeWord(args['end'])}',
      if (args['done'] == true)
        'mark done'
      else if (args['done'] == false)
        'clear done',
    ];
    // Name the block being changed so the user can confirm against a title,
    // not just an id (review Nit 2).
    final label = id == null
        ? '?'
        : block == null
            ? '#$id'
            : '#$id "${block.title}"';
    return 'Update plan block $label'
        '${changes.isEmpty ? '' : ': ${changes.join(', ')}'}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final rawId = args['id'];
    if (rawId == null) return _jsonError('id is required');
    final id = _int(args, 'id');
    if (id == null) return _jsonError('id must be an integer');
    final block = await store.planBlockById(id);
    if (block == null) return _jsonError('no plan block with id $id');

    String? title;
    if (args['title'] != null) {
      title = _safeText(args, 'title');
      if (title.isEmpty) return _jsonError('title cannot be empty');
    }
    int? start;
    if (args['start'] != null) {
      start = _parsePlanTime(args['start']);
      if (start == null) return _jsonError('start must be HH:MM');
    }
    int? end;
    if (args['end'] != null) {
      end = _parsePlanTime(args['end']);
      if (end == null) return _jsonError('end must be HH:MM');
    }
    bool? done;
    if (args['done'] != null) {
      final raw = args['done'];
      if (raw is! bool) return _jsonError('done must be true or false');
      done = raw;
    }
    if (title == null && start == null && end == null && done == null) {
      return _jsonError('provide at least one of title, start, end or done');
    }
    // Validate the merged row before writing anything, so a move that would
    // invert the block is rejected without a partial write.
    final error = planBlockError(
        title: title ?? block.title,
        startMin: start ?? block.startMin,
        endMin: end ?? block.endMin);
    if (error != null) return _jsonError(error);
    try {
      // One write for the move and the done flag, so a failure cannot leave
      // the block moved but unchecked (review Nit 4).
      await store.updatePlanBlock(id,
          title: title, startMin: start, endMin: end, done: done);
    } on StoreException catch (e) {
      return _jsonError(e.message);
    }
    final updated = await store.planBlockById(id);
    return jsonEncode({
      'ok': true,
      'id': id,
      if (updated != null) ..._planBlockJson(updated),
    });
  }
}

class DeletePlanBlockTool extends CoachTool {
  final AppStore store;

  DeletePlanBlockTool(this.store);

  @override
  ToolSpec get spec => const ToolSpec('delete_plan_block',
          'Delete a plan block by id. Use get_plan to find block ids.', {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
      });

  @override
  bool get isWrite => true;

  @override
  Future<String> summarize(Map<String, Object?> args) async {
    final id = _int(args, 'id');
    if (id == null) return 'Delete plan block ?';
    final block = await store.planBlockById(id);
    // Name the block so the user can confirm the deletion against a title
    // (review Nit 2).
    return 'Delete plan block #$id${block == null ? '' : ' "${block.title}"'}';
  }

  @override
  Future<String> run(Map<String, Object?> args) async {
    final rawId = args['id'];
    if (rawId == null) return _jsonError('id is required');
    final id = _int(args, 'id');
    if (id == null) return _jsonError('id must be an integer');
    final block = await store.planBlockById(id);
    if (block == null) return _jsonError('no plan block with id $id');
    await store.deletePlanBlock(id);
    return jsonEncode({'ok': true, 'deleted': id, 'title': block.title});
  }
}
