import 'package:compounder/coach/health_tools.dart';
import 'package:compounder/coach/tools.dart';
import 'package:compounder/health/service.dart';
import 'package:compounder/services/notify.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guards for audit finding M3 (commit af1ed03): every day step and
/// every `+1 day` end-exclusive window bound must use calendar arithmetic
/// (`DateTime(y, m, d + 1)`), never `Duration(days: 1)`.
///
/// A 24-hour step from local midnight lands on 23:00 (fall-back) or 01:00
/// (spring-forward), so a Duration-based bound silently truncates or widens
/// every health-sync, digest and coach date window.
///
/// These helpers build ambient-zone `DateTime`s, so the defect is only visible
/// when the process zone has a DST transition. [setUpAll] fails loudly instead
/// of passing vacuously when it does not: run with `TZ=America/New_York`.
void main() {
  setUpAll(() {
    // Precondition, not a test: without a real transition in the ambient zone
    // every assertion below would hold for the Duration implementation too.
    expect(DateTime(2026, 3, 8, 1).timeZoneOffset,
        isNot(DateTime(2026, 3, 8, 4).timeZoneOffset),
        reason: 'ambient zone has no 2026-03-08 DST transition; '
            'run with TZ=America/New_York');
    expect(DateTime(2026, 11, 1, 0).timeZoneOffset,
        isNot(DateTime(2026, 11, 1, 12).timeZoneOffset),
        reason: 'ambient zone has no 2026-11-01 DST transition; '
            'run with TZ=America/New_York');
  });

  /// The two boundary days, plus the day after each: the day *after* a
  /// spring-forward is where a Duration subtraction from midnight lands on
  /// 23:00, and the day *after* a fall-back is where it lands on 01:00.
  final anchors = <String, DateTime>{
    'spring-forward day 2026-03-08': DateTime(2026, 3, 8, 12),
    'day after spring-forward 2026-03-09': DateTime(2026, 3, 9, 12),
    'fall-back day 2026-11-01': DateTime(2026, 11, 1, 12),
    'day after fall-back 2026-11-02': DateTime(2026, 11, 2, 12),
  };

  group('coach dateRange end bound (tools.dart)', () {
    for (final entry in anchors.entries) {
      test('${entry.key}: to is next-day local midnight', () {
        final now = entry.value;
        final day = '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}';
        final r = dateRange({'start': day, 'end': day}, now: now);
        final from = DateTime.fromMillisecondsSinceEpoch(r.from);
        final to = DateTime.fromMillisecondsSinceEpoch(r.to);

        expect(from, DateTime(now.year, now.month, now.day),
            reason: 'from must be local midnight on the requested day');
        expect(to, DateTime(now.year, now.month, now.day + 1),
            reason: 'to must be the exclusive next-day local midnight');
        expect(to.hour, 0, reason: 'end bound must not drift off midnight');
        expect(to.minute, 0);
        expect(to.second, 0);
        expect(to.millisecond, 0);
      });
    }

    test('to is exactly one calendar day after from, not 24 hours', () {
      final now = DateTime(2026, 3, 8, 12);
      final r =
          dateRange({'start': '2026-03-08', 'end': '2026-03-08'}, now: now);
      final from = DateTime.fromMillisecondsSinceEpoch(r.from);
      final to = DateTime.fromMillisecondsSinceEpoch(r.to);
      // Spring-forward day: 24 hours after 2026-03-08 00:00 is 2026-03-09 01:00.
      expect(to.difference(from), isNot(const Duration(hours: 24)));
      expect(to.difference(from), const Duration(hours: 23));
    });
  });

  group('coach MindLogTool default window (tools.dart)', () {
    // Same shape as the digest window: local midnight six calendar days back,
    // exclusive next-day midnight. A Duration-based window would land on
    // 23:00/01:00 across a transition (audit m3-dst MINOR-4).
    for (final entry in anchors.entries) {
      test('${entry.key}: from is local midnight 6 days back', () {
        final now = entry.value;
        final r = mindLogWindow(now);
        final from = DateTime.fromMillisecondsSinceEpoch(r.from);
        final to = DateTime.fromMillisecondsSinceEpoch(r.to);

        expect(from, DateTime(now.year, now.month, now.day - 6),
            reason: 'start must be local midnight 6 calendar days back');
        expect(from.hour, 0);
        expect(from.minute, 0);
        expect(to, DateTime(now.year, now.month, now.day + 1),
            reason: 'end must be the exclusive next-day local midnight');
        expect(to.hour, 0);
        expect(to.difference(from).inHours, isNot(7 * 24),
            reason: 'a 7-day window across a transition is not 168 hours');
      });
    }
  });

  group('coach healthRange default window (health_tools.dart)', () {
    // Every one of these windows contains exactly one DST transition, so the
    // calendar span is `days` days minus/plus one hour. Pinned explicitly: a
    // Duration-based window would be exactly `days * 24` hours in all cases.
    for (final entry in anchors.entries) {
      final spring = entry.key.contains('spring');
      for (final days in [7, 14, 30]) {
        test('${entry.key}: defaultDays $days', () {
          final now = entry.value;
          final r = healthRange({}, defaultDays: days, now: now);
          final from = DateTime.fromMillisecondsSinceEpoch(r.from);
          final to = DateTime.fromMillisecondsSinceEpoch(r.to);

          expect(from, DateTime(now.year, now.month, now.day - (days - 1)),
              reason: 'start must be local midnight $days-1 days back');
          expect(from.hour, 0);
          expect(to, DateTime(now.year, now.month, now.day + 1),
              reason: 'end must be the exclusive next-day local midnight');
          expect(to.hour, 0);
          expect(to.difference(from).inHours, days * 24 + (spring ? -1 : 1),
              reason:
                  'window must span $days calendar days, not $days*24 hours');
        });
      }
    }
  });

  group('digest 7-day window (notify.dart)', () {
    for (final entry in anchors.entries) {
      test('${entry.key}: from is local midnight 6 days back', () {
        final now = entry.value;
        final from = digestWindowStart(now);
        expect(from, DateTime(now.year, now.month, now.day - 6));
        expect(from.hour, 0);
        expect(from.minute, 0);
        expect(from.second, 0);
      });
    }
  });

  group('todaySummary window (health/service.dart)', () {
    for (final entry in anchors.entries) {
      test('${entry.key}: [day-2 00:00, day+1 00:00)', () {
        final now = entry.value;
        final w = todaySummaryWindow(now);
        expect(w.from, DateTime(now.year, now.month, now.day - 2));
        expect(w.from.hour, 0);
        expect(w.to, DateTime(now.year, now.month, now.day + 1));
        expect(w.to.hour, 0);
        expect(w.to.minute, 0);
        expect(w.to.second, 0);
      });
    }
  });

  group('rescheduleDaily roll (notify.dart)', () {
    // 02:30 is inside the spring-forward gap and 01:30 is inside the repeated
    // fall-back hour. Every anchor here is 12:00, so the configured time is
    // always in the past and the roll-to-tomorrow branch is what runs; the
    // today-branch gap case is pinned separately below (audit m3-dst MINOR-3).
    for (final entry in anchors.entries) {
      for (final minutes in [2 * 60 + 30, 1 * 60 + 30, 18 * 60]) {
        test('${entry.key}: coachMinutes $minutes keeps wall-clock time', () {
          final now = entry.value;
          final when = nextDigestAt(now, minutes);
          expect(when.hour, minutes ~/ 60,
              reason: 'rolled delivery must keep the configured hour');
          expect(when.minute, minutes % 60,
              reason: 'rolled delivery must keep the configured minute');
          expect(when.isAfter(now), isTrue,
              reason: 'rolled delivery must be in the future');
          final sameDay = DateTime(
              now.year, now.month, now.day, minutes ~/ 60, minutes % 60);
          expect(when.day, sameDay.isAfter(now) ? now.day : now.day + 1,
              reason: 'a past-or-equal time must roll to tomorrow');
        });
      }
    }

    test('a future time today is not rolled', () {
      final now = DateTime(2026, 3, 8, 12);
      final when = nextDigestAt(now, 18 * 60);
      expect(when, DateTime(2026, 3, 8, 18));
    });

    test('a configured time inside the spring-forward gap normalises forward',
        () {
      // 02:30 does not exist on 2026-03-08, so the today branch must land on
      // the next wall-clock instant that does: 03:30. Pinned because the
      // anchor loop above only ever exercises the roll-to-tomorrow branch
      // (audit m3-dst MINOR-3).
      final now = DateTime(2026, 3, 8, 1);
      final when = nextDigestAt(now, 150);
      expect(when, DateTime(2026, 3, 8, 3, 30));
      expect(when.hour, 3, reason: '02:30 normalises to 03:30 that day');
      expect(when.isAfter(now), isTrue);
    });

    test('a repeated fall-back hour still delivers today', () {
      // 01:30 occurs twice on 2026-11-01. At 01:45 EDT the first occurrence has
      // passed, but 01:30 EST is still ahead, so the digest must not be pushed
      // to tomorrow (pre-existing observation in the M3 gate).
      final now = DateTime(2026, 11, 1, 1, 45);
      expect(now.timeZoneOffset, const Duration(hours: -4),
          reason: 'precondition: 01:45 on fall-back day is still EDT');
      final when = nextDigestAt(now, 90);
      // Compare wall-clock components, not DateTime equality: DateTime
      // equality includes the UTC offset, and DateTime(2026, 11, 1, 1, 30)
      // resolves to the first (EDT) occurrence while the correct answer is the
      // repeated EST one. The offset assertion below pins which occurrence.
      expect(when.year, 2026);
      expect(when.month, 11);
      expect(when.day, 1, reason: 'the repeated 01:30 EST is still today');
      expect(when.hour, 1);
      expect(when.minute, 30);
      expect(when.isAfter(now), isTrue);
      expect(when.timeZoneOffset, const Duration(hours: -5),
          reason: 'the repeated occurrence is EST');
    });
  });

  group('retention compaction cutoff (health/service.dart)', () {
    // 730 days back from an anchor in the same DST phase as the cutoff spans an
    // even number of transitions, so the calendar form and the old Duration
    // form resolve to the same instant. This is a DESTRUCTIVE boundary: it is
    // pinned so a future edit cannot silently change what gets deleted.
    for (final anchor in [
      DateTime(2026, 7, 1, 12, 34, 56, 789, 123),
      DateTime(2026, 1, 15, 12, 34, 56, 789, 123),
      DateTime(2025, 8, 20, 3, 15, 0, 0, 0),
    ]) {
      test('${anchor.toIso8601String()}: identical to the Duration form', () {
        final cutoff = retentionCutoff(anchor, 730);
        final legacy = anchor.subtract(const Duration(days: 730));
        expect(cutoff.millisecondsSinceEpoch, legacy.millisecondsSinceEpoch,
            reason: '730-day cutoff must delete exactly the same rows');
        expect(cutoff.hour, anchor.hour);
        expect(cutoff.minute, anchor.minute);
        expect(cutoff.second, anchor.second);
        expect(cutoff.millisecond, anchor.millisecond);
        expect(cutoff.microsecond, anchor.microsecond);
        // Calendar distance, not day-of-month: 730 days back crosses leap years.
        expect(
            DateTime.utc(anchor.year, anchor.month, anchor.day)
                .difference(DateTime.utc(cutoff.year, cutoff.month, cutoff.day))
                .inDays,
            730);
      });
    }

    test('a phase-mismatched anchor shifts by exactly the offset delta', () {
      // 2024-11-02 is EDT and 2026-11-02 is EST, so the calendar cutoff is one
      // hour earlier than the Duration form (deletes LESS). Pinned explicitly:
      // this is the calendar-correct semantic.
      final anchor = DateTime(2026, 11, 2, 12);
      final cutoff = retentionCutoff(anchor, 730);
      expect(cutoff, DateTime(2024, 11, 2, 12));
      expect(anchor.subtract(const Duration(days: 730)),
          DateTime(2024, 11, 2, 13));
    });

    test('a phase-mismatched anchor can also shift destructively', () {
      // The opposite direction: 2024-03-08 is EST and 2026-03-08 is EDT, so the
      // calendar cutoff is one hour LATER than the Duration form — it deletes
      // one extra hour of records. This is the destructive direction and must
      // be pinned too (audit m3-dst MINOR-2).
      final anchor = DateTime(2026, 3, 8, 12);
      final cutoff = retentionCutoff(anchor, 730);
      expect(cutoff, DateTime(2024, 3, 8, 12));
      expect(cutoff.millisecondsSinceEpoch, 1709917200000);
      expect(
          anchor.subtract(const Duration(days: 730)), DateTime(2024, 3, 8, 11));
      expect(anchor.subtract(const Duration(days: 730)).millisecondsSinceEpoch,
          1709913600000);
      expect(cutoff.isAfter(anchor.subtract(const Duration(days: 730))), isTrue,
          reason: 'the calendar cutoff must delete one extra hour here');
    });
  });

  group('calendarDaysSince (notify.dart)', () {
    test('counts calendar days across the spring-forward boundary', () {
      // 2026-03-08 23:00 -> 2026-03-11 00:30 is 3 calendar days but only 49.5
      // elapsed hours, so the old `difference().inDays` reported 2.
      final now = DateTime(2026, 3, 11, 0, 30);
      final workout = DateTime(2026, 3, 8, 23);
      expect(now.difference(workout).inDays, 2,
          reason: 'pre-fix elapsed-hours truncation under-reports');
      expect(calendarDaysSince(now, workout), 3);
    });

    test('counts calendar days across the fall-back boundary', () {
      final now = DateTime(2026, 11, 4, 0, 30);
      final workout = DateTime(2026, 11, 1, 23);
      expect(now.difference(workout).inDays, 2);
      expect(calendarDaysSince(now, workout), 3);
    });

    test('is exact for same-day and ordinary gaps', () {
      expect(
          calendarDaysSince(
              DateTime(2026, 5, 10, 23), DateTime(2026, 5, 10, 1)),
          0);
      expect(calendarDaysSince(DateTime(2026, 5, 10), DateTime(2026, 5, 3)), 7);
    });
  });
}
