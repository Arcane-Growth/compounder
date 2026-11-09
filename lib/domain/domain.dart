import 'dart:math' as math;

import 'package:intl/intl.dart';

// ---------------------------------------------------------------- fitness

double epley(double weightKg, int reps) {
  if (weightKg < 0) throw ArgumentError('weight must be non-negative');
  if (reps < 1) throw ArgumentError('reps must be at least 1');
  if (reps == 1) return weightKg;
  return weightKg * (1 + reps / 30);
}

double brzycki(double weightKg, int reps) {
  if (weightKg < 0) throw ArgumentError('weight must be non-negative');
  if (reps < 1 || reps > 36) {
    throw ArgumentError('reps must be between 1 and 36');
  }
  if (reps == 1) return weightKg;
  return weightKg * 36 / (37 - reps);
}

/// Best e1RM across [entries]. Sets with zero reps are skipped: the store
/// permits reps = 0 (an untouched placeholder set can be completed), and
/// [epley] rejects reps < 1 (audit B4). Negative weights are skipped too:
/// [epley] rejects them, and a negative weight carries no e1RM signal
/// (review F3 on c3d71cd).
double e1rmMaxOf(List<(double weightKg, int reps)> entries) {
  final valid = entries.where((e) => e.$2 >= 1 && e.$1 >= 0).toList();
  if (valid.isEmpty) return 0;
  return valid.map((e) => epley(e.$1, e.$2)).reduce(math.max);
}

double formatE1rm(double value) => (value * 2).roundToDouble() / 2;

class E1RmPoint {
  final int workoutId;
  final int date;
  final double valueKg;
  const E1RmPoint(this.workoutId, this.date, this.valueKg);
}

/// One row per finished session for an exercise: best working-set e1RM.
List<E1RmPoint> sessionPoints(
    List<({int workoutId, int date, double weightKg, int reps, bool isWarmup})>
        sets) {
  final byWorkout = <int,
      List<
          ({
            int workoutId,
            int date,
            double weightKg,
            int reps,
            bool isWarmup
          })>>{};
  for (final s in sets) {
    if (s.isWarmup) continue;
    // Zero-rep sets carry no e1RM signal (audit B4); dropping them here also
    // keeps a session with only placeholders out of the chart.
    if (s.reps < 1) continue;
    byWorkout.putIfAbsent(s.workoutId, () => []).add(s);
  }
  final points = byWorkout.entries.map((e) {
    final value = formatE1rm(
        e1rmMaxOf(e.value.map((s) => (s.weightKg, s.reps)).toList()));
    final date = e.value.map((s) => s.date).reduce(math.min);
    return E1RmPoint(e.key, date, value);
  }).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  return points;
}

double deltaKg(List<E1RmPoint> points) {
  if (points.isEmpty) return 0;
  return points.last.valueKg - points.first.valueKg;
}

/// The outcome of comparing one set against the user's history.
class PrAssessment {
  /// True when the set beats every prior finished session and every earlier
  /// set logged in the same session.
  final bool isPr;

  /// The e1RM snapshot to persist with the set when [isPr] is true, otherwise
  /// null.
  final double? e1rmKg;

  /// The best e1RM for this exercise across prior finished sessions, or 0 when
  /// the exercise has no history.
  final double previousBestKg;

  const PrAssessment(
      {required this.isPr, this.e1rmKg, required this.previousBestKg});
}

/// Decides whether a set is a personal record.
///
/// [priorBestKg] is the best e1RM for the exercise across every *finished*
/// session before this one (0 when the exercise has no history).
/// [earlierSets] are the sets already logged earlier in the same session.
///
/// Rules (owner-specified):
///  * a set qualifies only when its e1RM is strictly greater than both the
///    prior-session best and every earlier set in this session;
///  * the first-ever set for an exercise establishes the baseline and counts
///    as a PR;
///  * zero-rep sets never qualify (audit B4), and neither do warm-up sets;
///  * negative weights carry no e1RM signal.
///
/// The e1RM is [formatE1rm]ed before comparison so the stored snapshot and the
/// displayed value agree, and so two sets that round to the same half-kilo
/// cannot both claim a PR. A set whose e1RM is 0 (0 kg logged) carries no
/// signal and never flags, matching [e1rmMaxOf]'s treatment of empty input.
PrAssessment assessPr({
  required double weightKg,
  required int reps,
  required bool isWarmup,
  required double priorBestKg,
  required List<(double weightKg, int reps)> earlierSets,
}) {
  final prior = formatE1rm(priorBestKg);
  if (isWarmup || reps < 1 || weightKg < 0) {
    return PrAssessment(isPr: false, previousBestKg: prior);
  }
  final value = formatE1rm(epley(weightKg, reps));
  final sessionBest = formatE1rm(e1rmMaxOf(earlierSets));
  final beatsPrior = prior <= 0 || value > prior;
  if (!beatsPrior || value <= sessionBest) {
    return PrAssessment(isPr: false, previousBestKg: prior);
  }
  return PrAssessment(isPr: true, e1rmKg: value, previousBestKg: prior);
}

