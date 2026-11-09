import 'habits.dart';

/// Bit for "a workout was logged that day".
const int pillarWorkout = 1;

/// Bit for "a meal was logged that day".
const int pillarNutrition = 2;

/// Bit for "mood, meditation or a thought record was logged that day".
const int pillarMind = 4;

/// Bit for "a habit was checked off that day".
const int pillarHabits = 8;

/// Bit for "the day was planned" — at least one block on the day's plan.
const int pillarPlan = 16;

/// Every pillar present: a "perfect" day.
const int allPillarsMask =
    pillarWorkout | pillarNutrition | pillarMind | pillarHabits | pillarPlan;

/// One local calendar day's logging activity across the app's five pillars.
///
/// [day] is a local `YYYY-MM-DD` key, the same convention
/// `habit_completions.day` uses (see [habitDayKey]): a pillar is "done on
/// 2026-03-08", never "done at 23:00 UTC", so a timestamp never shifts a day
/// across a timezone or DST boundary.
class PillarDay {
  final String day;
  final int workoutCount;
  final int nutritionCount;
  final int mindCount;
  final int habitCount;

  /// Number of plan blocks on the day. A day counts as planned when this is
  /// above zero; finishing the blocks is not required.
  final int planCount;

  const PillarDay({
    required this.day,
    this.workoutCount = 0,
    this.nutritionCount = 0,
    this.mindCount = 0,
    this.habitCount = 0,
    this.planCount = 0,
  });

  /// Bitmask of the pillars logged that day (see [pillarWorkout] etc.).
  int get mask =>
      (workoutCount > 0 ? pillarWorkout : 0) |
      (nutritionCount > 0 ? pillarNutrition : 0) |
      (mindCount > 0 ? pillarMind : 0) |
      (habitCount > 0 ? pillarHabits : 0) |
      (planCount > 0 ? pillarPlan : 0);

  /// Number of distinct pillars logged, 0-5.
  int get pillarCount =>
      (workoutCount > 0 ? 1 : 0) +
      (nutritionCount > 0 ? 1 : 0) +
      (mindCount > 0 ? 1 : 0) +
      (habitCount > 0 ? 1 : 0) +
      (planCount > 0 ? 1 : 0);

  /// Heatmap intensity: exactly the number of distinct pillars, 0-5.
  int get intensity => pillarCount;

  /// True when all five pillars were logged that day.
  bool get perfect => mask == allPillarsMask;

  bool hasPillar(int pillar) => (mask & pillar) != 0;

  /// Row count for [pillar] (0 for an unknown bit).
  int countFor(int pillar) => switch (pillar) {
        pillarWorkout => workoutCount,
        pillarNutrition => nutritionCount,
        pillarMind => mindCount,
        pillarHabits => habitCount,
        pillarPlan => planCount,
        _ => 0,
      };
}

/// The local day key for [day], discarding any time component.
///
/// Deliberately an alias for [habitDayKey]: the activity heatmap and the habit
/// tracker must agree on what "a day" means, and one shared implementation is
/// the only way to guarantee that. The separate name documents the domain
/// boundary; it is not an independent implementation.
String localDayKey(DateTime day) => habitDayKey(day);

/// The day key immediately before [key], or null when [key] is malformed.
///
/// Calendar arithmetic (`DateTime(y, m, d - 1)`), never `Duration(days: 1)`:
/// a 24-hour step lands on 23:00 or 01:00 across a DST boundary and would
/// produce the wrong day key.
String? previousDayKey(String key) {
  final day = parseHabitDay(key);
  if (day == null) return null;
  return habitDayKey(DateTime(day.year, day.month, day.day - 1));
}

/// Consecutive days ending today (or yesterday, when today is not logged yet)
/// on which at least one pillar was logged.
///
/// A day counts when [days] holds an entry with `pillarCount > 0`. The streak
/// is measured up to yesterday when today is still empty, so an unfinished day
/// does not zero a streak the user has not broken yet. A gap ends the walk.
int currentStreak(Map<String, PillarDay> days, DateTime today) {
  var key = localDayKey(today);
  var streak = 0;
  final todayEntry = days[key];
  if (todayEntry == null || todayEntry.pillarCount == 0) {
    final yesterday = previousDayKey(key);
    if (yesterday == null) return 0;
    key = yesterday;
  }
  // Bound the walk by the number of known days: a corrupt map cannot spin
  // forever, and a streak cannot be longer than the history it is built from.
  for (var i = 0; i <= days.length; i++) {
    final entry = days[key];
    if (entry == null || entry.pillarCount == 0) break;
    streak++;
    final previous = previousDayKey(key);
    if (previous == null) break;
    key = previous;
  }
  return streak;
}

/// The longest run of consecutive days with at least one pillar logged.
int longestStreak(Map<String, PillarDay> days) {
  final keys = days.entries
      .where((e) => e.value.pillarCount > 0)
      .map((e) => e.key)
      .toList()
    ..sort();
  var best = 0;
  var run = 0;
  String? previous;
  for (final key in keys) {
    if (previous != null && previousDayKey(key) == previous) {
      run++;
    } else {
      run = 1;
    }
    if (run > best) best = run;
    previous = key;
  }
  return best;
}

/// Number of days in [month] (1-12) of [year] on which all five pillars were
/// logged.
int perfectDaysInMonth(Map<String, PillarDay> days, int year, int month) {
  final prefix = '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-';
  return days.values
      .where((d) => d.day.startsWith(prefix) && d.perfect)
      .length;
}

/// The pillars logged on [day], as a stable list of bit values.
const List<int> allPillars = [
  pillarWorkout,
  pillarNutrition,
  pillarMind,
  pillarHabits,
  pillarPlan,
];

/// Human label for a pillar bit.
String pillarLabel(int pillar) => switch (pillar) {
      pillarWorkout => 'Workout',
      pillarNutrition => 'Nutrition',
      pillarMind => 'Mood & Mind',
      pillarHabits => 'Habits',
      pillarPlan => 'Day plan',
      _ => 'Unknown',
    };
