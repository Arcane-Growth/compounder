import 'package:compounder/data/models.dart';
import 'package:compounder/domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feature 2 DST guard: the weekly tracker must build seven real local days
/// with calendar arithmetic, never `Duration(days: 1)`.
///
/// A 24-hour step from local midnight lands on 23:00 (spring-forward) or 01:00
/// (fall-back), so a Duration-based week would truncate or widen a day bucket.
/// These helpers build ambient-zone `DateTime`s, so the defect is only visible
/// when the process zone has a DST transition. [setUpAll] fails loudly instead
/// of passing vacuously when it does not: run with TZ=America/New_York.
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

  Meal mealAt(DateTime at, {double calories = 0}) => Meal(
        id: 0,
        timestamp: at.millisecondsSinceEpoch,
        imagePath: '',
        dish: 'Meal',
        calories: calories,
        protein: 0,
        carbs: 0,
        fat: 0,
      );

  test('a week containing the 2026-03-08 spring-forward yields 7 day buckets',
      () {
    final week = weeklyNutrition(
        const <Meal>[], DateTime(2026, 3, 4), const NutritionGoals());

    expect(week, hasLength(7));
    expect(week.map((d) => d.day), [
      for (var i = 0; i < 7; i++) DateTime(2026, 3, 2 + i),
    ]);
    for (final day in week) {
      expect(day.day.hour, 0, reason: 'every bucket starts at local midnight');
      expect(day.day.minute, 0);
      expect(day.day.second, 0);
      expect(day.day.millisecond, 0);
    }

    // The transition day really is 23 hours long in this zone, and the day
    // after it is 24: that is what makes a Duration step wrong.
    expect(
        nextDayKey(DateTime(2026, 3, 8))
            .difference(localMidnight(DateTime(2026, 3, 8)))
            .inHours,
        23);
    expect(
        nextDayKey(DateTime(2026, 3, 9))
            .difference(localMidnight(DateTime(2026, 3, 9)))
            .inHours,
        24);
    expect(
        localMidnight(DateTime(2026, 3, 9))
            .subtract(const Duration(days: 1))
            .hour,
        23,
        reason: 'the Duration-based step this guard rejects');
  });

  test('meals on the spring-forward day bucket by local day, not 24h offsets',
      () {
    final meals = [
      mealAt(DateTime(2026, 3, 8, 0, 0), calories: 100),
      mealAt(DateTime(2026, 3, 8, 23, 30), calories: 200),
      mealAt(DateTime(2026, 3, 9, 0, 0), calories: 400),
    ];
    final week =
        weeklyNutrition(meals, DateTime(2026, 3, 2), const NutritionGoals());

    expect(week[6].day, DateTime(2026, 3, 8));
    expect(week[6].totals.calories, 300,
        reason: 'both meals on the 23-hour day are in its window');
    expect(week[6].logged, isTrue);
    expect(week[6].deltaFor(NutritionMetric.calories), 300 - 2000);
  });

  test('weekStartFor stays on local midnight across a DST boundary', () {
    // Contract: the week anchor is Monday at local midnight, on both sides of
    // a transition. (A Duration subtraction happens to be safe in this zone
    // because US transitions fire at 02:00 Sunday, after that day's midnight;
    // the Monday anchor is the part a regression can actually break.)
    expect(weekStartFor(DateTime(2026, 3, 10)), DateTime(2026, 3, 9));
    expect(weekStartFor(DateTime(2026, 3, 10)).hour, 0);
    // 2026-11-03 is the Tuesday after the fall-back.
    expect(weekStartFor(DateTime(2026, 11, 3)), DateTime(2026, 11, 2));
    expect(weekStartFor(DateTime(2026, 11, 3)).hour, 0);
  });

  test('a week containing the 2026-11-01 fall-back yields 7 day buckets', () {
    final week = weeklyNutrition(
        const <Meal>[], DateTime(2026, 10, 28), const NutritionGoals());

    expect(week, hasLength(7));
    expect(week.map((d) => d.day), [
      for (var i = 0; i < 7; i++) DateTime(2026, 10, 26 + i),
    ]);
    expect(
        nextDayKey(DateTime(2026, 11, 1))
            .difference(localMidnight(DateTime(2026, 11, 1)))
            .inHours,
        25,
        reason: 'the fall-back day is 25 hours long');
  });
}