class Volume {
  final double totalKg;
  final int sets;
  final int reps;
  const Volume(this.totalKg, this.sets, this.reps);
}

/// Volume, working-set count and rep total for [sets].
///
/// A set with `reps < 1` is skipped entirely: it contributes no volume, no
/// reps, and is **not counted as a working set**. A zero-rep set is a
/// placeholder the user completed without logging reps, so counting it would
/// inflate "Working sets" (lib/ui/summary.dart) and "Sets · reps"
/// (lib/ui/workout.dart) with work that was never done. Warm-up sets are
/// excluded the same way. Pinned by test/coach_addset_clamp_test.dart
/// (review b2b3b4m1 MINOR-1).
///
/// A negative weight is clamped to zero rather than skipped: the set still
/// happened, so it counts, but it cannot subtract from the total. Neither
/// shape is reachable through the UI (it clamps at workout.dart) or the coach
/// tool (it clamps at AddSetTool), but the store accepts any value, so guard
/// here too (review F4 on c3d71cd).
Volume volumeOf(Iterable<({double weightKg, int reps, bool isWarmup})> sets) {
  var total = 0.0, n = 0, reps = 0;
  for (final s in sets) {
    if (s.isWarmup) continue;
    if (s.reps < 1) continue;
    final weightKg = s.weightKg < 0 ? 0.0 : s.weightKg;
    total += weightKg * s.reps;
    n++;
    reps += s.reps;
  }
  return Volume(total, n, reps);
}

// ---------------------------------------------------------------- nutrition

/// Atwater energy factors used by the macro calculator: protein and
/// carbohydrate supply 4 kcal per gram, fat supplies 9 kcal per gram.
const double kcalPerGramProtein = 4;
const double kcalPerGramCarbs = 4;
const double kcalPerGramFat = 9;

/// Calories implied by a macro breakdown, using the Atwater factors above.
///
/// This is the single source of truth for the meal calculator: the manual
/// entry screen and the meal review/edit screen both display this value, so
/// calories can never drift from the macros the user typed.
///
/// Negative and non-finite grams are treated as zero rather than throwing:
/// the store accepts any value, and a text field can hand back `NaN` or
/// `Infinity` through `double.tryParse` ("NaN", "Infinity"). A negative macro
/// cannot subtract energy, so it contributes nothing.
double caloriesFromMacros(double protein, double carbs, double fat) {
  double grams(double value) => value.isFinite && value > 0 ? value : 0;
  return grams(protein) * kcalPerGramProtein +
      grams(carbs) * kcalPerGramCarbs +
      grams(fat) * kcalPerGramFat;
}

/// Parses a macro gram value typed into a text field.
///
/// Empty, non-numeric ("abc"), negative and non-finite input all read as 0,
/// so the calculator never throws on a half-typed field.
double parseMacroGrams(String text) {
  final value = double.tryParse(text.trim());
  if (value == null || !value.isFinite || value < 0) return 0;
  return value;
}

// ---------------------------------------------------------------- units

enum WeightUnit {
  kg('kg'),
  lb('lb');

  const WeightUnit(this.label);
  final String label;

  static WeightUnit from(String? name) => WeightUnit.values
      .firstWhere((u) => u.name == name, orElse: () => WeightUnit.kg);
}

const double kgPerLb = 2.2046226218;

double fromKg(double weightKg, WeightUnit unit) =>
    ((unit == WeightUnit.kg ? weightKg : weightKg * kgPerLb) * 10)
        .roundToDouble() /
    10;

double toKg(double weight, WeightUnit unit) =>
    ((unit == WeightUnit.kg ? weight : weight / kgPerLb) * 10).roundToDouble() /
    10;

/// Parses a weight typed in [unit] and returns the value to store in kg.
/// Unlike [toKg], this keeps full precision so pound values round-trip through
/// storage and display without visibly drifting.
double? parseWeightKg(String text, WeightUnit unit) {
  final value = double.tryParse(text.trim());
  if (value == null) return null;
  return unit == WeightUnit.kg ? value : value / kgPerLb;
}

