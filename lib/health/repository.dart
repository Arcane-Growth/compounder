import 'package:sqflite/sqflite.dart';

import 'analysis.dart';
import 'categories.dart';
import 'models.dart';

class HealthRepository {
  final Database db;
  HealthRepository(this.db);

  Future<List<HealthRecord>> records({
    String? type,
    int? from,
    int? to,
    int? limit,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (type != null) {
      where.add('type = ?');
      args.add(type);
    }
    if (from != null) {
      where.add('date_to >= ?');
      args.add(from);
    }
    if (to != null) {
      where.add('date_from < ?');
      args.add(to);
    }
    final rows = await db.query(
      'health_records',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: where.isEmpty ? null : args,
      orderBy: 'date_from',
      limit: limit,
    );
    return rows.map(HealthRecord.fromMap).toList();
  }

  Future<int> upsertRecords(List<HealthRecord> records) async {
    if (records.isEmpty) return 0;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in records) {
        batch.insert('health_records', r.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    return records.length;
  }

  Future<void> setSyncState(
    String metric, {
    int? lastSyncedAt,
    int? lastSuccessAt,
    String? lastError,
  }) async {
    final existing = await db.query('health_sync_state',
        where: 'metric = ?', whereArgs: [metric], limit: 1);
    final values = <String, Object?>{
      'metric': metric,
      if (lastSyncedAt != null) 'last_synced_at': lastSyncedAt,
      if (lastSuccessAt != null) 'last_success_at': lastSuccessAt,
      'last_error': lastError,
    };
    if (existing.isEmpty) {
      await db.insert('health_sync_state', values);
    } else {
      await db.update('health_sync_state', values,
          where: 'metric = ?', whereArgs: [metric]);
    }
  }

  Future<Map<String, HealthSyncState>> syncStates() async {
    final rows = await db.query('health_sync_state');
    return {
      for (final r in rows) r['metric'] as String: HealthSyncState.fromMap(r)
    };
  }

  Future<DateTime?> lastSync() async {
    final rows = await db.query('health_sync_state',
        where: 'metric = ?', whereArgs: ['__all__'], limit: 1);
    if (rows.isEmpty) return null;
    final ms = rows.first['last_success_at'] as int?;
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<int> recordCount() async {
    final rows = await db.rawQuery('SELECT COUNT(*) c FROM health_records');
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<List<HealthDayStat>> daily({
    required String type,
    required int from,
    required int to,
  }) async {
    final fromDay = dayKey(from);
    final toDay = dayKey(to - 1);
    final dailyRows = await db.query(
      'health_daily',
      where: 'metric = ? AND day >= ? AND day <= ?',
      whereArgs: [type, fromDay, toDay],
      orderBy: 'day',
    );
    final merged = <String, HealthDayStat>{
      for (final r in dailyRows) (r['day'] as String): HealthDayStat.fromMap(r),
    };

    if (type == 'SLEEP') {
      final raw = await records(type: null, from: from, to: to);
      for (final stat in sleepDailyStats(raw)) {
        merged[stat.day] = stat;
      }
    } else {
      final raw = await records(type: type, from: from, to: to);
      final aggregation = metricAggregation(type);
      for (final stat in dailyStats(raw,
          aggregation: aggregation, attributeToEnd: isSleepType(type))) {
        merged[stat.day] = stat;
      }
    }
    final out = merged.values.toList()..sort((a, b) => a.day.compareTo(b.day));
    return out;
  }

  Future<List<SleepSession>> sleepSessions(
      {required int from, required int to}) async {
    final raw = await records(from: from, to: to);
    return buildSleepSessions(sleepSegmentsFromRecords(raw));
  }

  Future<Map<String, dynamic>> overview(
      {required int from, required int to}) async {
    final raw = await records(from: from, to: to);
    final sessions = buildSleepSessions(sleepSegmentsFromRecords(raw));
    final sleepDays = await daily(type: 'SLEEP', from: from, to: to);

    final heartDays = await daily(type: 'HEART_RATE', from: from, to: to);
    final heart = [
      for (final d in heartDays)
        {
          'date': d.day,
          'count': d.count,
          'avg': d.avg,
          'min': d.min,
          'max': d.max,
        }
    ];
    final resting = await daily(type: 'RESTING_HEART_RATE', from: from, to: to);
    final hrv =
        await daily(type: 'HEART_RATE_VARIABILITY_RMSSD', from: from, to: to);
    final steps = await daily(type: 'STEPS', from: from, to: to);
    final distance = await daily(type: 'DISTANCE_DELTA', from: from, to: to);
    final activeCal =
        await daily(type: 'ACTIVE_ENERGY_BURNED', from: from, to: to);
    final totalCal =
        await daily(type: 'TOTAL_CALORIES_BURNED', from: from, to: to);
    final workouts = workoutSummaries(raw);

    final latestSleep = sessions.isEmpty ? null : sessions.last;
    final sleepFallback = sleepDays.isEmpty ? null : sleepDays.last;

    return {
      'from': dayKey(from),
      'to': dayKey(to - 1),
      'sleep': {
        'nights': sleepDays.length,
        'averageAsleepMinutes': sleepDays.isEmpty
            ? null
            : round1(sleepDays.map((d) => d.sum).reduce((a, b) => a + b) /
                sleepDays.length),
        'lastNight': latestSleep != null
            ? _sleepMap(latestSleep)
            : sleepFallback == null
                ? null
                : {
                    'date': sleepFallback.day,
                    'asleepMinutes': sleepFallback.sum.round(),
                    ...sleepFallback.detail,
                  },
      },
      'heart': {
        'daily': heart,
        'restingHeartRate': _latestMap(resting),
        'hrvMs': _latestMap(hrv),
      },
      'activity': {
        'stepsTotal': _sum(steps),
        'stepsDaily': _points(steps),
        'distanceMeters': _sum(distance),
        'activeCalories': _sum(activeCal),
        'totalCalories': _sum(totalCal),
        'workouts': workouts,
        'workoutCount': workouts.length,
      },
      'body': {
        'weightKg': _latestMap(await daily(type: 'WEIGHT', from: from, to: to)),
        'bodyFatPercent': _latestMap(
            await daily(type: 'BODY_FAT_PERCENTAGE', from: from, to: to)),
        'leanMassKg':
            _latestMap(await daily(type: 'LEAN_BODY_MASS', from: from, to: to)),
        'bmi': _latestMap(
            await daily(type: 'BODY_MASS_INDEX', from: from, to: to)),
      },
      'vitals': {
        'bloodOxygen':
            _latestMap(await daily(type: 'BLOOD_OXYGEN', from: from, to: to)),
        'respiratoryRate': _latestMap(
            await daily(type: 'RESPIRATORY_RATE', from: from, to: to)),
        'bodyTemperatureC': _latestMap(
            await daily(type: 'BODY_TEMPERATURE', from: from, to: to)),
        'systolic': _latestMap(
            await daily(type: 'BLOOD_PRESSURE_SYSTOLIC', from: from, to: to)),
        'diastolic': _latestMap(
            await daily(type: 'BLOOD_PRESSURE_DIASTOLIC', from: from, to: to)),
        'bloodGlucose':
            _latestMap(await daily(type: 'BLOOD_GLUCOSE', from: from, to: to)),
      },
    };
  }

  Map<String, dynamic> _sleepMap(SleepSession s) => {
        'date': s.date,
        'start': s.start,
        'end': s.end,
        'bedtime': _timeOfDay(s.start),
        'wake': _timeOfDay(s.end),
        'inBedMinutes': s.inBedMinutes,
        'asleepMinutes': s.asleepMinutes,
        'awakeMinutes': s.awakeMinutes,
        'efficiencyPercent': s.efficiency,
        'stages': s.stages,
        'source': s.sourceName,
      };

  Map<String, dynamic>? _latestMap(List<HealthDayStat> days) {
    if (days.isEmpty) return null;
    final d = days.last;
    return {
      'date': d.day,
      'value': d.avg ?? d.sum,
      'min': d.min,
      'max': d.max,
      'count': d.count,
      'detail': d.detail,
    };
  }

  double? _sum(List<HealthDayStat> days) =>
      days.isEmpty ? null : round1(days.fold(0.0, (a, d) => a + d.sum));

  List<Map<String, dynamic>> _points(List<HealthDayStat> days) => [
        for (final d in days) {'date': d.day, 'value': round1(d.sum)},
      ];

  String _timeOfDay(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<List<Map<String, dynamic>>> availableMetrics() async {
    final raw = await db.rawQuery(
        'SELECT type, COUNT(*) c, MAX(date_to) last FROM health_records GROUP BY type');
    final daily = await db.rawQuery(
        'SELECT metric, COUNT(*) c, MAX(day) last FROM health_daily GROUP BY metric');
    final merged = <String, Map<String, dynamic>>{};
    for (final r in raw) {
      final type = r['type'] as String;
      final info = metricInfo(type);
      merged[type] = {
        'metric': type,
        'label': info.label,
        'unit': info.unit,
        'records': r['c'] as int? ?? 0,
        'lastDate': r['last'] == null ? null : dayKey(r['last'] as int),
        'aggregatedOnly': false,
      };
    }
    for (final r in daily) {
      final type = r['metric'] as String;
      final info = metricInfo(type);
      final existing = merged[type];
      merged[type] = {
        'metric': type,
        'label': info.label,
        'unit': info.unit,
        'records': (existing?['records'] as int? ?? 0),
        'lastDate': r['last'] as String?,
        'aggregatedOnly': existing == null,
        'aggregatedDays': r['c'] as int? ?? 0,
      };
    }
    final out = merged.values.toList()
      ..sort((a, b) => (a['label'] as String).compareTo(b['label'] as String));
    return out;
  }

  Future<void> compactOlderThan(DateTime cutoff) async {
    final cutoffMs = cutoff.millisecondsSinceEpoch;
    const keepRaw = ['WORKOUT', 'NUTRITION', 'MENSTRUATION_FLOW'];
    final old = await db.query(
      'health_records',
      where: 'date_to < ? AND type NOT IN (?, ?, ?)',
      whereArgs: [cutoffMs, ...keepRaw],
    );
    if (old.isEmpty) return;
    final records = old.map(HealthRecord.fromMap).toList();
    final byType = <String, List<HealthRecord>>{};
    for (final r in records) {
      byType.putIfAbsent(r.type, () => []).add(r);
    }
    await db.transaction((txn) async {
      for (final entry in byType.entries) {
        final type = entry.key;
        final stats = isSleepType(type)
            ? dailyStats(entry.value,
                aggregation: HealthAggregation.sum, attributeToEnd: true)
            : dailyStats(entry.value, aggregation: metricAggregation(type));
        for (final stat in stats) {
          await txn.insert('health_daily', stat.toMap(),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      final sleepStats = sleepDailyStats(records);
      for (final stat in sleepStats) {
        await txn.insert('health_daily', stat.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.delete('health_records',
          where: 'date_to < ? AND type NOT IN (?, ?, ?)',
          whereArgs: [cutoffMs, ...keepRaw]);
    });
  }

  Future<void> deleteAll() async {
    await db.transaction((txn) async {
      await txn.delete('health_records');
      await txn.delete('health_daily');
      await txn.delete('health_sync_state');
    });
  }

  Future<Map<String, dynamic>> syncStatus() async {
    final states = await syncStates();
    return {
      'records': await recordCount(),
      'lastSync': (await lastSync())?.toIso8601String(),
      'metrics': {
        for (final entry in states.entries)
          entry.key: {
            'lastSyncedAt': entry.value.lastSyncedAt == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(entry.value.lastSyncedAt!)
                    .toIso8601String(),
            'lastSuccessAt': entry.value.lastSuccessAt == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                        entry.value.lastSuccessAt!)
                    .toIso8601String(),
            'lastError': entry.value.lastError,
          },
      },
      'available': await availableMetrics(),
    };
  }
}
