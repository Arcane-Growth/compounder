import 'dart:convert';

import '../health/analysis.dart';
import '../health/categories.dart';
import '../health/models.dart';
import '../health/repository.dart';
import '../health/service.dart';
import '../llm/llm.dart';
import 'agent.dart';
import 'tools.dart';

({int from, int to}) _range(Map<String, Object?> args, {int defaultDays = 7}) {
  final now = DateTime.now();
  final startRaw = args['start'] as String?;
  final start = DateTime.tryParse(startRaw ?? '') ??
      DateTime(now.year, now.month, now.day - (defaultDays - 1));
  final endRaw = args['end'] as String?;
  final end =
      DateTime.tryParse(endRaw ?? '') ?? (startRaw == null ? now : start);
  final lo = end.isBefore(start) ? end : start;
  final hi = end.isBefore(start) ? start : end;
  return (
    from: DateTime(lo.year, lo.month, lo.day).millisecondsSinceEpoch,
    to: DateTime(hi.year, hi.month, hi.day + 1).millisecondsSinceEpoch,
  );
}

Map<String, Object?> _sleepSessionMap(SleepSession s) => {
      'date': s.date,
      'bedtime': _clock(s.start),
      'wake': _clock(s.end),
      'inBedMinutes': s.inBedMinutes,
      'asleepMinutes': s.asleepMinutes,
      'awakeMinutes': s.awakeMinutes,
      'efficiencyPercent': s.efficiency,
      'stagesMinutes': s.stages,
      'source': s.sourceName,
    };

