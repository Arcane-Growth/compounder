import 'package:compounder/domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('one rep max', () {
    test('epley equals weight at one rep', () {
      expect(epley(100, 1), 100);
    });

    test('epley grows with reps', () {
      expect(epley(100, 10), closeTo(133.33, 0.01));
    });

    test('brzycki matches formula', () {
      expect(brzycki(100, 10), closeTo(133.33, 0.01));
    });

    test('brzycki rejects invalid reps', () {
      expect(() => brzycki(100, 0), throwsArgumentError);
      expect(() => brzycki(100, 37), throwsArgumentError);
    });

    test('max picks the strongest set', () {
      expect(e1rmMaxOf([(60, 8), (80, 3), (70, 6)]), closeTo(88.0, 0.01));
    });

    test('format rounds to nearest half kg', () {
      expect(formatE1rm(97.74), 97.5);
      expect(formatE1rm(97.76), 98.0);
    });

    test('session points exclude warmups and sort by date', () {
      final points = sessionPoints([
        (workoutId: 1, date: 200, weightKg: 80, reps: 5, isWarmup: false),
        (workoutId: 1, date: 200, weightKg: 40, reps: 8, isWarmup: true),
        (workoutId: 2, date: 100, weightKg: 75, reps: 5, isWarmup: false),
      ]);
      expect(points.length, 2);
      expect(points.first.workoutId, 2);
      expect(points.last.valueKg, closeTo(93.5, 0.01));
    });

    test('delta is latest minus first', () {
      const points = [E1RmPoint(1, 1, 90), E1RmPoint(2, 2, 101.5)];
      expect(deltaKg(points), closeTo(11.5, 0.001));
    });
  });

  group('units', () {
    test('kg to lb', () {
      expect(fromKg(100, WeightUnit.lb), closeTo(220.5, 0.05));
    });

    test('round-trip through lb', () {
      expect(toKg(fromKg(82.5, WeightUnit.lb), WeightUnit.lb), closeTo(82.5, 0.05));
    });

    test('unit lookup falls back to kg', () {
      expect(WeightUnit.from('nonsense'), WeightUnit.kg);
    });

    test('trimZero drops empty decimals', () {
      expect(trimZero(97.0), '97');
      expect(trimZero(97.5), '97.5');
    });
  });

  group('wealth', () {
    const entries = [
      (10000.0, false), // cash
      (250000.5, false), // property
      (12000.0, true), // car loan
    ];

    test('net worth subtracts liabilities', () {
      expect(Wealth.netWorth(entries), closeTo(248000.5, 0.001));
    });

    test('liabilities are absolute even if stored negative', () {
      expect(Wealth.netWorth([(500.0, true)]), -500);
    });

    test('totals split by kind', () {
      expect(Wealth.totalAssets(entries), closeTo(260000.5, 0.001));
      expect(Wealth.totalLiabilities(entries), closeTo(12000, 0.001));
    });

    test('amount formatting groups thousands', () {
      expect(Wealth.formatAmount(1234567.891), '1,234,567.89');
      expect(Wealth.formatAmount(-1234.5), '-1,234.50');
    });
  });

  group('mind', () {
    test('average mood', () {
      expect(Mind.averageMood([3, 4, 5]), closeTo(4.0, 0.001));
      expect(Mind.averageMood([]), isNull);
    });

    test('streak counts consecutive days ending today', () {
      final today = DateTime(2026, 5, 10, 9);
      final checkins = [
        DateTime(2026, 5, 10, 8),
        DateTime(2026, 5, 10, 21),
        DateTime(2026, 5, 9),
        DateTime(2026, 5, 8),
        DateTime(2026, 5, 6),
      ];
      expect(Mind.moodStreak(checkins, today: today), 3);
    });

    test('streak is zero without a check-in today', () {
      expect(Mind.moodStreak([DateTime(2026, 5, 9)], today: DateTime(2026, 5, 10)), 0);
    });

    test('minutes between windows', () {
      final sessions = [
        (DateTime(2026, 5, 1, 7), 10),
        (DateTime(2026, 5, 2, 7), 5),
        (DateTime(2026, 5, 9, 7), 20),
      ];
      expect(
        Mind.minutesBetween(
            sessions, DateTime(2026, 4, 30), DateTime(2026, 5, 3)),
        15,
      );
    });
  });
}