String trimZero(double value) {
  final rounded = (value * 10).roundToDouble() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// Whole numbers with thousands separators: 12345 -> "12,345".
///
/// Fractions are truncated, not rounded (82.7 -> "82"), because these are
/// counters and step totals where showing "83" would overstate the number.
/// Grouping comes from intl with an explicit en_US pattern so the output does
/// not change with device locale.
final NumberFormat _countFormat = NumberFormat.decimalPattern('en_US')
  ..maximumFractionDigits = 0;

String formatCount(num value) => _countFormat.format(value.truncate());

// ---------------------------------------------------------------- wealth

class Wealth {
  /// Net worth = assets minus liabilities (debt balances are subtracted whatever their sign).
  static double netWorth(List<(double balance, bool isLiability)> entries) =>
      entries.map((e) => e.$2 ? -e.$1.abs() : e.$1).fold(0.0, (a, b) => a + b);

  static double totalAssets(List<(double balance, bool isLiability)> entries) =>
      entries.where((e) => !e.$2).map((e) => e.$1).fold(0.0, (a, b) => a + b);

  static double totalLiabilities(
          List<(double balance, bool isLiability)> entries) =>
      entries
          .where((e) => e.$2)
          .map((e) => e.$1.abs())
          .fold(0.0, (a, b) => a + b);

  static String formatAmount(double value) {
    final negative = value < 0;
    final parts = value.abs().toStringAsFixed(2).split('.');
    final digits = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return '${negative ? '-' : ''}${buf.toString()}.${parts[1]}';
  }
}

class NetWorthPoint {
  final int date;
  final double value;
  const NetWorthPoint(this.date, this.value);
}

/// Builds a net-worth series from account balance snapshots, carrying each
/// account's most recent balance forward and subtracting liabilities.
///
/// The sort is a deterministic total order on `(takenAt, accountId, balance)`.
/// Sorting on `takenAt` alone was not deterministic: Dart's `List.sort` is not
/// stable, so snapshots sharing a timestamp could be folded in any order and
/// the last one visited won the month (review F2 on c3d71cd). Entries that tie
/// on all three keys are indistinguishable to the fold, so the result is
/// reproducible regardless of input order.
List<NetWorthPoint> netWorthSeries(
    List<({int accountId, double balance, bool isLiability, int takenAt})>
        snapshots) {
  final sorted = [...snapshots]..sort((a, b) {
      final byTime = a.takenAt.compareTo(b.takenAt);
      if (byTime != 0) return byTime;
      final byAccount = a.accountId.compareTo(b.accountId);
      if (byAccount != 0) return byAccount;
      return a.balance.compareTo(b.balance);
    });
  final latest = <int, (double, bool)>{};
  final points = <NetWorthPoint>[];
  for (final snapshot in sorted) {
    latest[snapshot.accountId] = (snapshot.balance, snapshot.isLiability);
    points.add(NetWorthPoint(
      snapshot.takenAt,
      Wealth.netWorth(latest.values.map((e) => (e.$1, e.$2)).toList()),
    ));
  }
  return points;
}

// ---------------------------------------------------------------- finance

class Finance {
  /// Value of [principal] plus a fixed [monthlyContribution] after [years]
  /// at [annualPercent] percent, compounding monthly (contributions at month end).
  static double futureValue({
    required double principal,
    double monthlyContribution = 0,
    required double annualPercent,
    required int years,
  }) {
    if (years < 0) throw ArgumentError('years must be >= 0');
    final r = annualPercent / 100 / 12;
    final n = years * 12;
    final growth = math.pow(1 + r, n).toDouble();
    final contributed = r == 0
        ? monthlyContribution * n
        : monthlyContribution * (growth - 1) / r;
    return principal * growth + contributed;
  }

  /// Months to pay off [principal] at [annualPercent] with a fixed
  /// [monthlyPayment]; null when the payment never beats the interest.
  static int? payoffMonths({
    required double principal,
    required double monthlyPayment,
    required double annualPercent,
  }) {
    if (principal <= 0) return 0;
    if (monthlyPayment <= 0) return null;
    final r = annualPercent / 100 / 12;
    if (r == 0) return (principal / monthlyPayment).ceil();
    if (monthlyPayment <= principal * r) return null;
    final months =
        -math.log(1 - principal * r / monthlyPayment) / math.log(1 + r);
    return months.ceil();
  }

  /// Extra interest avoided by paying off [principal] early over [years]
  /// versus letting the same cash grow at [annualPercent] (negative = better
  /// to invest when returns beat the debt rate).
  static double upsideVsInvest({
    required double principal,
    required double debtPercent,
    required double investPercent,
    required int years,
  }) {
    final owed = futureValue(
        principal: principal, annualPercent: debtPercent, years: years);
    final grown = futureValue(
        principal: principal, annualPercent: investPercent, years: years);
    return grown - owed;
  }
}

// ---------------------------------------------------------------- mind

/// Previous calendar day at local midnight.
///
/// Calendar arithmetic, not `Duration(days: 1)`: a 24-hour subtraction from
/// midnight lands on 23:00 (or 01:00) across a DST boundary, so the result is
/// not a day key and day-walking loops miss a day.
DateTime previousDayKey(DateTime day) =>
    DateTime(day.year, day.month, day.day - 1);

/// Next calendar day at local midnight. Same calendar-arithmetic rule as
/// [previousDayKey]: a 24-hour addition lands on 01:00 across a spring-forward
/// boundary, so it is not a day key.
DateTime nextDayKey(DateTime day) => DateTime(day.year, day.month, day.day + 1);

/// Local instant seven calendar days before [now], preserving the time of day.
///
/// Calendar arithmetic, not `Duration(days: 7)`: a 168-hour subtraction lands
/// on 23:00/01:00 across a DST boundary and would shift the "last 7 days" mood
/// window by an hour (audit m3-dst MINOR-4).
DateTime mindWeekStart(DateTime now) => DateTime(now.year, now.month,
    now.day - 7, now.hour, now.minute, now.second, now.millisecond,
    now.microsecond);

class Mind {
  static double? averageMood(List<int> moods) =>
      moods.isEmpty ? null : moods.reduce((a, b) => a + b) / moods.length;

  /// Consecutive days (ending at [today]) with at least one mood check-in.
  static int moodStreak(List<DateTime> checkins, {DateTime? today}) {
    final dayKey = today ?? DateTime.now();
    final days = checkins.map((d) => DateTime(d.year, d.month, d.day)).toSet();
    if (!days.contains(DateTime(dayKey.year, dayKey.month, dayKey.day))) {
      return 0;
    }
    var streak = 0;
    var cursor = DateTime(dayKey.year, dayKey.month, dayKey.day);
    while (days.contains(cursor)) {
      streak++;
      cursor = previousDayKey(cursor);
    }
    return streak;
  }

  static int minutesBetween(List<(DateTime time, int minutes)> sessions,
          DateTime start, DateTime end) =>
      sessions
          .where((s) => !s.$1.isBefore(start) && s.$1.isBefore(end))
          .map((s) => s.$2)
          .fold(0, (a, b) => a + b);
}

// ---------------------------------------------------------------- nutrition

/// Local midnight for [day]: the inclusive lower bound of that calendar day.
DateTime localMidnight(DateTime day) => DateTime(day.year, day.month, day.day);

/// Monday of the week containing [day], at local midnight.
///
/// Calendar arithmetic only. `DateTime(y, m, d - n)` stays on a day boundary
/// across a DST transition, where `Duration(days: n)` lands on 23:00 or 01:00
/// and would silently widen or truncate the week.
DateTime weekStartFor(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));

