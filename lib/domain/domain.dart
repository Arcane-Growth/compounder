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
