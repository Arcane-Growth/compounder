import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/domain.dart';
import '../domain/habits.dart';
import 'models.dart';

class MacroGoals {
  final double calories, protein, carbs, fat;
  const MacroGoals(
      {this.calories = 2000,
      this.protein = 150,
      this.carbs = 250,
      this.fat = 70});
}

class AiSettings {
  final String baseUrl, apiKey, model;
  const AiSettings({this.baseUrl = '', this.apiKey = '', this.model = ''});

  bool get configured =>
      baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;
}

class ExerciseView {
  final WorkoutExercise entry;
  final Exercise exercise;
  final List<WorkoutSet> sets;
  const ExerciseView(this.entry, this.exercise, this.sets);
}

/// A store operation failed in a way the UI should report to the user.
///
/// [message] is safe to show as-is; [cause] keeps the underlying error for
/// logging.
class StoreException implements Exception {
  final String message;
  final Object? cause;
  const StoreException(this.message, {this.cause});

  @override
  String toString() => message;
}

class WorkoutDetail {
  final Workout workout;
  final List<ExerciseView> exercises;
  const WorkoutDetail(this.workout, this.exercises);

  Volume get volume => volumeOf(exercises
      .expand((e) => e.sets)
      .map((s) => (weightKg: s.weightKg, reps: s.reps, isWarmup: s.isWarmup)));
}

/// Single source of truth: owns the database, cached lists and settings.
class AppStore extends ChangeNotifier {
  late final Database db;
  final SharedPreferences prefs;

  List<Exercise> exercises = [];
  List<WorkoutSummary> history = [];
  List<Meal> meals = [];
  List<Account> accounts = [];
  List<NetWorthPoint> netWorthHistory = [];
  List<MoodEntry> moods = [];
  List<MeditationEntry> meditations = [];
  List<ThoughtRecord> thoughts = [];
  List<Reminder> reminders = [];
  List<Habit> habits = [];
  List<HabitCompletion> habitCompletions = [];
  List<int> usageOrder = [];

  AppStore._(this.db, this.prefs);

  static Future<AppStore> open(SharedPreferences prefs, {String? path}) async {
    path ??= p.join(await getDatabasesPath(), 'compounder.db');
    final db = await openDatabase(path,
        version: 10,
        onConfigure: _configureSchema,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema);
    final store = AppStore._(db, prefs);
    await store.refreshAll();
    return store;
  }

