import 'dart:convert';
import 'dart:math' as math;

import 'categories.dart';
import 'models.dart';

String dayKey(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String dayKeyForDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

double round1(double v) => (v * 10).roundToDouble() / 10;
double round2(double v) => (v * 100).roundToDouble() / 100;

int _clampMinutes(num v) => v.round().clamp(0, 24 * 60);

const _sleepStageTypes = {
  'SLEEP_SESSION',
  'SLEEP_ASLEEP',
  'SLEEP_AWAKE',
  'SLEEP_AWAKE_IN_BED',
  'SLEEP_DEEP',
  'SLEEP_LIGHT',
  'SLEEP_OUT_OF_BED',
  'SLEEP_REM',
  'SLEEP_UNKNOWN',
  'SLEEP_IN_BED',
};

bool isSleepRecord(HealthRecord r) => _sleepStageTypes.contains(r.type);

List<SleepSegment> sleepSegmentsFromRecords(List<HealthRecord> records) => [
      for (final r in records)
        if (isSleepRecord(r))
          SleepSegment(
            uuid: r.uuid,
            type: r.type,
            start: r.dateFrom,
            end: r.dateTo,
            sourceId: r.sourceId,
            sourceName: r.sourceName,
          ),
    ];

/// Groups sleep stage records into nights/naps. When multiple sources cover
/// the same night, the source with the most detailed stage data wins so stages
/// are not double-counted.
List<SleepSession> buildSleepSessions(List<SleepSegment> segments) {
  if (segments.isEmpty) return const [];

  final sorted = [...segments]..sort((a, b) => a.start.compareTo(b.start));
  final clusters = <List<SleepSegment>>[];
  var current = <SleepSegment>[];
  int? clusterStart;
  int? clusterEnd;

  void flush() {
    if (current.isNotEmpty) {
      clusters.add(current);
      current = [];
      clusterStart = null;
      clusterEnd = null;
    }
  }

  const gapLimit = 90 * 60 * 1000;
  const maxSession = 16 * 60 * 60 * 1000;

  for (final s in sorted) {
    if (current.isEmpty) {
      current = [s];
      clusterStart = s.start;
      clusterEnd = s.end;
      continue;
    }
    final gap = s.start - (clusterEnd ?? s.start);
    final duration = s.end - (clusterStart ?? s.start);
    if (gap > gapLimit || duration > maxSession) {
      flush();
      current = [s];
      clusterStart = s.start;
      clusterEnd = s.end;
    } else {
      current.add(s);
      clusterEnd = math.max(clusterEnd ?? s.end, s.end);
    }
  }
  flush();

  final sessions = <SleepSession>[];
  for (final cluster in clusters) {
    final chosen = _bestSource(cluster);
    final sessionRecords = chosen
        .where((s) => s.type == 'SLEEP_SESSION')
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (sessionRecords.isNotEmpty) {
      for (final session in sessionRecords) {
        final stages = chosen
            .where((s) =>
                s.type != 'SLEEP_SESSION' &&
                s.start < session.end &&
                s.end > session.start)
            .toList();
        sessions.add(_buildSession(
          start: session.start,
          end: session.end,
          stages: stages,
          sourceName: session.sourceName,
          hasSessionRecord: true,
        ));
      }
    } else {
      final start = chosen.map((s) => s.start).reduce(math.min);
      final end = chosen.map((s) => s.end).reduce(math.max);
      sessions.add(_buildSession(
        start: start,
        end: end,
        stages: chosen.where((s) => s.type != 'SLEEP_SESSION').toList(),
        sourceName: chosen.first.sourceName,
      ));
    }
  }

  sessions.sort((a, b) => a.start.compareTo(b.start));
  return sessions;
}

List<SleepSegment> _bestSource(List<SleepSegment> cluster) {
  final groups = <String, List<SleepSegment>>{};
  for (final s in cluster) {
    final key = s.sourceId.isNotEmpty ? s.sourceId : s.sourceName;
    groups.putIfAbsent(key, () => []).add(s);
  }
  if (groups.length == 1) return groups.values.first;

  /// (hasSessionRecord, weightedDetail). A source that reports a full
  /// SLEEP_SESSION record describes the whole night; a stage-only source may
  /// describe a single stage (e.g. a REM-only sync), so it must never win a
  /// cluster over a source that has the session. Within each class the most
  /// detailed source still wins.
  (int, double) score(List<SleepSegment> list) {
    var hasSession = false;
    var specific = 0;
    var total = 0;
    for (final s in list) {
      final m = s.minutes;
      total += m;
      if (s.type == 'SLEEP_SESSION') {
        hasSession = true;
      } else if (s.type == 'SLEEP_DEEP' ||
          s.type == 'SLEEP_LIGHT' ||
          s.type == 'SLEEP_REM' ||
          s.type == 'SLEEP_AWAKE') {
        specific += m;
      }
    }
    return (hasSession ? 1 : 0, (specific * 2 + total).toDouble());
  }

  final best = groups.entries.reduce((a, b) {
    final sa = score(a.value);
    final sb = score(b.value);
    if (sa.$1 != sb.$1) return sa.$1 > sb.$1 ? a : b;
    return sa.$2 >= sb.$2 ? a : b;
  });
  return best.value;
}

SleepSession _buildSession({
  required int start,
  required int end,
  required List<SleepSegment> stages,
  required String sourceName,
  bool hasSessionRecord = false,
}) {
  final byType = <String, List<(int, int)>>{};
  for (final s in stages) {
    byType.putIfAbsent(s.type, () => []).add((s.start, s.end));
  }
  final merged = <String, int>{};
  for (final entry in byType.entries) {
    merged[entry.key] = _mergedMinutes(entry.value);
  }

  final sessionMinutes = ((end - start) / 60000).round();
  // Every type that reports time actually spent asleep. SLEEP_ASLEEP and
  // SLEEP_UNKNOWN often span the whole night and overlap the specific stages,
  // so union the intervals instead of adding the per-type totals — that keeps
  // generic-only wearables counted without double-counting a staged night.
  final asleepIntervals = <(int, int)>[
    for (final type in const [
      'SLEEP_DEEP',
      'SLEEP_LIGHT',
      'SLEEP_REM',
      'SLEEP_ASLEEP',
      'SLEEP_UNKNOWN',
    ])
      ...?byType[type],
  ];
  final stageAsleep = _mergedMinutes(asleepIntervals);
  final awake =
      (merged['SLEEP_AWAKE'] ?? 0) + (merged['SLEEP_AWAKE_IN_BED'] ?? 0);
  // Time in bed must cover everything the night reports: the session window,
  // the summed stages plus awake time, and any explicit SLEEP_IN_BED total.
  // Stages can outrun the session window when a source reports a stage past
  // the recorded end, so covered time wins over the session length.
  final covered = stageAsleep + awake;
  var inBed = math.max(sessionMinutes, covered);
  inBed = math.max(inBed, merged['SLEEP_IN_BED'] ?? 0);
  // A SLEEP_SESSION record carries the night's real asleep total (Health Connect
  // keeps reporting it even when only one stage synced), so it must beat a
  // partial stage sum — but it must not claim time actually spent awake, and it
  // must never exceed time in bed. Hence: the larger of the synced stages and
  // (session length capped by inBed - awake).
  var asleep = stages.isEmpty ? sessionMinutes : stageAsleep;
  if (hasSessionRecord) {
    asleep = math.max(stageAsleep, math.min(sessionMinutes, inBed - awake));
  }
  // Invariant: asleep + awake can never exceed time in bed.
  asleep = math.min(asleep, inBed - awake);
  final efficiency = inBed <= 0 ? 0.0 : (asleep / inBed).clamp(0.0, 1.0);

  final cleanStages = <String, int>{};
  for (final key in [
    'SLEEP_DEEP',
    'SLEEP_LIGHT',
    'SLEEP_REM',
    'SLEEP_AWAKE',
    'SLEEP_AWAKE_IN_BED'
  ]) {
    final v = merged[key] ?? 0;
    if (v > 0) cleanStages[key] = _clampMinutes(v);
  }
  // Generic asleep/unknown intervals are reported (not discarded) but only for
  // the part no specific stage covers, so the stage breakdown stays additive.
  final specificIntervals = <(int, int)>[
    for (final key in const [
      'SLEEP_DEEP',
      'SLEEP_LIGHT',
      'SLEEP_REM',
      'SLEEP_AWAKE',
      'SLEEP_AWAKE_IN_BED',
    ])
      ...?byType[key],
  ];
  for (final key in const ['SLEEP_ASLEEP', 'SLEEP_UNKNOWN']) {
    final intervals = byType[key];
    if (intervals == null || intervals.isEmpty) continue;
    final uncovered = _uncoveredMinutes(intervals, specificIntervals);
    if (uncovered > 0) cleanStages[key] = _clampMinutes(uncovered);
  }

  return SleepSession(
    date: dayKey(end),
    start: start,
    end: end,
    inBedMinutes: _clampMinutes(inBed),
    asleepMinutes: _clampMinutes(asleep),
    awakeMinutes: _clampMinutes(awake),
    efficiency: round1(efficiency * 100),
    stages: cleanStages,
    sourceName: sourceName,
  );
}

int _mergedMinutes(List<(int, int)> intervals) {
  final total = _mergeIntervals(intervals)
      .fold(0, (sum, interval) => sum + (interval.$2 - interval.$1));
  return (total / 60000).round();
}

/// Minutes in [intervals] that no interval in [covered] already accounts for.
int _uncoveredMinutes(List<(int, int)> intervals, List<(int, int)> covered) {
  final cuts = _mergeIntervals(covered);
  var total = 0;
  for (final (start, end) in intervals) {
    var cursor = start;
    for (final (cutStart, cutEnd) in cuts) {
      if (cutEnd <= cursor) continue;
      if (cutStart >= end) break;
      if (cutStart > cursor) total += cutStart - cursor;
      cursor = math.max(cursor, cutEnd);
      if (cursor >= end) break;
    }
    if (cursor < end) total += end - cursor;
  }
  return (total / 60000).round();
}

List<(int, int)> _mergeIntervals(List<(int, int)> intervals) {
  final sorted = [...intervals]..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(int, int)>[];
  for (final (start, end) in sorted) {
    if (out.isEmpty) {
      out.add((start, end));
      continue;
    }
    final last = out.last;
    if (start <= last.$2) {
      out[out.length - 1] = (last.$1, math.max(last.$2, end));
    } else {
      out.add((start, end));
    }
  }
  return out;
}

List<HealthDayStat> dailyStats(
  List<HealthRecord> records, {
  HealthAggregation aggregation = HealthAggregation.sum,
  bool attributeToEnd = false,
}) {
  final byDay = <String, List<HealthRecord>>{};
  for (final r in records) {
    if (r.value == null) continue;
    final day = dayKey(attributeToEnd ? r.dateTo : r.dateFrom);
    byDay.putIfAbsent(day, () => []).add(r);
  }

  final out = <HealthDayStat>[];
  final days = byDay.keys.toList()..sort();
  for (final day in days) {
    final list = byDay[day]!;
    final values = list.map((r) => r.value!).toList();
    final sum = values.fold(0.0, (a, b) => a + b);
    final min = values.reduce(math.min);
    final max = values.reduce(math.max);
    final avg = values.isEmpty ? null : sum / values.length;
    switch (aggregation) {
      case HealthAggregation.sum:
        out.add(HealthDayStat(
            day: day,
            metric: list.first.type,
            count: list.length,
            sum: round2(sum),
            avg: avg == null ? null : round2(avg),
            min: round2(min),
            max: round2(max)));
      case HealthAggregation.average:
        out.add(HealthDayStat(
            day: day,
            metric: list.first.type,
            count: list.length,
            sum: round2(sum),
            avg: avg == null ? null : round2(avg),
            min: round2(min),
            max: round2(max)));
      case HealthAggregation.minMax:
        out.add(HealthDayStat(
            day: day,
            metric: list.first.type,
            count: list.length,
            sum: round2(sum),
            avg: avg == null ? null : round2(avg),
            min: round2(min),
            max: round2(max)));
      case HealthAggregation.latest:
        final latest = (list.toList()
              ..sort((a, b) => a.dateFrom.compareTo(b.dateFrom)))
            .last;
        out.add(HealthDayStat(
            day: day,
            metric: latest.type,
            count: list.length,
            sum: round2(latest.value!),
            avg: round2(latest.value!),
            min: round2(min),
            max: round2(max)));
      case HealthAggregation.list:
        final points = (list.toList()
              ..sort((a, b) => a.dateFrom.compareTo(b.dateFrom)))
            .map((r) => {'time': r.dateFrom, 'value': round2(r.value!)})
            .toList();
        out.add(HealthDayStat(
            day: day,
            metric: list.first.type,
            count: list.length,
            sum: round2(sum),
            avg: avg == null ? null : round2(avg),
            min: round2(min),
            max: round2(max),
            detail: {'points': points}));
    }
  }
  return out;
}

List<HealthDayStat> sleepDailyStats(List<HealthRecord> records) {
  final sessions = buildSleepSessions(sleepSegmentsFromRecords(records));
  if (sessions.isEmpty) return const [];
  final byDay = <String, List<SleepSession>>{};
  for (final session in sessions) {
    byDay.putIfAbsent(session.date, () => []).add(session);
  }
  final out = <HealthDayStat>[];
  for (final entry in byDay.entries) {
    final stages = <String, int>{};
    var asleep = 0;
    var awake = 0;
    var inBed = 0;
    for (final s in entry.value) {
      asleep += s.asleepMinutes;
      awake += s.awakeMinutes;
      inBed += s.inBedMinutes;
      for (final stage in s.stages.entries) {
        stages[stage.key] = (stages[stage.key] ?? 0) + stage.value;
      }
    }
    // Same rule as buildSleepSessions: time in bed covers everything the night
    // reported, so awake time is never counted as time in bed and the day-level
    // detail keeps the asleep + awake <= inBed invariant even for rows stored
    // by older builds.
    final dayInBed = math.max(inBed, asleep + awake);
    out.add(HealthDayStat(
      day: entry.key,
      metric: 'SLEEP',
      count: entry.value.length,
      sum: asleep.toDouble(),
      avg: entry.value.isEmpty ? null : round1(asleep / entry.value.length),
      min: asleep.toDouble(),
      max: asleep.toDouble(),
      detail: {
        'asleepMinutes': asleep,
        'awakeMinutes': awake,
        'inBedMinutes': dayInBed,
        'efficiency': dayInBed == 0 ? 0 : round1(asleep / dayInBed * 100),
        'stages': stages,
      },
    ));
  }
  out.sort((a, b) => a.day.compareTo(b.day));
  return out;
}

List<Map<String, dynamic>> heartDailyStats(List<HealthRecord> records) {
  final byDay = <String, List<double>>{};
  for (final r in records) {
    if (r.type != 'HEART_RATE' || r.value == null) continue;
    byDay.putIfAbsent(dayKey(r.dateFrom), () => []).add(r.value!);
  }
  final days = byDay.keys.toList()..sort();
  return [
    for (final day in days)
      {
        'date': day,
        'count': byDay[day]!.length,
        'avg': round1(byDay[day]!.reduce((a, b) => a + b) / byDay[day]!.length),
        'min': round1(byDay[day]!.reduce(math.min)),
        'max': round1(byDay[day]!.reduce(math.max)),
      }
  ];
}

List<Map<String, dynamic>> hourlyHeartStats(List<HealthRecord> records) {
  final byHour = <String, List<double>>{};
  for (final r in records) {
    if (r.type != 'HEART_RATE' || r.value == null) continue;
    final d = DateTime.fromMillisecondsSinceEpoch(r.dateFrom);
    final key = '${dayKeyForDate(d)}T${d.hour.toString().padLeft(2, '0')}';
    byHour.putIfAbsent(key, () => []).add(r.value!);
  }
  final keys = byHour.keys.toList()..sort();
  return [
    for (final key in keys)
      {
        'hour': key,
        'avg':
            round1(byHour[key]!.reduce((a, b) => a + b) / byHour[key]!.length),
        'min': round1(byHour[key]!.reduce(math.min)),
        'max': round1(byHour[key]!.reduce(math.max)),
      }
  ];
}

List<Map<String, dynamic>> workoutSummaries(List<HealthRecord> records) {
  final out = <Map<String, dynamic>>[];
  for (final r in records) {
    if (r.type != 'WORKOUT') continue;
    Map<String, dynamic>? raw;
    try {
      final decoded = jsonDecode(r.rawJson);
      if (decoded is Map<String, dynamic>) raw = decoded;
    } catch (_) {}
    final summary = raw?['workoutSummary'];
    final duration = ((r.dateTo - r.dateFrom) / 60000).round();
    out.add({
      'date': dayKey(r.dateFrom),
      'start': r.dateFrom,
      'end': r.dateTo,
      'durationMinutes': duration,
      'activity':
          summary is Map ? summary['workoutType'] ?? 'WORKOUT' : 'WORKOUT',
      'energyKcal': summary is Map
          ? round1((summary['totalEnergyBurned'] as num? ?? 0).toDouble())
          : null,
      'distanceMeters': summary is Map
          ? round1((summary['totalDistance'] as num? ?? 0).toDouble())
          : null,
      'steps':
          summary is Map ? (summary['totalSteps'] as num? ?? 0).toInt() : null,
      'source': r.sourceName,
    });
  }
  out.sort((a, b) => (a['start'] as int).compareTo(b['start'] as int));
  return out;
}