String _clock(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class HealthOverviewTool extends CoachTool {
  final HealthRepository repository;
  final HealthService service;
  HealthOverviewTool(this.repository, this.service);

  @override
  ToolSpec get spec => ToolSpec(
        'getHealthOverview',
        'Health Connect summary for a date range: sleep (last night, averages, stages), '
            'heart rate/resting HR/HRV, activity (steps, distance, calories, workouts), body '
            'measurements and vitals. Dates YYYY-MM-DD; omitted = last 7 days.',
        dateRangeSchema,
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = _range(args);
    final overview = await repository.overview(from: r.from, to: r.to);
    final status = await service.status();
    return jsonEncode({
      ...overview,
      'sync': {
        'connected': status['enabled'],
        'lastSync': status['lastSync'],
        'lastError': status['lastError'],
      },
    });
  }
}

class SleepTool extends CoachTool {
  final HealthRepository repository;
  SleepTool(this.repository);

  @override
  ToolSpec get spec => ToolSpec(
        'getSleep',
        'Sleep from Health Connect for a date range: per-night bedtime, wake time, asleep/awake '
            'minutes, sleep stages and efficiency. Dates YYYY-MM-DD; omitted = last 14 days.',
        dateRangeSchema,
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = _range(args, defaultDays: 14);
    final sessions = await repository.sleepSessions(from: r.from, to: r.to);
    final days = await repository.daily(type: 'SLEEP', from: r.from, to: r.to);
    final nights = sessions.map(_sleepSessionMap).toList();
    // Include compacted/aggregated nights for older history that no longer has
    // raw stage records.
    final known = nights.map((n) => n['date']).toSet();
    for (final d in days) {
      if (known.contains(d.day)) continue;
      nights.add({
        'date': d.day,
        'bedtime': null,
        'wake': null,
        'inBedMinutes': d.detail['inBedMinutes'],
        'asleepMinutes': d.sum.round(),
        'awakeMinutes': d.detail['awakeMinutes'],
        'efficiencyPercent': d.detail['efficiency'],
        'stagesMinutes': d.detail['stages'],
        'source': null,
        'aggregated': true,
      });
    }
    nights.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    final asleep = nights
        .map((n) => (n['asleepMinutes'] as num?)?.toDouble() ?? 0)
        .where((v) => v > 0)
        .toList();
    return jsonEncode({
      'from': dayKey(r.from),
      'to': dayKey(r.to - 1),
      'nights': nights,
      'averageAsleepMinutes': asleep.isEmpty
          ? null
          : round1(asleep.reduce((a, b) => a + b) / asleep.length),
    });
  }
}

class HeartRateTool extends CoachTool {
  final HealthRepository repository;
  HeartRateTool(this.repository);

  @override
  ToolSpec get spec => ToolSpec(
        'getHeartRate',
        'Heart data from Health Connect: daily heart-rate average/min/max, resting heart rate, '
            'HRV, and optional hourly averages. Dates YYYY-MM-DD; omitted = last 14 days.',
        {
          'type': 'object',
          'properties': {
            'start': {'type': 'string', 'description': 'Start date YYYY-MM-DD'},
            'end': {'type': 'string', 'description': 'End date YYYY-MM-DD'},
            'includeHourly': {
              'type': 'boolean',
              'description':
                  'Include hourly heart-rate averages (default false; capped to 7 days).',
            },
          },
        },
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = _range(args, defaultDays: 14);
    final raw = await repository.records(from: r.from, to: r.to);
    final daily = heartDailyStats(raw);
    final resting = await repository.daily(
        type: 'RESTING_HEART_RATE', from: r.from, to: r.to);
    final hrv = await repository.daily(
        type: 'HEART_RATE_VARIABILITY_RMSSD', from: r.from, to: r.to);
    final includeHourly = args['includeHourly'] == true;
    return jsonEncode({
      'from': dayKey(r.from),
      'to': dayKey(r.to - 1),
      'daily': daily,
      'restingHeartRate': [
        for (final d in resting) {'date': d.day, 'value': d.avg ?? d.sum}
      ],
      'hrvMs': [
        for (final d in hrv) {'date': d.day, 'value': d.avg ?? d.sum}
      ],
      if (includeHourly) 'hourly': hourlyHeartStats(raw),
      if (daily.isEmpty) 'note': 'No heart-rate samples found in this range.',
    });
  }
}

class HealthMetricTool extends CoachTool {
  final HealthRepository repository;
  HealthMetricTool(this.repository);

  @override
  ToolSpec get spec => ToolSpec(
        'getHealthMetric',
        'Query any imported Health Connect metric by name: steps, distance, calories, weight, '
            'body fat, lean mass, BMI, blood oxygen, respiratory rate, temperature, blood pressure, '
            'glucose, sleep stages, nutrition, hydration, menstruation or workouts. Returns daily '
            'aggregates or readings. Dates YYYY-MM-DD; omitted = last 30 days.',
        {
          'type': 'object',
          'properties': {
            'metric': {
              'type': 'string',
              'description':
                  'Health Connect type, e.g. STEPS, WEIGHT, BLOOD_OXYGEN, SLEEP, WORKOUT.',
            },
            'start': {'type': 'string'},
            'end': {'type': 'string'},
          },
          'required': ['metric'],
        },
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final rawMetric = (args['metric'] as String?)?.trim().toUpperCase();
    if (rawMetric == null || rawMetric.isEmpty) {
      return '{"error":"metric is required"}';
    }
    final r = _range(args, defaultDays: 30);
    final info = metricInfo(rawMetric);

    if (rawMetric == 'WORKOUT') {
      final workouts = workoutSummaries(
          await repository.records(type: 'WORKOUT', from: r.from, to: r.to));
      return jsonEncode(
          {'metric': rawMetric, 'unit': info.unit, 'workouts': workouts});
    }
    if (rawMetric == 'SLEEP' || isSleepType(rawMetric)) {
      final days =
          await repository.daily(type: rawMetric, from: r.from, to: r.to);
      return jsonEncode({
        'metric': rawMetric,
        'label': info.label,
        'unit': info.unit,
        'points': [
          for (final d in days)
            {
              'date': d.day,
              'minutes': d.sum.round(),
              'count': d.count,
              ...d.detail,
            }
        ],
      });
    }
    if (rawMetric == 'NUTRITION') {
      final records =
          await repository.records(type: 'NUTRITION', from: r.from, to: r.to);
      return jsonEncode({
        'metric': rawMetric,
        'label': info.label,
        'entries': [
          for (final record in records)
            {
              'date': dayKey(record.dateFrom),
              'raw': _nutritionFields(record.rawJson),
            }
        ],
      });
    }

    final days =
        await repository.daily(type: rawMetric, from: r.from, to: r.to);
    if (days.isEmpty) {
      final available = await repository.availableMetrics();
      return jsonEncode({
        'metric': rawMetric,
        'points': [],
        'note': 'No data for this metric in the range.',
        'availableMetrics': [for (final m in available) m['metric']],
      });
    }
    return jsonEncode({
      'metric': rawMetric,
      'label': info.label,
      'unit': info.unit,
      'aggregation': info.aggregation.name,
      'points': [
        for (final d in days)
          {
            'date': d.day,
            'count': d.count,
            'sum': d.sum,
            'avg': d.avg,
            'min': d.min,
            'max': d.max,
            if (d.detail.isNotEmpty) 'detail': d.detail,
          }
      ],
    });
  }

  Map<String, Object?> _nutritionFields(String rawJson) {
    try {
      final raw = jsonDecode(rawJson);
      final value = raw is Map ? raw['value'] : null;
      if (value is Map) {
        return {
          'name': value['name'],
          'mealType': value['meal_type'],
          'calories': value['calories'],
          'protein': value['protein'],
          'carbs': value['carbs'],
          'fat': value['fat'],
        };
      }
    } catch (_) {}
    return const {};
  }
}

class HealthWorkoutsTool extends CoachTool {
  final HealthRepository repository;
  HealthWorkoutsTool(this.repository);

  @override
  ToolSpec get spec => ToolSpec(
        'getHealthWorkouts',
        'Workout/exercise sessions imported from Health Connect: activity, duration, energy, '
            'distance, steps and source. Dates YYYY-MM-DD; omitted = last 30 days.',
        dateRangeSchema,
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = _range(args, defaultDays: 30);
    final workouts = workoutSummaries(
        await repository.records(type: 'WORKOUT', from: r.from, to: r.to));
    return jsonEncode({
      'from': dayKey(r.from),
      'to': dayKey(r.to - 1),
      'workouts': workouts,
    });
  }
}

class HealthSyncStatusTool extends CoachTool {
  final HealthService service;
  HealthSyncStatusTool(this.service);

  @override
  ToolSpec get spec => const ToolSpec(
        'getHealthSyncStatus',
        'Whether Health Connect is connected, which categories are enabled, last sync time, '
            'errors, and which health metrics are available. No arguments.',
        {'type': 'object'},
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final status = await service.status();
    return jsonEncode(status);
  }
}