/// The nutrition fields the aggregates below need, without importing the
/// persistence model into the domain layer.
///
/// `Meal` (lib/data/models.dart) implements this interface, so the dependency
/// points data → domain, never domain → data (review nutrition MINOR-6).
abstract interface class MealNutrition {
  int get timestamp;
  double get calories;
  double get protein;
  double get carbs;
  double get fat;
}

/// Meals inside the half-open local-day window
/// `[localMidnight(day), localMidnight(day + 1))`.
///
/// The exclusive upper bound is what keeps the next day's 00:00 — and any
/// future-dated row — out of the day's totals. The lower bound is inclusive,
/// so a meal logged at exactly 00:00 belongs to that day.
///
/// Generic over [MealNutrition] so a caller keeps its concrete row type
/// (`List<Meal>` in, `List<Meal>` out) while the domain stays model-free.
List<T> mealsOnDay<T extends MealNutrition>(Iterable<T> meals, DateTime day) {
  final start = localMidnight(day).millisecondsSinceEpoch;
  final end = nextDayKey(day).millisecondsSinceEpoch;
  return meals.where((m) => m.timestamp >= start && m.timestamp < end).toList();
}

/// Calories and macros summed over one local day.
class NutritionTotals {
  final double calories, protein, carbs, fat;
  const NutritionTotals({
    this.calories = 0,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
  });

