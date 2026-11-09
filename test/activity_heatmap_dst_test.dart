import 'package:compounder/domain/activity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// DST regression guard for the activity streak's calendar arithmetic.
///
/// [previousDayKey] and [currentStreak] build ambient-zone `DateTime`s, so a
/// `Duration(days: 1)` implementation only fails when the process zone has a
/// DST transition. [setUpAll] fails loudly instead of passing vacuously when
/// it does not: run with `TZ=America/New_York` (the CI test command pins it).
void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    // Precondition, not a test: without a real transition in the ambient zone
    // the Duration implementation would pass every assertion below.
    expect(DateTime(2026, 3, 8, 1).timeZoneOffset,
        isNot(DateTime(2026, 3, 8, 4).timeZoneOffset),
        reason: 'ambient zone has no 2026-03-08 DST transition; '
            'run with TZ=America/New_York');
  });

  test('a DST transition day is one day, not zero or two', () {
    final ny = tz.getLocation('America/New_York');
    final before = tz.TZDateTime(ny, 2026, 3, 7, 12);
    final dst = tz.TZDateTime(ny, 2026, 3, 8, 12);
    final after = tz.TZDateTime(ny, 2026, 3, 9, 12);
    // Fail loudly if the zone data ever stops having the transition: the
    // test would otherwise pass without exercising DST at all.
    expect(dst.timeZoneOffset, isNot(before.timeZoneOffset),
        reason: 'America/New_York must spring forward on 2026-03-08');
    expect(localDayKey(before), '2026-03-07');
    expect(localDayKey(dst), '2026-03-08');
    expect(localDayKey(after), '2026-03-09');
    final days = {
      for (final d in [before, dst, after])
        localDayKey(d): PillarDay(day: localDayKey(d), workoutCount: 1),
    };
    expect(currentStreak(days, after), 3,
        reason: 'calendar-day arithmetic must not skip the 23-hour day');
    expect(longestStreak(days), 3);
    expect(previousDayKey('2026-03-09'), '2026-03-08');
    expect(previousDayKey('2026-03-08'), '2026-03-07');
  });
}
