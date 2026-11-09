import 'package:compounder/health/models.dart';
import 'package:compounder/health/service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';

/// Records every fetch window so the test can prove the sync never asks the
/// plugin for more than one day at a time.
class _RecordingSource implements HealthSource {
  final List<({HealthDataType type, DateTime start, DateTime end})> calls = [];
  final Set<String> unavailable;
  final Set<String> failing;

  _RecordingSource({
    this.unavailable = const {},
    this.failing = const {},
  });

  @override
  Future<void> configure() async {}

  @override
  Future<HealthConnectSdkStatus?> sdkStatus() async =>
      HealthConnectSdkStatus.sdkAvailable;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> install() async {}

  @override
  bool isTypeAvailable(HealthDataType type) => !unavailable.contains(type.name);

  @override
  Future<bool> requestAuthorization(List<HealthDataType> types) async => true;

  @override
  Future<bool?> hasPermissions(List<HealthDataType> types) async => true;

  @override
  Future<bool> isHistoryAvailable() async => true;

  @override
  Future<bool> isHistoryAuthorized() async => false;

  @override
  Future<bool> requestHistoryAuthorization() async => true;

  @override
  Future<List<HealthDataPoint>> fetch({
    required HealthDataType type,
    required DateTime start,
    required DateTime end,
  }) async {
    calls.add((type: type, start: start, end: end));
    if (failing.contains(type.name)) {
      throw StateError('boom ${type.name}');
    }
    return [
      for (var i = 0; i < 1; i++)
        HealthDataPoint(
          uuid: '${type.name}-${start.millisecondsSinceEpoch}-$i',
          value: NumericHealthValue(numericValue: 60 + i),
          type: type,
          unit: HealthDataUnit.BEATS_PER_MINUTE,
          dateFrom: start.add(Duration(minutes: i)),
          dateTo: start.add(Duration(minutes: i + 1)),
          sourcePlatform: HealthPlatformType.googleHealthConnect,
          sourceDeviceId: 'device',
          sourceId: 'src',
          sourceName: 'src',
        ),
    ];
  }

  @override
  Future<void> revokePermissions() async {}
}

HealthRecord _toRecord(HealthDataPoint p, DateTime syncedAt) => HealthRecord(
      uuid: p.uuid,
      type: p.type.name,
      value: 1,
      unit: p.unit.name,
      dateFrom: p.dateFrom.millisecondsSinceEpoch,
      dateTo: p.dateTo.millisecondsSinceEpoch,
      sourceId: p.sourceId,
      sourceName: p.sourceName,
      syncedAt: syncedAt.millisecondsSinceEpoch,
    );