  NutritionTotals operator +(NutritionTotals other) => NutritionTotals(
        calories: calories + other.calories,
        protein: protein + other.protein,
        carbs: carbs + other.carbs,
        fat: fat + other.fat,
      );
}

/// Daily targets the weekly tracker compares against. Mirrors the persisted
/// `MacroGoals` (lib/data/store.dart) without importing the store into the
/// domain layer.
class NutritionGoals {
  final double calories, protein, carbs, fat;
  const NutritionGoals({
    this.calories = 2000,
    this.protein = 150,
    this.carbs = 250,
    this.fat = 70,
  });
}

/// The metric the weekly tracker is currently charting.
enum NutritionMetric {
  calories('Calories', 'kcal'),
  protein('Protein', 'g'),
  carbs('Carbs', 'g'),
  fat('Fat', 'g');

  const NutritionMetric(this.label, this.unit);
  final String label;
  final String unit;

  double valueOf(NutritionTotals totals) => switch (this) {
        NutritionMetric.calories => totals.calories,
        NutritionMetric.protein => totals.protein,
        NutritionMetric.carbs => totals.carbs,
        NutritionMetric.fat => totals.fat,
      };

  double goalOf(NutritionGoals goals) => switch (this) {
        NutritionMetric.calories => goals.calories,
        NutritionMetric.protein => goals.protein,
        NutritionMetric.carbs => goals.carbs,
        NutritionMetric.fat => goals.fat,
      };
}

/// One day of a week: its totals, whether anything was logged, and the signed
/// distance from the goal for every metric (positive = over).
class NutritionDay {
  final DateTime day;
  final NutritionTotals totals;
  final bool logged;
  final Map<NutritionMetric, double> deltas;

  const NutritionDay({
    required this.day,
    required this.totals,
    required this.logged,
    required this.deltas,
  });

  double deltaFor(NutritionMetric metric) => deltas[metric] ?? 0;

  bool isOver(NutritionMetric metric) => deltaFor(metric) > 0;
}

/// Calories and macros summed over the local day [day].
NutritionTotals nutritionTotalsForDay(
        Iterable<MealNutrition> meals, DateTime day) =>
    _totalsOf(mealsOnDay(meals, day));

NutritionTotals _totalsOf(Iterable<MealNutrition> meals) {
  var totals = const NutritionTotals();
  for (final meal in meals) {
    totals = totals +
        NutritionTotals(
          calories: meal.calories,
          protein: meal.protein,
          carbs: meal.carbs,
          fat: meal.fat,
        );
  }
  return totals;
}

/// Totals and goal deltas for a single local day.
NutritionDay nutritionDayFor(
    Iterable<MealNutrition> meals, DateTime day, NutritionGoals goals) {
  final inDay = mealsOnDay(meals, day);
  final totals = _totalsOf(inDay);
  return NutritionDay(
    day: localMidnight(day),
    totals: totals,
    logged: inDay.isNotEmpty,
    deltas: {
      for (final metric in NutritionMetric.values)
        metric: metric.valueOf(totals) - metric.goalOf(goals),
    },
  );
}

/// Seven consecutive days starting at the Monday of [weekStart]'s week.
///
/// Each bucket is built with calendar arithmetic, so a week containing a DST
/// transition still yields seven real days with correct local boundaries.
List<NutritionDay> weeklyNutrition(
    Iterable<MealNutrition> meals, DateTime weekStart, NutritionGoals goals) {
  final monday = weekStartFor(weekStart);
  return [
    for (var i = 0; i < 7; i++)
      nutritionDayFor(
          meals, DateTime(monday.year, monday.month, monday.day + i), goals),
  ];
}

/// How many days of a week landed over, under or exactly on the goal for
/// [metric], and how many had nothing logged.
class NutritionWeekSummary {
  final int over, under, onTarget, unlogged;
  const NutritionWeekSummary({
    required this.over,
    required this.under,
    required this.onTarget,
    required this.unlogged,
  });
}

NutritionWeekSummary summarizeWeek(
    List<NutritionDay> days, NutritionMetric metric) {
  var over = 0, under = 0, onTarget = 0, unlogged = 0;
  for (final day in days) {
    if (!day.logged) {
      unlogged++;
      continue;
    }
    final delta = day.deltaFor(metric);
    if (delta > 0) {
      over++;
    } else if (delta < 0) {
      under++;
    } else {
      onTarget++;
    }
  }
  return NutritionWeekSummary(
      over: over, under: under, onTarget: onTarget, unlogged: unlogged);
}
