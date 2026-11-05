import 'dart:convert';

class HealthRecord {
  final int? id;
  final String uuid;
  final String type;
  final double? value;
  final String unit;
  final int dateFrom;
  final int dateTo;
  final String sourceId;
  final String sourceName;
  final String platform;
  final int recordingMethod;
  final String rawJson;
  final int syncedAt;

  const HealthRecord({
    this.id,
    required this.uuid,
    required this.type,
    this.value,
    required this.unit,
    required this.dateFrom,
    required this.dateTo,
    this.sourceId = '',
    this.sourceName = '',
    this.platform = '',
    this.recordingMethod = 0,
    this.rawJson = '',
    required this.syncedAt,
  });

  factory HealthRecord.fromMap(Map<String, Object?> m) => HealthRecord(
        id: m['id'] as int?,
        uuid: m['uuid'] as String,
        type: m['type'] as String,
        value: (m['value'] as num?)?.toDouble(),
        unit: m['unit'] as String? ?? '',
        dateFrom: m['date_from'] as int,
        dateTo: m['date_to'] as int,
        sourceId: m['source_id'] as String? ?? '',
        sourceName: m['source_name'] as String? ?? '',
        platform: m['platform'] as String? ?? '',
        recordingMethod: m['recording_method'] as int? ?? 0,
        rawJson: m['raw_json'] as String? ?? '',
        syncedAt: m['synced_at'] as int,
      );

  Map<String, Object?> toMap() => {
        if (id != null && id != 0) 'id': id,
        'uuid': uuid,
        'type': type,
        'value': value,
        'unit': unit,
        'date_from': dateFrom,
        'date_to': dateTo,
        'source_id': sourceId,
        'source_name': sourceName,
        'platform': platform,
        'recording_method': recordingMethod,
        'raw_json': rawJson,
        'synced_at': syncedAt,
      };
}

class HealthDayStat {
  final String day;
  final String metric;
  final int count;
  final double sum;
  final double? avg;
  final double? min;
  final double? max;
  final Map<String, Object?> detail;

  const HealthDayStat({
    required this.day,
    required this.metric,
    this.count = 0,
    this.sum = 0,
    this.avg,
    this.min,
    this.max,
    this.detail = const {},
  });

  factory HealthDayStat.fromMap(Map<String, Object?> m) => HealthDayStat(
        day: m['day'] as String,
        metric: m['metric'] as String,
        count: m['count'] as int? ?? 0,
        sum: (m['sum'] as num?)?.toDouble() ?? 0,
        avg: (m['avg'] as num?)?.toDouble(),
        min: (m['min'] as num?)?.toDouble(),
        max: (m['max'] as num?)?.toDouble(),
        detail: _decodeDetail(m['detail_json'] as String?),
      );

  Map<String, Object?> toMap() => {
        'day': day,
        'metric': metric,
        'count': count,
        'sum': sum,
        'avg': avg,
        'min': min,
        'max': max,
        'detail_json': detail.isEmpty ? '' : jsonEncode(detail),
      };
}

Map<String, Object?> _decodeDetail(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, Object?>() : const {};
  } catch (_) {
    return const {};
  }
}

class HealthSyncState {
  final String metric;
  final int? lastSyncedAt;
  final int? lastSuccessAt;
  final String? lastError;

  const HealthSyncState({
    required this.metric,
    this.lastSyncedAt,
    this.lastSuccessAt,
    this.lastError,
  });

  factory HealthSyncState.fromMap(Map<String, Object?> m) => HealthSyncState(
        metric: m['metric'] as String,
        lastSyncedAt: m['last_synced_at'] as int?,
        lastSuccessAt: m['last_success_at'] as int?,
        lastError: m['last_error'] as String?,
      );
}

class SleepSegment {
  final String uuid;
  final String type;
  final int start;
  final int end;
  final String sourceId;
  final String sourceName;

  const SleepSegment({
    required this.uuid,
    required this.type,
    required this.start,
    required this.end,
    this.sourceId = '',
    this.sourceName = '',
  });

  int get minutes => ((end - start) / 60000).round();
}

class SleepSession {
  final String date;
  final int start;
  final int end;
  final int inBedMinutes;
  final int asleepMinutes;
  final int awakeMinutes;
  final double efficiency;
  final Map<String, int> stages;
  final String sourceName;

  const SleepSession({
    required this.date,
    required this.start,
    required this.end,
    required this.inBedMinutes,
    required this.asleepMinutes,
    required this.awakeMinutes,
    required this.efficiency,
    required this.stages,
    this.sourceName = '',
  });
}