  /// Enables foreign-key enforcement for every connection. Without this the
  /// `REFERENCES ... ON DELETE CASCADE` clauses on workout_exercises and
  /// workout_sets are decorative: SQLite defaults `foreign_keys` to OFF, so a
  /// dangling child row could be written and never cleaned up.
  static Future<void> _configureSchema(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''CREATE TABLE exercises(
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, muscle_group TEXT NOT NULL,
      equipment TEXT NOT NULL DEFAULT '', is_custom INTEGER NOT NULL DEFAULT 0)''');
    await db.execute('''CREATE TABLE workouts(
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, started_at INTEGER NOT NULL,
      ended_at INTEGER, note TEXT)''');
    await db.execute('''CREATE TABLE workout_exercises(
      id INTEGER PRIMARY KEY AUTOINCREMENT, workout_id INTEGER NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
      exercise_id INTEGER NOT NULL, position INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE workout_sets(
      id INTEGER PRIMARY KEY AUTOINCREMENT, workout_exercise_id INTEGER NOT NULL
      REFERENCES workout_exercises(id) ON DELETE CASCADE,
      position INTEGER NOT NULL, weight_kg REAL NOT NULL, reps INTEGER NOT NULL,
      completed_at INTEGER, is_warmup INTEGER NOT NULL DEFAULT 0)''');
    await db.execute('''CREATE TABLE meals(
      id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, image_path TEXT NOT NULL DEFAULT '',
      dish TEXT NOT NULL, description TEXT, calories REAL NOT NULL, protein REAL NOT NULL,
      carbs REAL NOT NULL, fat REAL NOT NULL,
      foods_json TEXT NOT NULL DEFAULT '[]', is_auto INTEGER NOT NULL DEFAULT 0)''');
    await db.execute('''CREATE TABLE accounts(
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, balance REAL NOT NULL,
      currency TEXT NOT NULL DEFAULT 'USD', updated_at INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE moods(
      id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, mood INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '')''');
    await db.execute('''CREATE TABLE meditations(
      id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, minutes INTEGER NOT NULL, kind TEXT NOT NULL DEFAULT 'Meditation')''');
    await db.execute('''CREATE TABLE thought_records(
      id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, situation TEXT NOT NULL,
      thought TEXT NOT NULL, reframe TEXT NOT NULL DEFAULT '')''');
    await _createV2Tables(db);
    await _createV3Tables(db);
    await _createV8Indexes(db);
    await _createV9Indexes(db);
    await _createV10Tables(db);
  }

  static Future<void> _createV2Tables(Database db) async {
    await db.execute('''CREATE TABLE balance_snapshots(
      id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER NOT NULL,
      balance REAL NOT NULL, taken_at INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE reminders(
      id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, due_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL)''');
  }

  static Future<void> _upgradeSchema(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createV2Tables(db);
      // Give every existing account a starting point so trends have a baseline.
      await db.execute(
          'INSERT INTO balance_snapshots(account_id, balance, taken_at) SELECT id, balance, updated_at FROM accounts');
    }
    if (oldVersion < 3) {
      await _createV3Tables(db);
    }
    if (oldVersion < 4) {
      // Column add is additive only: existing meal rows keep every value and
      // simply read back a null description.
      await _addColumnIfMissing(db, 'meals', 'description', 'TEXT');
    }
    if (oldVersion < 5) {
      // health-13.3.1 stamped every sleep stage of a night with the parent
      // session's uuid, so the UNIQUE uuid column kept only the last stage per
      // night and destroyed the rest. Those rows are unrecoverable (the stages
      // were overwritten, not merely mis-keyed), so purge them and let the next
      // sync re-fetch the night with composite uuids. Only sleep rows and the
      // sleep sync stamps are touched; every other metric keeps its history.
      await db.delete('health_records', where: "type LIKE 'SLEEP%'");
      await db.delete('health_sync_state', where: "metric LIKE 'SLEEP%'");
    }
    if (oldVersion < 6) {
      // The 4->5 step purged the sleep rows but left the aggregate `__all__`
      // sync stamp behind. HealthService.syncNow derives its start window from
      // repository.lastSync(), which reads only `__all__`, so the next sync
      // resumed from that stamp and re-fetched roughly two days instead of the
      // full 30-day window: ~25 nights of sleep history stayed missing even
      // though Health Connect still had them. Clearing the aggregate stamp
      // makes lastSync() return null, so the next sync takes the initial path
      // and re-fetches the whole window. Only `__all__` is touched; every
      // per-metric stamp and every non-sleep record survives.
      await db.delete('health_sync_state', where: "metric = '__all__'");
    }
    if (oldVersion < 7) {
      // The 5->6 step cleared only the aggregate `__all__` stamp, which is not
      // sufficient. runChunkedSync also resumes from the per-metric stamps
      // (service.dart:197-202), and the narrow post-migration sync re-created
      // SLEEP_* stamps at the recent end of the window. Those stamps pull the
      // sleep chunk start forward again, so the sleep window stays narrow and
      // the purged nights are never re-fetched.
      //
      // Verified on the Pixel 10: with only `__all__` cleared, the next sync
      // still fetched a single night (22 rows, one date). Clearing the SLEEP_*
      // stamps as well lets the sleep types start from the initial window.
      //
      // Only `__all__` and the SLEEP_* family are touched; every other
      // metric's stamp and every non-sleep record survives untouched.
      await db.delete('health_sync_state', where: "metric = '__all__'");
      await db.delete('health_sync_state', where: "metric LIKE 'SLEEP%'");
    }
    if (oldVersion < 8) {
      // Every non-health table was created without indexes, so the hot paths
      // (workout detail, meal list, net-worth series, due reminders) were full
      // table scans. Indexes are additive: no row is rewritten, so existing
      // data is untouched. IF NOT EXISTS keeps the step safe to re-run on a
      // partially applied migration.
      //
      // What the indexes actually buy, measured with EXPLAIN QUERY PLAN on
      // populated tables: `meals` and `reminders` become index scans/searches
      // with no temp B-tree. `balance_snapshots` becomes a covering index scan
      // ordered by taken_at, also with no temp B-tree. `workout_sets` and
      // `workout_exercises` become index searches on the WHERE column but still
      // build a temp B-tree to satisfy `ORDER BY position`, because the index
      // does not carry `position`. That residual sort is small (one exercise's
      // sets, one workout's entries) and is left as-is rather than widening the
      // indexes to composite shapes.
      await _createV8Indexes(db);
    }
    if (oldVersion < 9) {
      // v8 shipped `idx_balance_snapshots_account_taken(account_id, taken_at)`,
      // which cannot serve the net-worth series: that query has no account_id
      // predicate and orders by taken_at, so SQLite used the index only as a
      // scan and still built a temp B-tree — measurably slower than no index at
      // 300k rows. v9 adds the covering shape the query actually needs. The
      // account_id-leading index is kept because deleteAccount filters on
      // account_id alone and, without it, SQLite falls back to a full SCAN.
      //
      // Also renames the workout_sets index to match the column it indexes.
      // Indexes hold no user data, so dropping and recreating them is safe.
      await _createV9Indexes(db);
    }
    if (oldVersion < 10) {
      // Habit tracker. Purely additive: two new tables, no existing row is
      // touched, so a v9 install keeps every workout, meal, account and health
      // record. IF NOT EXISTS makes the step safe to re-run on a partially
      // applied migration.
      await _createV10Tables(db);
    }
  }

  /// Indexes for the non-health tables (schema v8/v9). Idempotent so both
  /// onCreate and a re-run of the 7->8 upgrade can call it.
  static Future<void> _createV8Indexes(Database db) async {
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_workout_sets_workout_exercise_id ON workout_sets(workout_exercise_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_workout_exercises_workout ON workout_exercises(workout_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_meals_timestamp ON meals(timestamp)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_balance_snapshots_account_taken ON balance_snapshots(account_id, taken_at)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_reminders_due_at ON reminders(due_at)');
  }

  /// Schema v9: the covering index the net-worth series needs, plus the
  /// workout_sets index rename. Idempotent, and safe to re-run.
  static Future<void> _createV9Indexes(Database db) async {
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_balance_snapshots_taken ON balance_snapshots(taken_at, account_id, balance)');
    // Rename: the v8 name did not match the column it indexes. DROP then
    // CREATE, both idempotent; an index carries no user data.
    await db.execute('DROP INDEX IF EXISTS idx_workout_sets_exercise');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_workout_sets_workout_exercise_id ON workout_sets(workout_exercise_id)');
  }

  /// Schema v10: the habit tracker tables. Idempotent, additive only.
  ///
  /// `habit_completions.day` is a local `YYYY-MM-DD` key rather than an epoch
  /// timestamp: a habit is done on a calendar day, and a timestamp would shift
  /// across timezones and DST. `UNIQUE(habit_id, day)` makes checking a day off
  /// twice a no-op instead of a duplicate row, and its implicit index serves
  /// both the per-habit history query and the range query.
  static Future<void> _createV10Tables(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS habits(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      cadence TEXT NOT NULL,
      target INTEGER NOT NULL DEFAULT 1,
      archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS habit_completions(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      habit_id INTEGER NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
      day TEXT NOT NULL,
      count INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL,
      UNIQUE(habit_id, day))''');
  }

  /// Adds [column] to [table] only when it is absent, so a partially applied
  /// migration can be re-run without throwing "duplicate column name".
  static Future<void> _addColumnIfMissing(
      Database db, String table, String column, String definition) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    final exists = info.any((c) => c['name'] == column);
    if (exists) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  static Future<void> _createV3Tables(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS health_records(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
      value REAL,
      unit TEXT NOT NULL DEFAULT '',
      date_from INTEGER NOT NULL,
      date_to INTEGER NOT NULL,
      source_id TEXT NOT NULL DEFAULT '',
      source_name TEXT NOT NULL DEFAULT '',
      platform TEXT NOT NULL DEFAULT '',
      recording_method INTEGER NOT NULL DEFAULT 0,
      raw_json TEXT NOT NULL DEFAULT '',
      synced_at INTEGER NOT NULL)''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_health_records_type_date ON health_records(type, date_from)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_health_records_date ON health_records(date_from)');
    await db.execute('''CREATE TABLE IF NOT EXISTS health_daily(
      day TEXT NOT NULL,
      metric TEXT NOT NULL,
      count INTEGER NOT NULL DEFAULT 0,
      sum REAL NOT NULL DEFAULT 0,
      avg REAL,
      min REAL,
      max REAL,
      detail_json TEXT NOT NULL DEFAULT '',
      PRIMARY KEY(day, metric))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS health_sync_state(
      metric TEXT PRIMARY KEY,
      last_synced_at INTEGER,
      last_success_at INTEGER,
      last_error TEXT)''');
  }

  Future<void> refreshAll() async {
    exercises = (await db.query('exercises', orderBy: 'name'))
        .map(Exercise.fromMap)
        .toList();
    history = await loadHistory();
    meals = (await db.query('meals', orderBy: 'timestamp DESC')).map((m) {
      final meal = Meal.fromMap(m);
      return meal.copyWith(foods: _decodeFoods(m['foods_json']));
    }).toList();
    accounts = (await db.query('accounts', orderBy: 'balance DESC'))
        .map(Account.fromMap)
        .toList();
    netWorthHistory = netWorthSeries(await snapshotSeries());
    moods = (await db.query('moods', orderBy: 'timestamp DESC'))
        .map(MoodEntry.fromMap)
        .toList();
    meditations = (await db.query('meditations', orderBy: 'timestamp DESC'))
        .map(MeditationEntry.fromMap)
        .toList();
    thoughts = (await db.query('thought_records', orderBy: 'timestamp DESC'))
        .map(ThoughtRecord.fromMap)
        .toList();
    reminders = (await db.query('reminders',
            where: 'due_at > ?',
            whereArgs: [DateTime.now().millisecondsSinceEpoch],
            orderBy: 'due_at'))
        .map(Reminder.fromMap)
        .toList();
    habits = (await db.query('habits', orderBy: 'name, id'))
        .map(Habit.fromMap)
        .toList();
    habitCompletions = (await db.query('habit_completions',
            orderBy: 'habit_id, day'))
        .map(HabitCompletion.fromMap)
        .toList();
    final usageRows = await db.rawQuery('''
        SELECT we.exercise_id eid, COUNT(*) c FROM workout_exercises we
        JOIN workout_sets s ON s.workout_exercise_id = we.id GROUP BY eid ORDER BY c DESC''');
    usageOrder = usageRows.map((r) => r['eid'] as int).toList();
    notifyListeners();
  }

  /// Decodes a meal's `foods_json` column. A malformed row must not make
  /// [open] throw — the meal still loads, just without its food breakdown
  /// (audit M1). Mirrors the tolerant decode in HealthDayStat.fromMap.
  ///
  /// Decoding is per entry: one entry that throws inside [Food.fromJson] (for
  /// example a non-String `name`) drops only that entry, not every food for the
  /// meal (audit F5).
  static List<Food> _decodeFoods(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final foods = <Food>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      try {
        foods.add(Food.fromJson(entry.cast<String, Object?>()));
      } catch (_) {
        // Skip just this entry; the rest of the meal's breakdown survives.
      }
    }
    return foods;
  }

  // ------------------------------------------------------------ settings

  AiSettings get ai => AiSettings(
        baseUrl: String.fromEnvironment('LLM_BASE_URL').isNotEmpty
            ? String.fromEnvironment('LLM_BASE_URL')
            : prefs.getString('baseUrl') ?? '',
        apiKey: String.fromEnvironment('LLM_API_KEY').isNotEmpty
            ? String.fromEnvironment('LLM_API_KEY')
            : prefs.getString('apiKey') ?? '',
        model: String.fromEnvironment('LLM_MODEL').isNotEmpty
            ? String.fromEnvironment('LLM_MODEL')
            : prefs.getString('model') ?? '',
      );

  Future<void> saveAi(AiSettings s) async {
    await prefs.setString('baseUrl', s.baseUrl);
    await prefs.setString('apiKey', s.apiKey);
    await prefs.setString('model', s.model);
    notifyListeners();
  }

  MacroGoals get goals => MacroGoals(
        calories: prefs.getDouble('goalCal') ?? 2000,
        protein: prefs.getDouble('goalProtein') ?? 150,
        carbs: prefs.getDouble('goalCarbs') ?? 250,
        fat: prefs.getDouble('goalFat') ?? 70,
      );

  Future<void> saveGoals(MacroGoals g) async {
    await prefs.setDouble('goalCal', g.calories);
    await prefs.setDouble('goalProtein', g.protein);
    await prefs.setDouble('goalCarbs', g.carbs);
    await prefs.setDouble('goalFat', g.fat);
    notifyListeners();
  }

  WeightUnit get unit => WeightUnit.from(prefs.getString('unit'));
  Future<void> setUnit(WeightUnit u) async {
    await prefs.setString('unit', u.name);
    notifyListeners();
  }

  int get restSeconds => prefs.getInt('restSeconds') ?? 120;
  Future<void> setRestSeconds(int s) async {
    await prefs.setInt('restSeconds', s.clamp(5, 600));
    notifyListeners();
  }

  bool get coachEnabled => prefs.getBool('coachEnabled') ?? false;
  int get coachMinutes => prefs.getInt('coachMinutes') ?? 18 * 60;
  Future<void> setCoach({bool? enabled, int? minutes}) async {
    if (enabled != null) await prefs.setBool('coachEnabled', enabled);
    if (minutes != null) {
      await prefs.setInt('coachMinutes', minutes.clamp(0, 24 * 60 - 1));
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ workouts

  Future<Workout?> activeWorkout() async {
    final rows =
        await db.query('workouts', where: 'ended_at IS NULL', limit: 1);
    return rows.isEmpty ? null : Workout.fromMap(rows.first);
  }

  Future<WorkoutDetail?> workoutDetail(int id) async {
    final rows =
        await db.query('workouts', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final workout = Workout.fromMap(rows.first);
    final entries = await db.query('workout_exercises',
        where: 'workout_id = ?', whereArgs: [id], orderBy: 'position');
    final views = <ExerciseView>[];
    for (final e in entries.map(WorkoutExercise.fromMap)) {
      final exRows = await db.query('exercises',
          where: 'id = ?', whereArgs: [e.exerciseId], limit: 1);
      if (exRows.isEmpty) continue;
      final sets = (await db.query('workout_sets',
              where: 'workout_exercise_id = ?',
              whereArgs: [e.id],
              orderBy: 'position'))
          .map(WorkoutSet.fromMap)
          .toList();
      views.add(ExerciseView(e, Exercise.fromMap(exRows.first), sets));
    }
    return WorkoutDetail(workout, views);
  }

  Future<int> createWorkout(String name) async {
    final id = await db.insert('workouts', {
      'name': name.trim().isEmpty ? 'Workout' : name.trim(),
      'started_at': DateTime.now().millisecondsSinceEpoch,
    });
    await refreshAll();
    return id;
  }

  Future<void> finishWorkout(int id) async {
    await db.update(
        'workouts', {'ended_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  Future<void> deleteWorkout(int id) async {
    await db.delete('workout_sets',
        where:
            'workout_exercise_id IN (SELECT id FROM workout_exercises WHERE workout_id = ?)',
        whereArgs: [id]);
    await db
        .delete('workout_exercises', where: 'workout_id = ?', whereArgs: [id]);
    await db.delete('workouts', where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  /// Adds an exercise, pre-filling set placeholders from the most recent session.
  /// When there is no history and [seedDefaultSet] is true, one incomplete 0 x 0
  /// set is created so the user can start editing immediately.
  ///
  /// Throws [StoreException] when the workout or exercise no longer exists.
  /// `workout_exercises.workout_id` declares a foreign key, so a dangling
  /// workout id raises a `FOREIGN KEY constraint failed` under
  /// `PRAGMA foreign_keys = ON`. `exercise_id` declares no foreign key, so a
  /// dangling exercise id would otherwise insert a row that joins to nothing;
  /// it is checked explicitly (audit backup MINOR-3).
  Future<int> addExerciseToWorkout(int workoutId, int exerciseId,
      {bool seedDefaultSet = false}) async {
    final exerciseExists = await db.query('exercises',
        columns: ['id'], where: 'id = ?', whereArgs: [exerciseId], limit: 1);
    if (exerciseExists.isEmpty) {
      throw const StoreException(
          'Could not add that exercise — it no longer exists. '
          'Pull to refresh and try again.');
    }
    final posRows = await db.rawQuery(
        'SELECT MAX(position) m FROM workout_exercises WHERE workout_id = ?',
        [workoutId]);
    final position = ((posRows.first['m'] as int?) ?? -1) + 1;
    final int entryId;
    try {
      entryId = await db.insert('workout_exercises', {
        'workout_id': workoutId,
        'exercise_id': exerciseId,
        'position': position
      });
    } on DatabaseException catch (e) {
      throw StoreException(
          'Could not add that exercise — the workout no longer exists. '
          'Pull to refresh and try again.',
          cause: e);
    }

    final latest = await db.rawQuery('''
        SELECT we.id FROM workout_exercises we
        JOIN workouts w ON w.id = we.workout_id
        WHERE we.exercise_id = ? AND w.ended_at IS NOT NULL
        ORDER BY w.started_at DESC LIMIT 1''', [exerciseId]);
    var seeded = false;
    if (latest.isNotEmpty) {
      final prev = (await db.query('workout_sets',
              where: 'workout_exercise_id = ?',
              whereArgs: [latest.first['id']],
              orderBy: 'position'))
          .map(WorkoutSet.fromMap)
          .toList();
      for (var i = 0; i < prev.length; i++) {
        await db.insert(
            'workout_sets',
            WorkoutSet(
              id: 0,
              workoutExerciseId: entryId,
              position: i,
              weightKg: prev[i].weightKg,
              reps: prev[i].reps,
              isWarmup: prev[i].isWarmup,
            ).toMap());
        seeded = true;
      }
    }
    if (!seeded && seedDefaultSet) {
      await db.insert(
          'workout_sets',
          WorkoutSet(
            id: 0,
            workoutExerciseId: entryId,
            position: 0,
            weightKg: 0,
            reps: 0,
          ).toMap());
    }
    await refreshAll();
    return entryId;
  }

  Future<int> addSet(int entryId, double weightKg, int reps,
      {bool warmup = false, bool completed = true}) async {
    final posRows = await db.rawQuery(
        'SELECT MAX(position) m FROM workout_sets WHERE workout_exercise_id = ?',
        [entryId]);
    final position = ((posRows.first['m'] as int?) ?? -1) + 1;
    final id = await db.insert('workout_sets', {
      'workout_exercise_id': entryId,
      'position': position,
      'weight_kg': weightKg,
      'reps': reps,
      'completed_at': completed ? DateTime.now().millisecondsSinceEpoch : null,
      'is_warmup': warmup ? 1 : 0,
    });
    await refreshAll();
    return id;
  }

  Future<void> updateSet(int id,
      {double? weightKg, int? reps, int? completedAt, bool? warmup}) async {
    final values = <String, Object?>{
      if (weightKg != null) 'weight_kg': weightKg,
      if (reps != null) 'reps': reps,
      if (completedAt != null)
        'completed_at': completedAt == 0 ? null : completedAt,
      if (warmup != null) 'is_warmup': warmup ? 1 : 0,
    };
    if (values.isEmpty) return;
    await db.update('workout_sets', values, where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  Future<void> deleteSetRow(int id) async {
    await db.delete('workout_sets', where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  Future<void> removeExercise(int entryId) async {
    await db.delete('workout_sets',
        where: 'workout_exercise_id = ?', whereArgs: [entryId]);
    await db.delete('workout_exercises', where: 'id = ?', whereArgs: [entryId]);
    await refreshAll();
  }

  Future<void> createExercise(
      String name, String muscleGroup, String equipment) async {
    await db.insert('exercises', {
      'name': name.trim(),
      'muscle_group': muscleGroup,
      'equipment': equipment,
      'is_custom': 1,
    });
    await refreshAll();
  }

  List<Exercise> pickerList(String query) {
    var list = exercises;
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((e) =>
              e.name.toLowerCase().contains(q) ||
              e.muscleGroup.toLowerCase().contains(q))
          .toList();
    }
    final byUsage = <int, int>{
      for (var i = 0; i < usageOrder.length; i++)
        usageOrder[i]: usageOrder.length - i,
    };
    list = [...list]
      ..sort((a, b) => (byUsage[b.id] ?? 0).compareTo(byUsage[a.id] ?? 0));
    return list;
  }

  Future<List<WorkoutSummary>> loadHistory() async {
    final rows = await db.rawQuery('''
        SELECT w.id workout_id, w.name, w.started_at, w.ended_at,
               COALESCE(SUM(CASE WHEN s.is_warmup = 0 AND s.completed_at IS NOT NULL
                                 THEN s.weight_kg * s.reps END), 0) total_kg,
               COUNT(s.id) set_count,
               (SELECT COUNT(*) FROM workout_exercises we WHERE we.workout_id = w.id) exercise_count
        FROM workouts w
        LEFT JOIN workout_exercises we ON we.workout_id = w.id
        LEFT JOIN workout_sets s ON s.workout_exercise_id = we.id
        WHERE w.ended_at IS NOT NULL
        GROUP BY w.id ORDER BY w.started_at DESC LIMIT 50''');
    return rows
        .map((r) => WorkoutSummary(
              workoutId: r['workout_id'] as int,
              name: r['name'] as String,
              startedAt: r['started_at'] as int,
              endedAt: r['ended_at'] as int?,
              totalKg: (r['total_kg'] as num).toDouble(),
              setCount: r['set_count'] as int,
              exerciseCount: r['exercise_count'] as int,
            ))
        .toList();
  }

  /// e1RM chart points for an exercise across finished sessions.
  Future<List<E1RmPoint>> progressFor(int exerciseId) async {
    final rows = await db.rawQuery('''
        SELECT w.id workout_id, w.started_at date, s.weight_kg, s.reps, s.is_warmup
        FROM workouts w
        JOIN workout_exercises we ON we.workout_id = w.id
        JOIN workout_sets s ON s.workout_exercise_id = we.id
        WHERE we.exercise_id = ? AND w.ended_at IS NOT NULL''', [exerciseId]);
    return sessionPoints(rows
        .map((r) => (
              workoutId: r['workout_id'] as int,
              date: r['date'] as int,
              weightKg: (r['weight_kg'] as num).toDouble(),
              reps: r['reps'] as int,
              isWarmup: (r['is_warmup'] as int) == 1,
            ))
        .toList());
  }

  // ------------------------------------------------------------ meals

  Map<String, Object?> _mealRow(Meal meal) => meal.toMap()
    ..['foods_json'] = jsonEncode(meal.foods.map((f) => f.toJson()).toList());

  Future<int> addMeal(Meal meal) async {
    await db.insert('meals', _mealRow(meal));
    await refreshAll();
    return 0;
  }

  /// Updates the meal's existing row (matched by id). Never inserts: an
  /// unknown id is a no-op, so a deleted meal cannot be resurrected.
  Future<void> updateMeal(Meal meal) async {
    if (meal.id == 0) return;
    final row = _mealRow(meal)..remove('id');
    await db.update('meals', row, where: 'id = ?', whereArgs: [meal.id]);
    await refreshAll();
  }

  Future<void> deleteMeal(int id) async {
    await db.delete('meals', where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  // ------------------------------------------------------------ wealth

  Future<void> saveAccount(Account a) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final map = a.toMap()..['updated_at'] = now;
    final id = a.id == 0
        ? await db.insert('accounts', map)
        : (await db.update('accounts', map,
                    where: 'id = ?', whereArgs: [a.id]) >
                0
            ? a.id
            : 0);
    // A 0 here means the UPDATE matched no row: the account was deleted from
    // under the editor. Inserting a snapshot would leave a row pointing at
    // account_id 0 that no account owns and that the net-worth join drops.
    if (id != 0) {
      await db.insert('balance_snapshots',
          {'account_id': id, 'balance': a.balance, 'taken_at': now});
    }
    await refreshAll();
  }

  /// Every balance snapshot joined to its account's current type, in a
  /// deterministic total order.
  ///
  /// The order is `(taken_at, account_id, balance, id)`: the first three
  /// columns are exactly `idx_balance_snapshots_taken`, so this shape is served
  /// by the covering index with no temp B-tree. Appending `id` is free — rowid
  /// is implicitly the last column of every SQLite index — and makes the order
  /// a strict total order, so two rows that agree on all three indexed columns
  /// still have a stable relative order. (The earlier comment claimed a
  /// measured "20 ms vs 45 ms at 300k rows"; re-measurement showed 215.3 vs
  /// 215.7 ms, and the temp B-tree belonged to the old `(taken_at, id)` shape,
  /// not to appending `id` — review b2b3b4m1 NIT-3.)
  ///
  /// This is the single source for both the Wealth screen series and the
  /// coach's `getNetWorthHistory` tool, so the two describe the same series
  /// (review F1/F2 on c3d71cd).
  Future<List<({int accountId, double balance, bool isLiability, int takenAt})>>
      snapshotSeries() async {
    final rows = await db.rawQuery('''
        SELECT s.account_id, s.balance, s.taken_at, a.type
        FROM balance_snapshots s
        JOIN accounts a ON a.id = s.account_id
        ORDER BY s.taken_at, s.account_id, s.balance, s.id''');
    return rows
        .map((r) => (
              accountId: r['account_id'] as int,
              balance: (r['balance'] as num).toDouble(),
              isLiability: (r['type'] as String) == 'Debt',
              takenAt: r['taken_at'] as int,
            ))
        .toList();
  }

  // ------------------------------------------------------------ reminders

  Future<Reminder> addReminder(String text, int dueAt) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert(
        'reminders', {'text': text, 'due_at': dueAt, 'created_at': now});
    final reminder = Reminder(id: id, text: text, dueAt: dueAt, createdAt: now);
    await refreshAll();
    return reminder;
  }

  Future<void> deleteReminder(int id) async {
    await db.delete('reminders', where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  Future<void> deleteAccount(int id) async {
    await db
        .delete('balance_snapshots', where: 'account_id = ?', whereArgs: [id]);
    await db.delete('accounts', where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  // ------------------------------------------------------------ mind

  Future<void> logMood(int mood, String note, {int? timestamp}) async {
    await db.insert('moods', {
      'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      'mood': mood.clamp(1, 5),
      'note': note,
    });
    await refreshAll();
  }

  Future<void> logMeditation(int minutes, {String kind = 'Meditation'}) async {
    await db.insert('meditations', {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'minutes': minutes,
      'kind': kind,
    });
    await refreshAll();
  }

  Future<void> logThought(
      String situation, String thought, String reframe) async {
    await db.insert('thought_records', {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'situation': situation,
      'thought': thought,
      'reframe': reframe,
    });
    await refreshAll();
  }

  Future<void> deleteThought(int id) async {
    await db.delete('thought_records', where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  Future<void> deleteMood(int id) async {
    await db.delete('moods', where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  // ------------------------------------------------------------ habits

  /// Creates a habit. Throws [StoreException] on a blank name, an unknown
  /// cadence or a target below 1, so the UI and the coach tools share one
  /// validation boundary instead of each re-implementing it.
  Future<int> createHabit(String name, String cadence, int target) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw const StoreException('Habit name cannot be empty.');
    }
    final parsed = HabitCadence.parse(cadence);
    if (parsed == null) {
      throw StoreException(
          'Unknown habit cadence "$cadence". Use daily, weekly or monthly.');
    }
    if (target < 1) {
      throw const StoreException(
          'Habit target must be at least 1 day per period.');
    }
    final id = await db.insert('habits', {
      'name': cleanName,
      'cadence': parsed.name,
      'target': target,
      'archived': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await refreshAll();
    return id;
  }

  /// Updates a habit in place. A no-op for an unknown id (the row was deleted
  /// from under the editor), matching [updateMeal]'s contract.
  Future<void> updateHabit(int id,
      {String? name, String? cadence, int? target, bool? archived}) async {
    final values = <String, Object?>{};
    if (name != null) {
      final cleanName = name.trim();
      if (cleanName.isEmpty) {
        throw const StoreException('Habit name cannot be empty.');
      }
      values['name'] = cleanName;
    }
    if (cadence != null) {
      final parsed = HabitCadence.parse(cadence);
      if (parsed == null) {
        throw StoreException(
            'Unknown habit cadence "$cadence". Use daily, weekly or monthly.');
      }
      values['cadence'] = parsed.name;
    }
    if (target != null) {
      if (target < 1) {
        throw const StoreException(
            'Habit target must be at least 1 day per period.');
      }
      values['target'] = target;
    }
    if (archived != null) values['archived'] = archived ? 1 : 0;
    if (values.isEmpty) return;
    await db.update('habits', values, where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  /// Deletes a habit and its completion history. The child rows are removed
  /// explicitly rather than relying on the declared cascade, so the delete is
  /// correct even if `PRAGMA foreign_keys` were ever off.
  Future<void> deleteHabit(int id) async {
    await db
        .delete('habit_completions', where: 'habit_id = ?', whereArgs: [id]);
    await db.delete('habits', where: 'id = ?', whereArgs: [id]);
    await refreshAll();
  }

  /// Checks [day] off ([done] true) or clears it (false) for [habitId].
  ///
  /// Idempotent: checking an already-checked day replaces the row instead of
  /// failing on the UNIQUE(habit_id, day) constraint. Throws [StoreException]
  /// when the habit no longer exists, so a coach call cannot write an orphan
  /// completion that the FK would reject.
  Future<void> setHabitCompletion(int habitId, DateTime day, bool done) async {
    final exists = await db.query('habits',
        columns: ['id'], where: 'id = ?', whereArgs: [habitId], limit: 1);
    if (exists.isEmpty) {
      throw StoreException('No habit with id $habitId.');
    }
    final key = habitDayKey(day);
    if (done) {
      await db.insert(
          'habit_completions',
          {
            'habit_id': habitId,
            'day': key,
            'count': 1,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await db.delete('habit_completions',
          where: 'habit_id = ? AND day = ?', whereArgs: [habitId, key]);
    }
    await refreshAll();
  }

  /// Flips [day] for [habitId] and returns the new state (true = checked off).
  Future<bool> toggleHabitCompletion(int habitId, DateTime day) async {
    final key = habitDayKey(day);
    final existing = await db.query('habit_completions',
        columns: ['id'],
        where: 'habit_id = ? AND day = ?',
        whereArgs: [habitId, key],
        limit: 1);
    final done = existing.isEmpty;
    await setHabitCompletion(habitId, day, done);
    return done;
  }

  /// Completion history for one habit, optionally bounded by a local day range
  /// ([from] inclusive, [to] exclusive). Day keys are zero-padded ISO dates, so
  /// string comparison is chronological.
  Future<List<HabitCompletion>> habitCompletionsFor(int habitId,
      {DateTime? from, DateTime? to}) async {
    final where = <String>['habit_id = ?'];
    final args = <Object?>[habitId];
    if (from != null) {
      where.add('day >= ?');
      args.add(habitDayKey(from));
    }
    if (to != null) {
      where.add('day < ?');
      args.add(habitDayKey(to));
    }
    final rows = await db.query('habit_completions',
        where: where.join(' AND '), whereArgs: args, orderBy: 'day');
    return rows.map(HabitCompletion.fromMap).toList();
  }

  /// Every habit's completions inside a local day range ([from] inclusive,
  /// [to] exclusive), grouped by habit id. One query for the coach's status
  /// tool instead of one per habit.
  Future<Map<int, List<HabitCompletion>>> habitCompletionsInRange(
      DateTime from, DateTime to) async {
    final rows = await db.query('habit_completions',
        where: 'day >= ? AND day < ?',
        whereArgs: [habitDayKey(from), habitDayKey(to)],
        orderBy: 'habit_id, day');
    final grouped = <int, List<HabitCompletion>>{};
    for (final row in rows.map(HabitCompletion.fromMap)) {
      grouped.putIfAbsent(row.habitId, () => []).add(row);
    }
    return grouped;
  }

  // ------------------------------------------------------------ helpers

  Future<List<Map<String, Object?>>> finishedWorkoutRows(int from, int to) =>
      db.rawQuery('''
      SELECT w.id, w.name, w.started_at, w.ended_at FROM workouts w
      WHERE w.ended_at IS NOT NULL AND w.started_at >= ? AND w.started_at < ?
      ORDER BY w.started_at''', [from, to]);

  Future<List<Map<String, Object?>>> workoutExerciseRows(int workoutId) =>
      db.rawQuery('''
      SELECT e.name, e.muscle_group, s.weight_kg, s.reps, s.is_warmup, s.completed_at
      FROM workout_exercises we
      JOIN exercises e ON e.id = we.exercise_id
      JOIN workout_sets s ON s.workout_exercise_id = we.id
      WHERE we.workout_id = ?''', [workoutId]);
}
