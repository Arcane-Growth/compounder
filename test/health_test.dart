import 'package:compounder/health/analysis.dart';
import 'package:compounder/health/models.dart';
import 'package:flutter_test/flutter_test.dart';

int _at(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 1, day, hour, minute).millisecondsSinceEpoch;

HealthRecord _rec(
  String type,
  int start,
  int end, {
  String source = 'phone',
  double? value,
}) =>
    HealthRecord(
      uuid: '$type-$start-$end-$source',
      type: type,
      value: value,
      unit: 'MINUTE',
      dateFrom: start,
      dateTo: end,
      sourceId: source,
      sourceName: source,
      syncedAt: 0,
    );

void main() {
  group('sleep reconstruction', () {
    test('builds one night with stage totals and efficiency', () {
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 'a',
            type: 'SLEEP_DEEP',
            start: _at(1, 23),
            end: _at(1, 23, 30),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'b',
            type: 'SLEEP_LIGHT',
            start: _at(1, 23, 30),
            end: _at(2, 2),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'c',
            type: 'SLEEP_REM',
            start: _at(2, 2),
            end: _at(2, 3),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'd',
            type: 'SLEEP_AWAKE',
            start: _at(2, 3),
            end: _at(2, 3, 15),
            sourceName: 'watch'),
      ]);
      expect(sessions, hasLength(1));
      final s = sessions.single;
      expect(s.date, '2026-01-02');
      expect(s.asleepMinutes, 30 + 150 + 60);
      expect(s.awakeMinutes, 15);
      expect(s.stages['SLEEP_DEEP'], 30);
      expect(s.stages['SLEEP_LIGHT'], 150);
      expect(s.stages['SLEEP_REM'], 60);
      expect(s.efficiency, greaterThan(90));
    });

    test('does not double-count generic asleep when specific stages exist', () {
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 'a',
            type: 'SLEEP_ASLEEP',
            start: _at(1, 23),
            end: _at(2, 7),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'b',
            type: 'SLEEP_DEEP',
            start: _at(1, 23),
            end: _at(2, 1),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'c',
            type: 'SLEEP_LIGHT',
            start: _at(2, 1),
            end: _at(2, 7),
            sourceName: 'watch'),
      ]);
      expect(sessions, hasLength(1));
      expect(sessions.single.asleepMinutes, 8 * 60);
    });

    test('prefers the most detailed source when sources overlap', () {
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 'a',
            type: 'SLEEP_ASLEEP',
            start: _at(1, 23),
            end: _at(2, 7),
            sourceName: 'generic'),
        SleepSegment(
            uuid: 'b',
            type: 'SLEEP_DEEP',
            start: _at(1, 23),
            end: _at(2, 1),
            sourceName: 'detailed'),
        SleepSegment(
            uuid: 'c',
            type: 'SLEEP_LIGHT',
            start: _at(2, 1),
            end: _at(2, 7),
            sourceName: 'detailed'),
      ]);
      expect(sessions, hasLength(1));
      expect(sessions.single.sourceName, 'detailed');
      expect(sessions.single.stages['SLEEP_DEEP'], 120);
    });

    test('uses session duration when only a session record is available', () {
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 'a',
            type: 'SLEEP_SESSION',
            start: _at(1, 23),
            end: _at(2, 7),
            sourceName: 'watch'),
      ]);
      expect(sessions, hasLength(1));
      expect(sessions.single.asleepMinutes, 8 * 60);
      expect(sessions.single.efficiency, 100);
    });

    test('splits a nap from a night when the gap is large', () {
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 'a',
            type: 'SLEEP_LIGHT',
            start: _at(1, 23),
            end: _at(2, 7),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'b',
            type: 'SLEEP_LIGHT',
            start: _at(2, 14),
            end: _at(2, 15),
            sourceName: 'watch'),
      ]);
      expect(sessions, hasLength(2));
      expect(sessions.first.date, '2026-01-02');
      expect(sessions.last.date, '2026-01-02');
    });
  });

  group('aggregation', () {
    test('sums steps per day', () {
      final stats = dailyStats([
        _rec('STEPS', _at(1, 9), _at(1, 10), value: 1000),
        _rec('STEPS', _at(1, 12), _at(1, 13), value: 2500),
        _rec('STEPS', _at(2, 8), _at(2, 9), value: 500),
      ]);
      expect(stats, hasLength(2));
      expect(stats.first.sum, 3500);
      expect(stats.last.sum, 500);
    });

    test('heart rate daily stats include avg/min/max', () {
      final stats = heartDailyStats([
        _rec('HEART_RATE', _at(1, 9), _at(1, 9), value: 60),
        _rec('HEART_RATE', _at(1, 10), _at(1, 10), value: 80),
      ]);
      expect(stats.single['count'], 2);
      expect(stats.single['avg'], 70);
      expect(stats.single['min'], 60);
      expect(stats.single['max'], 80);
    });

    test('sleep daily stats carry stage details', () {
      final stats = sleepDailyStats([
        _rec('SLEEP_DEEP', _at(1, 23), _at(2, 1)),
        _rec('SLEEP_LIGHT', _at(2, 1), _at(2, 6)),
      ]);
      expect(stats.single.day, '2026-01-02');
      expect(stats.single.sum, 420);
      expect((stats.single.detail['stages'] as Map)['SLEEP_DEEP'], 120);
    });

    test('sleep daily stats keep a cross-midnight night together', () {
      final stats = sleepDailyStats([
        _rec('SLEEP_DEEP', _at(1, 23), _at(1, 23, 30)),
        _rec('SLEEP_LIGHT', _at(1, 23, 30), _at(2, 6)),
      ]);
      expect(stats, hasLength(1));
      expect(stats.single.day, '2026-01-02');
      expect(stats.single.sum, 7 * 60);
    });

    test('day stat JSON round-trips detail', () {
      const stat = HealthDayStat(
        day: '2026-01-02',
        metric: 'SLEEP',
        sum: 420,
        detail: {
          'stages': {'SLEEP_DEEP': 120}
        },
      );
      final decoded = HealthDayStat.fromMap(stat.toMap());
      expect(decoded.day, '2026-01-02');
      expect((decoded.detail['stages'] as Map)['SLEEP_DEEP'], 120);
    });
  });
}
