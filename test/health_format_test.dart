import 'package:compounder/ui/health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('efficiency percent formatting', () {
    test('null means nothing recorded', () {
      expect(formatEfficiencyPercent(null), '—');
    });

    test('values are already 0..100 percentages and are not rescaled', () {
      // Regression: a `value <= 1 ? value * 100 : value` branch used to turn a
      // 1% night into "100%" and a 0.5% night into "50%".
      expect(formatEfficiencyPercent(0), '0%');
      expect(formatEfficiencyPercent(1), '1%');
      expect(formatEfficiencyPercent(0.5), '0%');
      expect(formatEfficiencyPercent(1.5), '1%');
      expect(formatEfficiencyPercent(87), '87%');
      expect(formatEfficiencyPercent(100), '100%');
    });

    test('fractions truncate rather than round, like other counters', () {
      expect(formatEfficiencyPercent(87.4), '87%');
      expect(formatEfficiencyPercent(87.9), '87%');
    });

    test('integers carry thousands separators', () {
      expect(formatEfficiencyPercent(1000), '1,000%');
    });
  });
}
