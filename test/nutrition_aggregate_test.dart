import 'package:compounder/data/models.dart';
import 'package:compounder/domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feature 2: per-date nutrition browsing and the weekly tracker.
///
/// These are the measured-value guards for the pure aggregate the Macros tab
/// renders: half-open local-day windows (00:00 in, next-day 00:00 out), no
/// future rows in a day's totals, and exact per-day over/under deltas for a
/// Mon–Sun week.
Meal mealAt(DateTime at,
        {double calories = 0,
        double protein = 0,
        double carbs = 0,
        double fat = 0,
        String dish = 'Meal'}) =>
    Meal(
      id: 0,
      timestamp: at.millisecondsSinceEpoch,
      imagePath: '',
      dish: dish,
      calories: calories,
      protein: protein,
      carbs: carbs,
      fat: fat,
    );

void main() {
  group('day window boundaries', () {
    test('meals at 00:00 and 23:59 local belong to that day', () {
      final meals = [
        mealAt(DateTime(2026, 5, 11, 0, 0), calories: 100, protein: 10),
        mealAt(DateTime(2026, 5, 11, 23, 59), calories: 200, protein: 20),
      ];
      final totals = nutritionTotalsForDay(meals, DateTime(2026, 5, 11));
      expect(totals.calories, 300);
      expect(totals.protein, 30);
      expect(mealsOnDay(meals, DateTime(2026, 5, 11)), hasLength(2));
    });

    test("the next day's 00:00 is excluded", () {
      final meals = [
        mealAt(DateTime(2026, 5, 11, 23, 59), calories: 200),
        mealAt(DateTime(2026, 5, 12, 0, 0), calories: 400),
      ];
      final totals = nutritionTotalsForDay(meals, DateTime(2026, 5, 11));
      expect(totals.calories, 200,
          reason: 'the window is half-open: [00:00, next 00:00)');
      expect(mealsOnDay(meals, DateTime(2026, 5, 12)).single.calories, 400);
    });

    test('a future-dated meal is excluded from today', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final meals = [
        mealAt(DateTime(today.year, today.month, today.day, 12), calories: 500),
        mealAt(DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9),
            calories: 900),
      ];
      final totals = nutritionTotalsForDay(meals, today);
      expect(totals.calories, 500,
          reason: 'a future row must not leak into today');
      expect(mealsOnDay(meals, today).single.calories, 500);
    });

    test('a meal on the previous day is excluded', () {
      final meals = [
        mealAt(DateTime(2026, 5, 10, 23, 59), calories: 700),
        mealAt(DateTime(2026, 5, 11, 0, 0), calories: 100),
      ];
      expect(nutritionTotalsForDay(meals, DateTime(2026, 5, 11)).calories, 100);
    });
  });

  group('weekly aggregation', () {
    final goals =
        NutritionGoals(calories: 2000, protein: 150, carbs: 250, fat: 70);

    test('sums exactly the seven in-window days and reports over/under deltas',
        () {
      final meals = [
        // Monday: 2100 kcal / 160 p -> 100 over calories, 10 over protein.
        mealAt(DateTime(2026, 5, 11, 8), calories: 2100, protein: 160),
        // Tuesday: 1800 kcal / 140 p -> 200 under calories, 10 under protein.
        mealAt(DateTime(2026, 5, 12, 8), calories: 1800, protein: 140),
        // Wednesday: exactly on the calorie goal.
        mealAt(DateTime(2026, 5, 13, 8), calories: 2000, protein: 150),
        // Sunday 23:59 is still in the week.
        mealAt(DateTime(2026, 5, 17, 23, 59), calories: 500),
        // The Monday after the week is out of window.
        mealAt(DateTime(2026, 5, 18, 0, 0), calories: 9999),
        // The Sunday before the week is out of window.
        mealAt(DateTime(2026, 5, 10, 23, 59), calories: 8888),
      ];

      final week = weeklyNutrition(meals, DateTime(2026, 5, 13), goals);
      expect(week, hasLength(7));
      expect(week.map((d) => d.day), [
        for (var i = 0; i < 7; i++) DateTime(2026, 5, 11 + i),
      ]);

      expect(week[0].totals.calories, 2100);
      expect(week[0].deltaFor(NutritionMetric.calories), 100);
      expect(week[0].deltaFor(NutritionMetric.protein), 10);
      expect(week[0].isOver(NutritionMetric.calories), isTrue);

      expect(week[1].totals.calories, 1800);
      expect(week[1].deltaFor(NutritionMetric.calories), -200);
      expect(week[1].deltaFor(NutritionMetric.protein), -10);
      expect(week[1].isOver(NutritionMetric.calories), isFalse);

      expect(week[2].deltaFor(NutritionMetric.calories), 0);
      expect(week[2].logged, isTrue);

      expect(week[3].logged, isFalse);
      expect(week[3].totals.calories, 0);

      expect(week[6].totals.calories, 500,
          reason: 'Sunday 23:59 belongs to the week');
      expect(week[6].deltaFor(NutritionMetric.calories), -1500);

      // Neither out-of-window row leaked in.
      final total = week.fold<double>(0, (a, d) => a + d.totals.calories);
      expect(total, 2100 + 1800 + 2000 + 500);
    });

    test('summarizeWeek counts over, under, on-target and unlogged days', () {
      final meals = [
        mealAt(DateTime(2026, 5, 11, 8), calories: 2100),
        mealAt(DateTime(2026, 5, 12, 8), calories: 1800),
        mealAt(DateTime(2026, 5, 13, 8), calories: 2000),
        mealAt(DateTime(2026, 5, 14, 8), calories: 2500),
      ];
      final week = weeklyNutrition(meals, DateTime(2026, 5, 11), goals);
      final summary = summarizeWeek(week, NutritionMetric.calories);
      expect(summary.over, 2);
      expect(summary.under, 1);
      expect(summary.onTarget, 1);
      expect(summary.unlogged, 3);
      expect(summary.over + summary.under + summary.onTarget + summary.unlogged,
          7);
    });

    test('weekStartFor snaps any day to its Monday', () {
      expect(weekStartFor(DateTime(2026, 5, 11)), DateTime(2026, 5, 11));
      expect(
          weekStartFor(DateTime(2026, 5, 17, 23, 59)), DateTime(2026, 5, 11));
      expect(weekStartFor(DateTime(2026, 5, 18)), DateTime(2026, 5, 18));
      // Month and year boundaries.
      expect(weekStartFor(DateTime(2026, 1, 1)), DateTime(2025, 12, 29));
      expect(weekStartFor(DateTime(2026, 3, 1)), DateTime(2026, 2, 23));
    });
  });
}
