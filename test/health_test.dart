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

/// A fully staged Health Connect night: an 8h SLEEP_SESSION whose stage
/// records add up to the whole session window, with 90 minutes awake.
/// deep 60 + light 240 + rem 90 = 390 asleep, awake 90, in bed 480.
List<SleepSegment> _stagedNightWithAwake() => [
      SleepSegment(
          uuid: 'session',
          type: 'SLEEP_SESSION',
          start: _at(1, 23),
          end: _at(2, 7),
          sourceName: 'watch'),
      SleepSegment(
          uuid: 'deep',
          type: 'SLEEP_DEEP',
          start: _at(1, 23),
          end: _at(2, 0),
          sourceName: 'watch'),
      SleepSegment(
          uuid: 'light',
          type: 'SLEEP_LIGHT',
          start: _at(2, 0),
          end: _at(2, 4),
          sourceName: 'watch'),
      SleepSegment(
          uuid: 'rem',
          type: 'SLEEP_REM',
          start: _at(2, 4),
          end: _at(2, 5, 30),
          sourceName: 'watch'),
      SleepSegment(
          uuid: 'awake',
          type: 'SLEEP_AWAKE',
          start: _at(2, 5, 30),
          end: _at(2, 7),
          sourceName: 'watch'),
    ];

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

  group('sleep total is never under-reported', () {
    test('a lone REM stage does not shrink a night that has a session record',
        () {
      // Regression: the old code summed only DEEP/LIGHT/REM whenever any of
      // them existed, so a phone that synced one 90-minute REM stage reported
      // 90 minutes for an 8-hour night.
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 'session',
            type: 'SLEEP_SESSION',
            start: _at(1, 23),
            end: _at(2, 7),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'rem',
            type: 'SLEEP_REM',
            start: _at(2, 3),
            end: _at(2, 4, 30),
            sourceName: 'watch'),
      ]);
      expect(sessions, hasLength(1));
      expect(sessions.single.asleepMinutes, 8 * 60);
    });

    test('prefers a source with a session record over a stage-only source', () {
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 's',
            type: 'SLEEP_SESSION',
            start: _at(1, 23),
            end: _at(2, 7),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'd',
            type: 'SLEEP_DEEP',
            start: _at(1, 23),
            end: _at(1, 23, 30),
            sourceName: 'ring'),
        SleepSegment(
            uuid: 'l',
            type: 'SLEEP_LIGHT',
            start: _at(1, 23, 30),
            end: _at(2, 6),
            sourceName: 'ring'),
        SleepSegment(
            uuid: 'r',
            type: 'SLEEP_REM',
            start: _at(2, 6),
            end: _at(2, 7),
            sourceName: 'ring'),
      ]);
      expect(sessions, hasLength(1));
      expect(sessions.single.sourceName, 'watch');
      expect(sessions.single.asleepMinutes, 8 * 60);
    });

    test('a source with only SLEEP_ASLEEP still reports that time', () {
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 'a',
            type: 'SLEEP_ASLEEP',
            start: _at(1, 23),
            end: _at(2, 6, 30),
            sourceName: 'band'),
      ]);
      expect(sessions.single.asleepMinutes, 450);
      expect(sessions.single.stages['SLEEP_ASLEEP'], 450);
    });

    test('total is never less than the summed stages or the session', () {
      final sessions = buildSleepSessions([
        SleepSegment(
            uuid: 's',
            type: 'SLEEP_SESSION',
            start: _at(1, 23),
            end: _at(2, 6),
            sourceName: 'watch'),
        SleepSegment(
            uuid: 'd',
            type: 'SLEEP_DEEP',
            start: _at(1, 23),
            end: _at(2, 7),
            sourceName: 'watch'),
      ]);
      expect(sessions.single.asleepMinutes, 8 * 60);
      expect(sessions.single.inBedMinutes, greaterThanOrEqualTo(8 * 60));
    });

    test('daily stats use the session total, not the single synced stage', () {
      final stats = sleepDailyStats([
        _rec('SLEEP_SESSION', _at(1, 23), _at(2, 7)),
        _rec('SLEEP_REM', _at(2, 3), _at(2, 4, 30)),
      ]);
      expect(stats, hasLength(1));
      expect(stats.single.sum, 8 * 60);
    });

    test('a fully staged night subtracts awake time from the session total', () {
      // Regression: raising asleep to the session length whenever a session
      // record existed pinned efficiency at 100% and never subtracted awake
      // time, so a real Health Connect night lost its stage breakdown.
      final sessions = buildSleepSessions(_stagedNightWithAwake());
      expect(sessions, hasLength(1));
      final s = sessions.single;
      expect(s.asleepMinutes, 390); // deep 60 + light 240 + rem 90
      expect(s.awakeMinutes, 90);
      expect(s.inBedMinutes, 480);
      expect(s.efficiency, closeTo(81.3, 0.1));
    });

    test('asleep plus awake never exceeds time in bed', () {
      final s = buildSleepSessions(_stagedNightWithAwake()).single;
      expect(s.asleepMinutes + s.awakeMinutes,
          lessThanOrEqualTo(s.inBedMinutes));
      expect(s.asleepMinutes + s.awakeMinutes, 480);
    });

    test('daily sleep stats report the staged efficiency, not 100 percent', () {
      final stats = sleepDailyStats([
        _rec('SLEEP_SESSION', _at(1, 23), _at(2, 7)),
        _rec('SLEEP_DEEP', _at(1, 23), _at(2, 0)),
        _rec('SLEEP_LIGHT', _at(2, 0), _at(2, 4)),
        _rec('SLEEP_REM', _at(2, 4), _at(2, 5, 30)),
        _rec('SLEEP_AWAKE', _at(2, 5, 30), _at(2, 7)),
      ]);
      expect(stats, hasLength(1));
      final detail = stats.single.detail;
      expect(detail['asleepMinutes'], 390);
      expect(detail['awakeMinutes'], 90);
      expect(detail['inBedMinutes'], 480);
      expect((detail['efficiency'] as num).toDouble(), closeTo(81.3, 0.1));
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
