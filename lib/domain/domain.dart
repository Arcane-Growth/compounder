import 'dart:math' as math;

// ---------------------------------------------------------------- fitness

double epley(double weightKg, int reps) {
  if (weightKg < 0) throw ArgumentError('weight must be non-negative');
  if (reps < 1) throw ArgumentError('reps must be at least 1');
  if (reps == 1) return weightKg;
  return weightKg * (1 + reps / 30);
}

double brzycki(double weightKg, int reps) {
  if (weightKg < 0) throw ArgumentError('weight must be non-negative');
  if (reps < 1 || reps > 36) throw ArgumentError('reps must be between 1 and 36');
  if (reps == 1) return weightKg;
  return weightKg * 36 / (37 - reps);
}

double e1rmMaxOf(List<(double weightKg, int reps)> entries) {
  if (entries.isEmpty) return 0;
  return entries.map((e) => epley(e.$1, e.$2)).reduce(math.max);
}

double formatE1rm(double value) => (value * 2).roundToDouble() / 2;

class E1RmPoint {
  final int workoutId;
  final int date;
  final double valueKg;
  const E1RmPoint(this.workoutId, this.date, this.valueKg);
}

/// One row per finished session for an exercise: best working-set e1RM.
List<E1RmPoint> sessionPoints(List<({int workoutId, int date, double weightKg, int reps, bool isWarmup})> sets) {
  final byWorkout = <int, List<({int workoutId, int date, double weightKg, int reps, bool isWarmup})>>{};
  for (final s in sets) {
    if (s.isWarmup) continue;
    byWorkout.putIfAbsent(s.workoutId, () => []).add(s);
  }
  final points = byWorkout.entries.map((e) {
    final value = formatE1rm(e1rmMaxOf(e.value.map((s) => (s.weightKg, s.reps)).toList()));
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

Volume volumeOf(Iterable<({double weightKg, int reps, bool isWarmup})> sets) {
  var total = 0.0, n = 0, reps = 0;
  for (final s in sets) {
    if (s.isWarmup) continue;
    total += s.weightKg * s.reps;
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

  static WeightUnit from(String? name) =>
      WeightUnit.values.firstWhere((u) => u.name == name, orElse: () => WeightUnit.kg);
}

const double kgPerLb = 2.2046226218;

double fromKg(double weightKg, WeightUnit unit) =>
    ((unit == WeightUnit.kg ? weightKg : weightKg * kgPerLb) * 10).roundToDouble() / 10;

double toKg(double weight, WeightUnit unit) =>
    ((unit == WeightUnit.kg ? weight : weight / kgPerLb) * 10).roundToDouble() / 10;

String trimZero(double value) {
  final rounded = (value * 10).roundToDouble() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

// ---------------------------------------------------------------- wealth

class Wealth {
  /// Net worth = assets minus liabilities (debt balances are subtracted whatever their sign).
  static double netWorth(List<(double balance, bool isLiability)> entries) => entries
      .map((e) => e.$2 ? -e.$1.abs() : e.$1)
      .fold(0.0, (a, b) => a + b);

  static double totalAssets(List<(double balance, bool isLiability)> entries) =>
      entries.where((e) => !e.$2).map((e) => e.$1).fold(0.0, (a, b) => a + b);

  static double totalLiabilities(List<(double balance, bool isLiability)> entries) =>
      entries.where((e) => e.$2).map((e) => e.$1.abs()).fold(0.0, (a, b) => a + b);

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

// ---------------------------------------------------------------- mind

class Mind {
  static double? averageMood(List<int> moods) => moods.isEmpty
      ? null
      : moods.reduce((a, b) => a + b) / moods.length;

  /// Consecutive days (ending at [today]) with at least one mood check-in.
  static int moodStreak(List<DateTime> checkins, {DateTime? today}) {
    final dayKey = today ?? DateTime.now();
    final days = checkins.map((d) => DateTime(d.year, d.month, d.day)).toSet();
    if (!days.contains(DateTime(dayKey.year, dayKey.month, dayKey.day))) return 0;
    var streak = 0;
    var cursor = DateTime(dayKey.year, dayKey.month, dayKey.day);
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  static int minutesBetween(List<(DateTime time, int minutes)> sessions, DateTime start, DateTime end) =>
      sessions
          .where((s) => !s.$1.isBefore(start) && s.$1.isBefore(end))
          .map((s) => s.$2)
          .fold(0, (a, b) => a + b);
}
