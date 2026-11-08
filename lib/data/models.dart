import '../domain/domain.dart';

class Exercise {
  final int id;
  final String name;
  final String muscleGroup;
  final String equipment;
  final bool isCustom;

  const Exercise({
    required this.id,
    required this.name,
    required this.muscleGroup,
    required this.equipment,
    this.isCustom = false,
  });

  factory Exercise.fromMap(Map<String, Object?> m) => Exercise(
        id: m['id'] as int,
        name: m['name'] as String,
        muscleGroup: m['muscle_group'] as String,
        equipment: m['equipment'] as String,
        isCustom: (m['is_custom'] as int) == 1,
      );

  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'name': name,
        'muscle_group': muscleGroup,
        'equipment': equipment,
        'is_custom': isCustom ? 1 : 0,
      };
}

class Workout {
  final int id;
  final String name;
  final int startedAt;
  final int? endedAt;
  final String? note;

  const Workout({
    required this.id,
    required this.name,
    required this.startedAt,
    this.endedAt,
    this.note,
  });

  bool get active => endedAt == null;

  factory Workout.fromMap(Map<String, Object?> m) => Workout(
        id: m['id'] as int,
        name: m['name'] as String,
        startedAt: m['started_at'] as int,
        endedAt: m['ended_at'] as int?,
        note: m['note'] as String?,
      );

  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'name': name,
        'started_at': startedAt,
        'ended_at': endedAt,
        'note': note,
      };
}

class WorkoutExercise {
  final int id;
  final int workoutId;
  final int exerciseId;
  final int position;

  const WorkoutExercise({
    required this.id,
    required this.workoutId,
    required this.exerciseId,
    required this.position,
  });

  factory WorkoutExercise.fromMap(Map<String, Object?> m) => WorkoutExercise(
        id: m['id'] as int,
        workoutId: m['workout_id'] as int,
        exerciseId: m['exercise_id'] as int,
        position: m['position'] as int,
      );
}

class WorkoutSet {
  final int id;
  final int workoutExerciseId;
  final int position;
  final double weightKg;
  final int reps;
  final int? completedAt;
  final bool isWarmup;

  const WorkoutSet({
    required this.id,
    required this.workoutExerciseId,
    required this.position,
    required this.weightKg,
    required this.reps,
    this.completedAt,
    this.isWarmup = false,
  });

  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'workout_exercise_id': workoutExerciseId,
        'position': position,
        'weight_kg': weightKg,
        'reps': reps,
        'completed_at': completedAt,
        'is_warmup': isWarmup ? 1 : 0,
      };

  factory WorkoutSet.fromMap(Map<String, Object?> m) => WorkoutSet(
        id: m['id'] as int,
        workoutExerciseId: m['workout_exercise_id'] as int,
        position: m['position'] as int,
        weightKg: (m['weight_kg'] as num).toDouble(),
        reps: m['reps'] as int,
        completedAt: m['completed_at'] as int?,
        isWarmup: (m['is_warmup'] as int) == 1,
      );
}

class Food {
  final String name;
  final double grams;
  final double calories;
  final double protein;
  final double carbs;
  final double fat;

  const Food(this.name, this.grams, this.calories, this.protein, this.carbs, this.fat);

  Map<String, Object?> toJson() => {
        'name': name,
        'grams': grams,
        'calories': calories,
        'protein': protein,
        'carbs': carbs,
        'fat': fat,
      };

  factory Food.fromJson(Map<String, Object?> j) => Food(
        (j['name'] as String?) ?? '',
        (j['grams'] as num?)?.toDouble() ?? 0,
        (j['calories'] as num?)?.toDouble() ?? 0,
        (j['protein'] as num?)?.toDouble() ?? 0,
        (j['carbs'] as num?)?.toDouble() ?? 0,
        (j['fat'] as num?)?.toDouble() ?? 0,
      );
}

class Meal implements MealNutrition {
  final int id;
  @override
  final int timestamp;
  final String imagePath;
  final String dish;

  /// Free-text note about the meal ("two slices, extra cheese"). Nullable so
  /// rows written before schema v4 stay valid.
  final String? description;
  @override
  final double calories;
  @override
  final double protein;
  @override
  final double carbs;
  @override
  final double fat;
  final List<Food> foods;
  final bool isAuto;

  const Meal({
    required this.id,
    required this.timestamp,
    required this.imagePath,
    required this.dish,
    this.description,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    this.foods = const [],
    this.isAuto = false,
  });

  factory Meal.fromMap(Map<String, Object?> m) => Meal(
        id: m['id'] as int,
        timestamp: m['timestamp'] as int,
        imagePath: m['image_path'] as String? ?? '',
        dish: m['dish'] as String,
        description: m['description'] as String?,
        calories: (m['calories'] as num).toDouble(),
        protein: (m['protein'] as num).toDouble(),
        carbs: (m['carbs'] as num).toDouble(),
        fat: (m['fat'] as num).toDouble(),
        foods: const [],
        isAuto: (m['is_auto'] as int) == 1,
      );

  /// Column map for the `meals` table. `foods` are stored separately as
  /// `foods_json`, so callers that persist a meal must add that key.
  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'timestamp': timestamp,
        'image_path': imagePath,
        'dish': dish,
        'description': description,
        'calories': calories,
        'protein': protein,
        'carbs': carbs,
        'fat': fat,
        'is_auto': isAuto ? 1 : 0,
      };

  Meal copyWith({
    int? id,
    int? timestamp,
    String? imagePath,
    String? dish,
    String? description,
    double? calories,
    double? protein,
    double? carbs,
    double? fat,
    List<Food>? foods,
    bool? isAuto,
  }) =>
      Meal(
        id: id ?? this.id,
        timestamp: timestamp ?? this.timestamp,
        imagePath: imagePath ?? this.imagePath,
        dish: dish ?? this.dish,
        description: description ?? this.description,
        calories: calories ?? this.calories,
        protein: protein ?? this.protein,
        carbs: carbs ?? this.carbs,
        fat: fat ?? this.fat,
        foods: foods ?? this.foods,
        isAuto: isAuto ?? this.isAuto,
      );
}

