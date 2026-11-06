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
      expect(toKg(fromKg(82.5, WeightUnit.lb), WeightUnit.lb),
          closeTo(82.5, 0.05));
    });

    test('parsed display weight is stored in kg', () {
      expect(parseWeightKg('82.5', WeightUnit.kg), closeTo(82.5, 0.001));
      expect(parseWeightKg('100', WeightUnit.lb), closeTo(45.3592, 0.001));
    });

    test('parsed lb weight round-trips through display without drift', () {
      final kg = parseWeightKg('100', WeightUnit.lb)!;
      expect(fromKg(kg, WeightUnit.lb), closeTo(100, 0.05));
      expect(trimZero(fromKg(kg, WeightUnit.lb)), '100');
    });

    test('unparseable weight returns null', () {
      expect(parseWeightKg('', WeightUnit.kg), isNull);
      expect(parseWeightKg('abc', WeightUnit.lb), isNull);
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

    test('history series carries balances forward and subtracts debts', () {
      final points = netWorthSeries([
        (accountId: 1, balance: 15000, isLiability: false, takenAt: 300),
        (accountId: 1, balance: 10000, isLiability: false, takenAt: 100),
        (accountId: 2, balance: 12000, isLiability: true, takenAt: 200),
      ]);
      expect(points.length, 3);
      expect(points[0].value, closeTo(10000, 0.001));
      expect(points[1].value, closeTo(-2000, 0.001));
      expect(points[2].value, closeTo(3000, 0.001));
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
      expect(
          Mind.moodStreak([DateTime(2026, 5, 9)], today: DateTime(2026, 5, 10)),
          0);
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

  group('finance', () {
    test('future value compounds principal and contributions', () {
      // 10k at 0% for 5 years stays 10k
      expect(
        Finance.futureValue(principal: 10000, annualPercent: 0, years: 5),
        closeTo(10000, 0.01),
      );
      // 10k at 12% for 1 year = 11268.25 (monthly compounding)
      expect(
        Finance.futureValue(principal: 10000, annualPercent: 12, years: 1),
        closeTo(11268.25, 1),
      );
      // 100/month at 6% for 10 years
      expect(
        Finance.futureValue(
            principal: 0,
            monthlyContribution: 100,
            annualPercent: 6,
            years: 10),
        closeTo(16387.9, 5),
      );
    });

    test('payoff months with and without interest', () {
      expect(
          Finance.payoffMonths(
              principal: 1200, monthlyPayment: 100, annualPercent: 0),
          12);
      expect(
          Finance.payoffMonths(
              principal: 10000, monthlyPayment: 300, annualPercent: 12),
          greaterThan(37));
      // Payment below monthly interest never pays off.
      expect(
          Finance.payoffMonths(
              principal: 10000, monthlyPayment: 100, annualPercent: 12),
          isNull);
      expect(
          Finance.payoffMonths(
              principal: 0, monthlyPayment: 100, annualPercent: 5),
          0);
    });

    test('investing beats paying a 0% debt at 7% returns', () {
      final upside = Finance.upsideVsInvest(
          principal: 5000, debtPercent: 0, investPercent: 7, years: 3);
      expect(upside, greaterThan(0));
    });
  });

  group('number formatting', () {
    test('groups thousands for whole numbers', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(1000), '1,000');
      expect(formatCount(1234567), '1,234,567');
    });

    test('keeps the minus sign on negatives', () {
      expect(formatCount(-1234), '-1,234');
    });

    test('truncates fractions instead of rounding', () {
      expect(formatCount(82.3), '82');
      expect(formatCount(82.9), '82');
      expect(formatCount(12345.67), '12,345');
    });
  });
}
