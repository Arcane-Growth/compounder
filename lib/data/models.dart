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

class Meal {
  final int id;
  final int timestamp;
  final String imagePath;
  final String dish;
  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final List<Food> foods;
  final bool isAuto;

  const Meal({
    required this.id,
    required this.timestamp,
    required this.imagePath,
    required this.dish,
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
        calories: (m['calories'] as num).toDouble(),
        protein: (m['protein'] as num).toDouble(),
        carbs: (m['carbs'] as num).toDouble(),
        fat: (m['fat'] as num).toDouble(),
        foods: const [],
        isAuto: (m['is_auto'] as int) == 1,
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
