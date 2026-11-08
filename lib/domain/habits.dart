import '../data/models.dart';

/// How often a habit is meant to be done. The target count is expressed in
/// days per period: 1/day, 3/week, 2/month.
enum HabitCadence {
  daily,
  weekly,
  monthly;

  /// Parses a cadence from stored text or model-supplied JSON. Returns null for
  /// anything unrecognised so callers can report a JSON error instead of
  /// throwing (coach tools must never throw on bad input).
  static HabitCadence? parse(Object? raw) {
    if (raw is! String) return null;
    switch (raw.trim().toLowerCase()) {
      case 'daily':
      case 'day':
        return HabitCadence.daily;
      case 'weekly':
      case 'week':
        return HabitCadence.weekly;
      case 'monthly':
      case 'month':
        return HabitCadence.monthly;
    }
    return null;
  }

  /// The word used in progress labels ("today", "this week", "this month").
  String get periodWord => switch (this) {
        HabitCadence.daily => 'today',
        HabitCadence.weekly => 'this week',
        HabitCadence.monthly => 'this month',
      };
}

/// A local calendar day. Completions are keyed by this string, never by an
/// epoch timestamp: a habit is "done on 2026-03-08", not "done at 23:00 UTC".
String habitDayKey(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Strict `YYYY-MM-DD` parser for coach-supplied dates.
///
/// Returns null for a malformed string, a non-string value, or a date that does
/// not exist (2026-02-30). `DateTime.tryParse` alone accepts `2026-02-30` and
/// rolls it to March 2, which would silently log a completion on the wrong day.
DateTime? parseHabitDay(Object? raw) {
  if (raw is! String) return null;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final parsed = DateTime(year, month, day);
  // DateTime rolls invalid days forward (Feb 30 -> Mar 2), so round-trip the
  // components and reject anything that moved.
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

/// One cadence period, as local calendar day keys. [end] is exclusive.
class HabitPeriod {
  final DateTime start;
  final DateTime end;
  const HabitPeriod(this.start, this.end);

  bool contains(DateTime day) {
    final key = habitDayKey(day);
    return key.compareTo(habitDayKey(start)) >= 0 &&
        key.compareTo(habitDayKey(end)) < 0;
  }
}

/// The period containing [day] for [cadence].
///
/// Every boundary is built with calendar arithmetic (`DateTime(y, m, d + n)`),
/// never `Duration(days: n)`: a 24-hour step lands on 23:00 or 01:00 across a
/// DST boundary, so it is not a day key and a period walk would skip or repeat
/// a day. Weeks start on Monday (ISO 8601); months start on the 1st.
HabitPeriod habitPeriodFor(HabitCadence cadence, DateTime day) {
  final key = DateTime(day.year, day.month, day.day);
  switch (cadence) {
    case HabitCadence.daily:
      return HabitPeriod(key, DateTime(key.year, key.month, key.day + 1));
    case HabitCadence.weekly:
      // weekday: Monday = 1 .. Sunday = 7.
      final start = DateTime(key.year, key.month, key.day - (key.weekday - 1));
      return HabitPeriod(
          start, DateTime(start.year, start.month, start.day + 7));
    case HabitCadence.monthly:
      final start = DateTime(key.year, key.month, 1);
      return HabitPeriod(start, DateTime(start.year, start.month + 1, 1));
  }
}

/// The period immediately before [period], for streak walking.
HabitPeriod previousHabitPeriod(HabitCadence cadence, HabitPeriod period) =>
    habitPeriodFor(cadence,
        DateTime(period.start.year, period.start.month, period.start.day - 1));

/// Progress for one habit in the period containing [day].
class HabitProgress {
  final int completedDays;
  final int target;
  final int streak;

  const HabitProgress({
    required this.completedDays,
    required this.target,
    required this.streak,
  });

  bool get met => completedDays >= target;
  double get fraction => target <= 0 ? 0 : (completedDays / target).clamp(0, 1);
}

/// Counts completed days inside [period] from [completions].
///
/// A completion row with `count <= 0` does not count: the store writes 1, but a
/// hand-edited or imported row could carry 0, and a zero must not satisfy a
/// target.
int habitCompletedDays(List<HabitCompletion> completions, HabitPeriod period) {
  final days = <String>{};
  for (final c in completions) {
    if (c.count <= 0) continue;
    final day = parseHabitDay(c.day);
    if (day == null) continue;
    if (period.contains(day)) days.add(c.day);
  }
  return days.length;
}

/// Consecutive periods (ending with the period containing [today]) in which the
/// habit met its target.
///
/// The current period only counts when it is already met; otherwise the streak
/// is measured up to the previous period, so an unfinished week does not zero a
/// streak the user has not broken yet.
int habitStreak(
  HabitCadence cadence,
  int target,
  List<HabitCompletion> completions, {
  required DateTime today,
}) {
  if (target <= 0) return 0;
  var period = habitPeriodFor(cadence, today);
  var streak = 0;
  if (habitCompletedDays(completions, period) < target) {
    period = previousHabitPeriod(cadence, period);
  }
  // Bound the walk: a habit cannot have a streak longer than its own history,
  // and an unbounded loop would spin forever on a corrupt completion set.
  final oldest = completions.isEmpty
      ? null
      : completions
          .map((c) => parseHabitDay(c.day))
          .whereType<DateTime>()
          .reduce((a, b) => a.isBefore(b) ? a : b);
  while (habitCompletedDays(completions, period) >= target) {
    streak++;
    if (oldest != null && period.start.isBefore(oldest)) break;
    period = previousHabitPeriod(cadence, period);
  }
  return streak;
}

/// Full progress snapshot for [habit] on [today].
HabitProgress habitProgress(
  Habit habit,
  List<HabitCompletion> completions, {
  required DateTime today,
}) {
  final cadence = HabitCadence.parse(habit.cadence) ?? HabitCadence.daily;
  final period = habitPeriodFor(cadence, today);
  return HabitProgress(
    completedDays: habitCompletedDays(completions, period),
    target: habit.target,
    streak: habitStreak(cadence, habit.target, completions, today: today),
  );
}