class Account {
  final int id;
  final String name;
  final String type;
  final double balance;
  final String currency;
  final int updatedAt;

  const Account({
    required this.id,
    required this.name,
    required this.type,
    required this.balance,
    this.currency = 'USD',
    required this.updatedAt,
  });

  bool get isLiability => type == 'Debt';

  static const types = ['Cash', 'Bank', 'Brokerage', 'Retirement', 'Crypto', 'Property', 'Debt', 'Other'];

  factory Account.fromMap(Map<String, Object?> m) => Account(
        id: m['id'] as int,
        name: m['name'] as String,
        type: m['type'] as String,
        balance: (m['balance'] as num).toDouble(),
        currency: m['currency'] as String,
        updatedAt: m['updated_at'] as int,
      );

  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'name': name,
        'type': type,
        'balance': balance,
        'currency': currency,
        'updated_at': updatedAt,
      };
}

class MoodEntry {
  final int id;
  final int timestamp;
  final int mood;
  final String note;

  const MoodEntry({required this.id, required this.timestamp, required this.mood, this.note = ''});

  factory MoodEntry.fromMap(Map<String, Object?> m) => MoodEntry(
        id: m['id'] as int,
        timestamp: m['timestamp'] as int,
        mood: m['mood'] as int,
        note: m['note'] as String? ?? '',
      );

  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'timestamp': timestamp,
        'mood': mood,
        'note': note,
      };
}

class MeditationEntry {
  final int id;
  final int timestamp;
  final int minutes;
  final String kind;

  const MeditationEntry({
    required this.id,
    required this.timestamp,
    required this.minutes,
    this.kind = 'Meditation',
  });

  factory MeditationEntry.fromMap(Map<String, Object?> m) => MeditationEntry(
        id: m['id'] as int,
        timestamp: m['timestamp'] as int,
        minutes: m['minutes'] as int,
        kind: m['kind'] as String,
      );

  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'timestamp': timestamp,
        'minutes': minutes,
        'kind': kind,
      };
}

class ThoughtRecord {
  final int id;
  final int timestamp;
  final String situation;
  final String thought;
  final String reframe;

  const ThoughtRecord({
    required this.id,
    required this.timestamp,
    required this.situation,
    required this.thought,
    this.reframe = '',
  });

  factory ThoughtRecord.fromMap(Map<String, Object?> m) => ThoughtRecord(
        id: m['id'] as int,
        timestamp: m['timestamp'] as int,
        situation: m['situation'] as String,
        thought: m['thought'] as String,
        reframe: m['reframe'] as String? ?? '',
      );

  Map<String, Object?> toMap() => {
        if (id != 0) 'id': id,
        'timestamp': timestamp,
        'situation': situation,
        'thought': thought,
        'reframe': reframe,
      };
}

class WorkoutSummary {
  final int workoutId;
  final String name;
  final int startedAt;
  final int? endedAt;
  final double totalKg;
  final int setCount;
  final int exerciseCount;

  const WorkoutSummary({
    required this.workoutId,
    required this.name,
    required this.startedAt,
    required this.endedAt,
    required this.totalKg,
    required this.setCount,
    required this.exerciseCount,
  });
}

class Reminder {
  final int id;
  final String text;
  final int dueAt;
  final int createdAt;

  const Reminder({
    required this.id,
    required this.text,
    required this.dueAt,
    required this.createdAt,
  });

  factory Reminder.fromMap(Map<String, Object?> m) => Reminder(
        id: m['id'] as int,
        text: m['text'] as String,
        dueAt: m['due_at'] as int,
        createdAt: m['created_at'] as int,
      );
}

/// A habit the user tracks: a name, a cadence and a target number of days per
/// period. Archived habits keep their completion history but drop out of the
/// daily checklist.
class Habit {
  final int id;
  final String name;

  /// `daily`, `weekly` or `monthly`. Stored as text so an unknown value from a
  /// newer build degrades to a readable row instead of failing the query.
  final String cadence;
  final int target;
  final bool archived;
  final int createdAt;

  const Habit({
    required this.id,
    required this.name,
    required this.cadence,
    required this.target,
    this.archived = false,
    required this.createdAt,
  });

  factory Habit.fromMap(Map<String, Object?> m) => Habit(
        id: m['id'] as int,
        name: m['name'] as String,
        cadence: m['cadence'] as String,
        target: m['target'] as int,
        archived: (m['archived'] as int) == 1,
        createdAt: m['created_at'] as int,
      );
}

/// One checked-off day for a habit. [day] is a local `YYYY-MM-DD` key, not an
/// epoch timestamp: a habit is done on a calendar day, and a timestamp would
/// shift across timezones and DST.
class HabitCompletion {
  final int id;
  final int habitId;
  final String day;
  final int count;
  final int createdAt;

  const HabitCompletion({
    required this.id,
    required this.habitId,
    required this.day,
    this.count = 1,
    required this.createdAt,
  });

  factory HabitCompletion.fromMap(Map<String, Object?> m) => HabitCompletion(
        id: m['id'] as int,
        habitId: m['habit_id'] as int,
        day: m['day'] as String,
        count: m['count'] as int,
        createdAt: m['created_at'] as int,
      );
}
