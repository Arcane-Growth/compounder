import 'package:compounder/domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Regression tests for audit finding M3: day stepping must use calendar
/// arithmetic (`DateTime(y, m, d - 1)`), never `Duration(days: 1)`.
///
/// A 24-hour subtraction from local midnight lands on 23:00 the previous day
/// across a spring-forward boundary (and 01:00 across a fall-back one), so the
/// result is not a day key and the streak walk stops early.
///
/// The ambient timezone of the test process cannot be pinned from inside Dart,
/// so the DST boundary is constructed explicitly with `tz.TZDateTime` in
/// America/New_York. That makes the DST assertions deterministic in any
/// ambient zone: they prove the boundary exists and that the production
/// helper returns a calendar day key rather than a shifted instant.
void main() {
  setUpAll(tzdata.initializeTimeZones);

  tz.Location ny() => tz.getLocation('America/New_York');

  group('calendar day stepping (M3)', () {
    test('Duration day stepping is wrong at the 2026-03-08 spring-forward', () {
      // 2026-03-08 02:00 EST -> 03:00 EDT in America/New_York.
      final midnight = tz.TZDateTime(ny(), 2026, 3, 9);
      final viaDuration = midnight.subtract(const Duration(days: 1));
      // The bug: 24 hours before 2026-03-09 00:00 EDT is 2026-03-07 23:00 EST.
      expect(viaDuration.day, 7);
      expect(viaDuration.hour, 23);
      // Calendar arithmetic lands on the real previous day at midnight.
      final viaCalendar = tz.TZDateTime(ny(), 2026, 3, 9 - 1);
      expect(viaCalendar.day, 8);
      expect(viaCalendar.hour, 0);
    });

    test('Duration day stepping is wrong at the 2026-11-01 fall-back', () {
      // 2026-11-01 02:00 EDT -> 01:00 EST in America/New_York.
      final midnight = tz.TZDateTime(ny(), 2026, 11, 2);
      final viaDuration = midnight.subtract(const Duration(days: 1));
      expect(viaDuration.day, 1);
      expect(viaDuration.hour, 1);
      final viaCalendar = tz.TZDateTime(ny(), 2026, 11, 2 - 1);
      expect(viaCalendar.day, 1);
      expect(viaCalendar.hour, 0);
    });

    test('previousDayKey returns a calendar day key, not a shifted instant',
        () {
      // Production helper, exercised on the exact boundary dates. The input is
      // a TZDateTime, so it carries its own zone: this discriminates the
      // calendar implementation from Duration stepping in ANY ambient zone,
      // including UTC where a 24-hour subtraction happens to be correct.
      for (final day in [
        tz.TZDateTime(ny(), 2026, 3, 9),
        tz.TZDateTime(ny(), 2026, 11, 2),
      ]) {
        final prev = previousDayKey(day);
        expect(prev.hour, 0, reason: 'day key must stay at local midnight');
        expect(prev.minute, 0);
        expect(prev.second, 0);
        expect(prev.day, day.day - 1);
        expect(prev.month, day.month);
        expect(prev.year, day.year);
      }
    });

    test('previousDayKey crosses month and year boundaries', () {
      expect(previousDayKey(DateTime(2026, 3, 1)), DateTime(2026, 2, 28));
      expect(previousDayKey(DateTime(2026, 1, 1)), DateTime(2025, 12, 31));
      expect(previousDayKey(DateTime(2024, 3, 1)), DateTime(2024, 2, 29));
    });

    test('moodStreak counts across the 2026-03-08 spring-forward boundary', () {
      // Check-ins built from the DST zone so the calendar dates are exact.
      final checkins = [
        tz.TZDateTime(ny(), 2026, 3, 6, 8),
        tz.TZDateTime(ny(), 2026, 3, 7, 21),
        tz.TZDateTime(ny(), 2026, 3, 8, 9),
        tz.TZDateTime(ny(), 2026, 3, 9, 7),
        tz.TZDateTime(ny(), 2026, 3, 10, 22),
      ];
      expect(Mind.moodStreak(checkins, today: DateTime(2026, 3, 10, 12)), 5);
    });

    test('moodStreak counts across the 2026-11-01 fall-back boundary', () {
      final checkins = [
        tz.TZDateTime(ny(), 2026, 10, 30, 8),
        tz.TZDateTime(ny(), 2026, 10, 31, 21),
        tz.TZDateTime(ny(), 2026, 11, 1, 9),
        tz.TZDateTime(ny(), 2026, 11, 2, 7),
      ];
      expect(Mind.moodStreak(checkins, today: DateTime(2026, 11, 2, 12)), 4);
    });

    test('moodStreak stops at the first missing day across the boundary', () {
      final checkins = [
        tz.TZDateTime(ny(), 2026, 3, 6, 8),
        // 2026-03-07 missing
        tz.TZDateTime(ny(), 2026, 3, 8, 9),
        tz.TZDateTime(ny(), 2026, 3, 9, 7),
        tz.TZDateTime(ny(), 2026, 3, 10, 22),
      ];
      expect(Mind.moodStreak(checkins, today: DateTime(2026, 3, 10, 12)), 3);
    });
  });
}