void main() {
  final now = DateTime(2026, 11, 6, 12);

  group('chunked health sync', () {
    test('a 30-day lookback is walked in 30 one-day fetches, not one',
        () async {
      final source = _RecordingSource();
      final stamps = <String, int>{};
      final result = await runChunkedSync(
        source: source,
        types: const [HealthDataType.HEART_RATE],
        start: now.subtract(const Duration(days: 30)),
        now: now,
        resumeStates: const {},
        toRecord: _toRecord,
        upsert: (records) async => records.length,
        stamp: (metric, chunkEndMs, error) async {
          stamps[metric] = chunkEndMs;
        },
      );

      expect(source.calls, hasLength(30));
      expect(result.records, 30);
      expect(result.errors, isEmpty);
      for (final call in source.calls) {
        expect(call.end.difference(call.start),
            lessThanOrEqualTo(const Duration(days: 1)));
      }
      // Chunks are contiguous and end exactly at `now`.
      expect(source.calls.first.start, now.subtract(const Duration(days: 30)));
      expect(source.calls.last.end, now);
      for (var i = 1; i < source.calls.length; i++) {
        expect(source.calls[i].start, source.calls[i - 1].end);
      }
      expect(stamps['HEART_RATE'], now.millisecondsSinceEpoch);
    });

    test('every type is chunked to one day, including high-frequency ones',
        () async {
      final source = _RecordingSource();
      await runChunkedSync(
        source: source,
        types: const [
          HealthDataType.HEART_RATE,
          HealthDataType.STEPS,
          HealthDataType.SLEEP_REM,
        ],
        start: now.subtract(const Duration(days: 3)),
        now: now,
        resumeStates: const {},
        toRecord: _toRecord,
        upsert: (records) async => records.length,
        stamp: (metric, chunkEndMs, error) async {},
      );
      expect(source.calls, hasLength(9));
      for (final call in source.calls) {
        expect(call.end.difference(call.start),
            lessThanOrEqualTo(const Duration(days: 1)));
      }
    });

    test('a partial final window is clamped to now', () async {
      final source = _RecordingSource();
      await runChunkedSync(
        source: source,
        types: const [HealthDataType.STEPS],
        start: now.subtract(const Duration(hours: 30)),
        now: now,
        resumeStates: const {},
        toRecord: _toRecord,
        upsert: (records) async => records.length,
        stamp: (metric, chunkEndMs, error) async {},
      );
      expect(source.calls, hasLength(2));
      expect(source.calls.last.end, now);
      expect(source.calls.last.end.difference(source.calls.last.start),
          lessThanOrEqualTo(const Duration(days: 1)));
    });

    test('a failing type does not abort the remaining types', () async {
      final source = _RecordingSource(failing: {'HEART_RATE'});
      final result = await runChunkedSync(
        source: source,
        types: const [HealthDataType.HEART_RATE, HealthDataType.STEPS],
        start: now.subtract(const Duration(days: 2)),
        now: now,
        resumeStates: const {},
        toRecord: _toRecord,
        upsert: (records) async => records.length,
        stamp: (metric, chunkEndMs, error) async {},
      );
      expect(result.errors.containsKey('HEART_RATE'), isTrue);
      expect(result.errors.containsKey('STEPS'), isFalse);
      expect(result.records, 2);
      expect(source.calls.where((c) => c.type == HealthDataType.STEPS),
          hasLength(2));
    });

    test('an upsert failure is caught per chunk, not left to escape', () async {
      final source = _RecordingSource();
      final result = await runChunkedSync(
        source: source,
        types: const [HealthDataType.STEPS],
        start: now.subtract(const Duration(days: 2)),
        now: now,
        resumeStates: const {},
        toRecord: _toRecord,
        upsert: (records) async => throw StateError('disk full'),
        stamp: (metric, chunkEndMs, error) async {},
      );
      expect(result.errors['STEPS'], contains('disk full'));
      expect(result.records, 0);
      // Both chunks were still attempted.
      expect(source.calls, hasLength(2));
    });

    test('an unavailable type is skipped without fetching', () async {
      final source = _RecordingSource(unavailable: {'HEART_RATE'});
      await runChunkedSync(
        source: source,
        types: const [HealthDataType.HEART_RATE, HealthDataType.STEPS],
        start: now.subtract(const Duration(days: 1)),
        now: now,
        resumeStates: const {},
        toRecord: _toRecord,
        upsert: (records) async => records.length,
        stamp: (metric, chunkEndMs, error) async {},
      );
      expect(source.calls.every((c) => c.type == HealthDataType.STEPS), isTrue);
    });

    test('a killed sync resumes from the last completed chunk', () async {
      final source = _RecordingSource();
      // Simulate a process kill after 10 of 30 chunks: the stamp is the end of
      // the last chunk that finished.
      final resumeAt = now.subtract(const Duration(days: 20));
      final result = await runChunkedSync(
        source: source,
        types: const [HealthDataType.HEART_RATE],
        start: now.subtract(const Duration(days: 30)),
        now: now,
        resumeStates: {
          'HEART_RATE': HealthSyncState(
            metric: 'HEART_RATE',
            lastSyncedAt: resumeAt.millisecondsSinceEpoch,
          ),
        },
        toRecord: _toRecord,
        upsert: (records) async => records.length,
        stamp: (metric, chunkEndMs, error) async {},
      );
      // 21 days of work remain: the 20 unfinished days plus a one-day overlap
      // on the last completed chunk to catch records that landed late.
      expect(source.calls, hasLength(21));
      expect(result.records, 21);
      expect(
          source.calls.first.start, resumeAt.subtract(const Duration(days: 1)));
      expect(source.calls.last.end, now);
    });

    test('sync state is stamped per chunk, not only per type', () async {
      final source = _RecordingSource();
      final stamps = <int>[];
      await runChunkedSync(
        source: source,
        types: const [HealthDataType.STEPS],
        start: now.subtract(const Duration(days: 3)),
        now: now,
        resumeStates: const {},
        toRecord: _toRecord,
        upsert: (records) async => records.length,
        stamp: (metric, chunkEndMs, error) async => stamps.add(chunkEndMs),
      );
      expect(stamps, hasLength(3));
      expect(stamps,
          orderedEquals(source.calls.map((c) => c.end.millisecondsSinceEpoch)));
    });
  });
}
