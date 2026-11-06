import 'package:compounder/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

Meal _meal({String? description}) => Meal(
      id: 7,
      timestamp: 1700000000000,
      imagePath: '/meals/meal-1.jpg',
      dish: 'Chicken bowl',
      description: description,
      calories: 620,
      protein: 48,
      carbs: 61,
      fat: 18,
      foods: const [Food('Chicken', 180, 300, 45, 0, 8)],
      isAuto: true,
    );

void main() {
  group('meal description', () {
    test('round-trips through the column map', () {
      final map = _meal(description: 'two slices, extra cheese').toMap();
      expect(map['description'], 'two slices, extra cheese');
      final back = Meal.fromMap({...map, 'foods_json': '[]'});
      expect(back.id, 7);
      expect(back.dish, 'Chicken bowl');
      expect(back.description, 'two slices, extra cheese');
      expect(back.isAuto, isTrue);
      expect(back.calories, 620);
    });

    test('a row written before the description column stays readable', () {
      final map = _meal().toMap()..remove('description');
      expect(Meal.fromMap(map).description, isNull);
    });

    test('copyWith keeps the description and can replace it', () {
      final original = _meal(description: 'one slice');
      expect(original.copyWith(calories: 700).description, 'one slice');
      expect(original.copyWith(description: 'two slices').description,
          'two slices');
      expect(original.copyWith(description: 'two slices').calories, 620);
    });

    test('toMap omits the id for an unsaved meal', () {
      final draft = Meal(
        id: 0,
        timestamp: 1,
        imagePath: '',
        dish: 'Toast',
        calories: 90,
        protein: 3,
        carbs: 15,
        fat: 1,
      );
      expect(draft.toMap().containsKey('id'), isFalse);
      expect(draft.toMap()['description'], isNull);
    });
  });
}
