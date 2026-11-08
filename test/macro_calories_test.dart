import 'package:compounder/domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feature 1: the macro→calorie calculator. These pin measured values (not
/// merely non-null results) and the guards that keep a half-typed or hostile
/// text field from producing nonsense or throwing.
void main() {
  group('caloriesFromMacros', () {
    test('40P/50C/20F is 540 kcal', () {
      // 40*4 + 50*4 + 20*9 = 160 + 200 + 180
      expect(caloriesFromMacros(40, 50, 20), 540);
    });

    test('zero macros are zero calories', () {
      expect(caloriesFromMacros(0, 0, 0), 0);
    });

    test('negative grams are clamped to zero', () {
      // 0 + 50*4 + 20*9
      expect(caloriesFromMacros(-40, 50, 20), 380);
      expect(caloriesFromMacros(-40, -50, -20), 0);
    });

    test('non-finite grams are treated as zero', () {
      // 50*4 + 20*9
      expect(caloriesFromMacros(double.nan, 50, 20), 380);
      expect(caloriesFromMacros(double.infinity, 50, 20), 380);
      expect(caloriesFromMacros(double.negativeInfinity, 50, 20), 380);
    });

    test('uses 4/4/9 kcal per gram', () {
      expect(caloriesFromMacros(1, 0, 0), 4);
      expect(caloriesFromMacros(0, 1, 0), 4);
      expect(caloriesFromMacros(0, 0, 1), 9);
    });

    test('fractional grams are kept', () {
      expect(caloriesFromMacros(12.5, 0, 0), 50);
      expect(caloriesFromMacros(0, 0, 2.5), 22.5);
    });
  });

  group('parseMacroGrams', () {
    test('parses a plain number', () {
      expect(parseMacroGrams('40'), 40);
    });

    test('parses a decimal with surrounding whitespace', () {
      expect(parseMacroGrams(' 12.5 '), 12.5);
    });

    test('empty and non-numeric input read as zero', () {
      expect(parseMacroGrams(''), 0);
      expect(parseMacroGrams('abc'), 0);
      expect(parseMacroGrams('4o'), 0);
    });

    test('negative input reads as zero', () {
      expect(parseMacroGrams('-5'), 0);
    });

    test('non-finite text reads as zero', () {
      expect(parseMacroGrams('NaN'), 0);
      expect(parseMacroGrams('Infinity'), 0);
      expect(parseMacroGrams('-Infinity'), 0);
    });
  });
}
