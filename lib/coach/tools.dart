import 'dart:convert';

import '../data/models.dart';
import '../services/notify.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import '../llm/llm.dart';
import 'agent.dart';

({int from, int to}) dateRange(Map<String, Object?> args) {
  final today = DateTime.now();
  final startRaw = args['start'] as String?;
  final start = DateTime.tryParse(startRaw ?? '') ?? today;
  final end = DateTime.tryParse(args['end'] as String? ?? '') ?? (startRaw == null ? today : start);
  final lo = end.isBefore(start) ? end : start;
  final hi = end.isBefore(start) ? start : end;
  return (
    from: DateTime(lo.year, lo.month, lo.day).millisecondsSinceEpoch,
    to: DateTime(hi.year, hi.month, hi.day).add(const Duration(days: 1)).millisecondsSinceEpoch,
  );
}

String isoDate(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String num1(double v) => trimZero(v);

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
      final now = DateTime.now();
      r = (
        from: DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6)).millisecondsSinceEpoch,
        to: DateTime(now.year, now.month, now.day)
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch
      );
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
  Future<String> run(Map<String, Object?> args) async {
    final name = args['exerciseName'] as String?;
    final weightKg = (args['weightKg'] as num?)?.toDouble();
    final reps = (args['reps'] as num?)?.toInt();
    if (name == null || weightKg == null || reps == null) {
      return '{"error":"exerciseName, weightKg and reps are required"}';
    }
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
    final rows = await store.snapshots();
    if (rows.isEmpty) return '{"points":[],"note":"No balance snapshots yet. Update an account to start a history."}';
    final latest = <int, double>{};
    final byMonth = <String, double>{};
    for (final r in rows) {
      latest[r['account_id'] as int] = (r['balance'] as num).toDouble();
      final taken = DateTime.fromMillisecondsSinceEpoch(r['taken_at'] as int);
      final month = '${taken.year}-${taken.month.toString().padLeft(2, '0')}';
      byMonth[month] = latest.values.fold(0.0, (a, b) => a + b);
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
      '(local date-time YYYY-MM-DDTHH:MM) or "inMinutes" from now. Confirm with the user before creating.',
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
