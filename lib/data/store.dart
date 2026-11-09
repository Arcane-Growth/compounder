import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/activity.dart';
import '../domain/domain.dart';
import '../domain/habits.dart';
import '../domain/plan.dart';
import '../subscription/constants.dart';
import '../subscription/entitlement.dart';
import '../subscription/gateway.dart';
import '../subscription/secrets.dart';
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

/// One exercise's personal-record outcome for a session: the best e1RM the
/// user hit this session, the best they had before it, and the difference.
///
/// [previousBestKg] is 0 when the exercise had no prior finished session, in
/// which case the session established the baseline.
class PrSummary {
  final int exerciseId;
  final String exerciseName;
  final double previousBestKg;
  final double newBestKg;

  const PrSummary({
    required this.exerciseId,
    required this.exerciseName,
    required this.previousBestKg,
    required this.newBestKg,
  });

  double get deltaKg => newBestKg - previousBestKg;

  /// True when this session established the exercise's first baseline.
  bool get isBaseline => previousBestKg <= 0;
}

/// Single source of truth: owns the database, cached lists and settings.
class AppStore extends ChangeNotifier implements DeviceTokenStore {
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

  /// Gateway API key issued after a verified store purchase. Loaded from the
  /// secret store at startup; never written to SharedPreferences directly.
  String? _gatewayApiKey;
  Entitlement? _entitlement;
  String? _deviceToken;
  bool _deviceTokenRegistered = false;

  static Future<AppStore> open(SharedPreferences prefs,
      {String? path, SecretStore? secretStore}) async {
    path ??= p.join(await getDatabasesPath(), 'compounder.db');
    final db = await openDatabase(path,
        version: 13,
        onConfigure: _configureSchema,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema);
    final store = AppStore._(db, prefs);
    await store.refreshAll();
    // Subscription state is best-effort: a keystore failure must not stop the
    // app from opening.
    try {
      final secrets = secretStore ?? PrefsSecretStore(prefs);
      store._gatewayApiKey = await secrets.read(gatewayApiKeySecret);
    } catch (_) {
      store._gatewayApiKey = null;
    }
    store._entitlement = Entitlement.decodeCache(prefs.getString(prefEntitlement));
    store._deviceToken = prefs.getString(prefDeviceToken);
    store._deviceTokenRegistered =
        prefs.getBool(prefDeviceTokenRegistered) ?? false;
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
      completed_at INTEGER, is_warmup INTEGER NOT NULL DEFAULT 0,
      is_pr INTEGER NOT NULL DEFAULT 0, pr_e1rm_kg REAL)''');
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
    await _createV11Indexes(db);
    await _createV13Tables(db);
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
    if (oldVersion < 11) {
      // The activity heatmap's aggregate queries filtered on a timestamp (or
      // day) column with no index, so every refresh full-scanned workouts,
      // moods, meditations, thought_records and habit_completions. These
      // indexes turn each scan into a bounded range search. Indexes hold no
      // user data, so the step is additive and safe to re-run.
      //
      // The GROUP BY still builds a temp B-tree: the group key is a computed
      // local-date expression (`date(...)`), which an index cannot satisfy.
      // That sort is bounded by the rows inside the requested window, not by
      // the table size, so it is accepted rather than widened into a
      // composite index.
      await _createV11Indexes(db);
    }
    if (oldVersion < 12) {
      // Personal records. Two additive columns on workout_sets: the flag and
      // the e1RM snapshot it was set at. Every existing row keeps its weight,
      // reps and completion state; the defaults mark them all as non-PR, so a
      // v11 history can never show a false PR. `_addColumnIfMissing` makes the
      // step safe to re-run on a partially applied migration.
      await _addColumnIfMissing(
          db, 'workout_sets', 'is_pr', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'workout_sets', 'pr_e1rm_kg', 'REAL');
    }
    if (oldVersion < 13) {
      // Day planner. Purely additive: one new table and its index, no existing
      // row is touched, so a v12 install keeps every workout, meal, account,
      // habit and health record. Existing days simply have no plan. IF NOT
      // EXISTS makes the step safe to re-run on a partially applied migration.
      await _createV13Tables(db);
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

  /// Schema v11: range indexes for the activity heatmap's aggregate queries.
  /// Idempotent, additive only.
  ///
  /// `habit_completions` already has an implicit `UNIQUE(habit_id, day)` index,
  /// but its leading column is `habit_id`, so a day-range query cannot use it.
  /// The explicit day-leading index serves the heatmap's range scan.
  static Future<void> _createV11Indexes(Database db) async {
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_workouts_started_at ON workouts(started_at)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_moods_timestamp ON moods(timestamp)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_meditations_timestamp ON meditations(timestamp)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_thought_records_timestamp ON thought_records(timestamp)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_habit_completions_day ON habit_completions(day)');
  }

  /// Schema v13: the day planner table. Idempotent, additive only.
  ///
  /// `plan_blocks.day` is a local `YYYY-MM-DD` key rather than an epoch
  /// timestamp, for the same reason `habit_completions.day` is: a block belongs
  /// to a calendar day, and a timestamp would shift across timezones and DST.
  /// `start_min`/`end_min` are minutes from local midnight, so a block carries
  /// no timezone at all. The `(day, start_min)` index serves the planner's
  /// chronological day query and the heatmap's per-day plan count.
  static Future<void> _createV13Tables(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS plan_blocks(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      day TEXT NOT NULL,
      title TEXT NOT NULL,
      start_min INTEGER NOT NULL,
      end_min INTEGER NOT NULL,
      done INTEGER NOT NULL DEFAULT 0,
      done_at INTEGER,
      created_at INTEGER NOT NULL,
      position INTEGER NOT NULL DEFAULT 0)''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_plan_blocks_day_start ON plan_blocks(day, start_min)');
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

  // ------------------------------------------------------ Compounder AI

  /// Which AI source the coach and vision calls use. Defaults to
  /// [AiSource.byo], so every existing install keeps working with no
  /// migration.
  AiSource get aiSource =>
      prefs.getString(prefAiSource) == aiSourceCompounder
          ? AiSource.compounder
          : AiSource.byo;

  Future<void> setAiSource(AiSource source) async {
    await prefs.setString(prefAiSource,
        source == AiSource.compounder ? aiSourceCompounder : 'byo');
    notifyListeners();
  }

  /// API key issued by the gateway. Held in memory and in the secret store;
  /// this getter never touches disk.
  String? get gatewayApiKey => _gatewayApiKey;

  Future<void> saveGatewayKey(String? key) async {
    _gatewayApiKey = key;
    notifyListeners();
  }

  /// Last entitlement the gateway confirmed, cached so the app can show the
  /// plan offline.
  Entitlement? get entitlement => _entitlement;

  Future<void> saveEntitlement(Entitlement entitlement) async {
    _entitlement = entitlement;
    await prefs.setString(prefEntitlement, entitlement.encodeCache());
    notifyListeners();
  }

  @override
  String? get deviceToken => _deviceToken;

  @override
  bool get deviceTokenRegistered => _deviceTokenRegistered;

  /// Persists a freshly minted device token. It is unconfirmed until the
  /// gateway accepts it, so [deviceTokenRegistered] resets.
  @override
  Future<void> saveDeviceToken(String token) async {
    _deviceToken = token;
    _deviceTokenRegistered = false;
    await prefs.setString(prefDeviceToken, token);
    await prefs.setBool(prefDeviceTokenRegistered, false);
  }

  @override
  Future<void> markDeviceTokenRegistered() async {
    _deviceTokenRegistered = true;
    await prefs.setBool(prefDeviceTokenRegistered, true);
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

  /// Audible rest-timer cues (5s warning tick and the "go" tone). On by
  /// default; the user can mute them in Settings.
  bool get restSoundsEnabled => prefs.getBool('restSoundsEnabled') ?? true;
  Future<void> setRestSoundsEnabled(bool enabled) async {
    await prefs.setBool('restSoundsEnabled', enabled);
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
    await _recomputePrFlagsForEntry(entryId);
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
    await _recomputePrFlagsForSet(id);
    await refreshAll();
  }

  Future<void> deleteSetRow(int id) async {
    final entryId = await _entryIdForSet(id);
    await db.delete('workout_sets', where: 'id = ?', whereArgs: [id]);
    if (entryId != null) await _recomputePrFlagsForEntry(entryId);
    await refreshAll();
  }

  Future<void> removeExercise(int entryId) async {
    final workoutId = await _workoutIdForEntry(entryId);
    await db.delete('workout_sets',
        where: 'workout_exercise_id = ?', whereArgs: [entryId]);
    await db.delete('workout_exercises', where: 'id = ?', whereArgs: [entryId]);
    if (workoutId != null) await _recomputePrFlags(workoutId);
    await refreshAll();
  }

  // ------------------------------------------------------ personal records

  /// Best e1RM for [exerciseId] across sessions that finished before
  /// [workoutId]. Zero when the exercise has no prior history.
  ///
  /// "Prior" is bounded by the target session's finish time, tie-broken by id,
  /// so a historical summary never sees a later session's numbers: the
  /// previous best has to be the baseline the user actually faced at the time,
  /// not a value that moves forward as they keep training. A session that is
  /// still in progress has no finish time, so every finished session counts as
  /// prior for it.
  ///
  /// Only performed sets count: warm-ups, zero-rep placeholders and sets that
  /// were never completed are skipped, mirroring the current-session exclusion
  /// in [_recomputePrFlags].
  Future<double> _priorBestKg(
      DatabaseExecutor ex, int exerciseId, int workoutId) async {
    final target = await ex.query('workouts',
        columns: ['ended_at'],
        where: 'id = ?',
        whereArgs: [workoutId],
        limit: 1);
    final endedAt = target.isEmpty ? null : target.first['ended_at'] as int?;
    final args = <Object?>[exerciseId, workoutId];
    var scope = '';
    if (endedAt != null) {
      scope = 'AND (w.ended_at < ? OR (w.ended_at = ? AND w.id < ?))';
      args.addAll([endedAt, endedAt, workoutId]);
    }
    final rows = await ex.rawQuery('''
        SELECT s.weight_kg, s.reps FROM workouts w
        JOIN workout_exercises we ON we.workout_id = w.id
        JOIN workout_sets s ON s.workout_exercise_id = we.id
        WHERE we.exercise_id = ? AND w.ended_at IS NOT NULL AND w.id != ?
          AND s.is_warmup = 0 AND s.reps >= 1 AND s.completed_at IS NOT NULL
          $scope''', args);
    return formatE1rm(e1rmMaxOf(rows
        .map((r) => (
              (r['weight_kg'] as num).toDouble(),
              r['reps'] as int,
            ))
        .toList()));
  }

  Future<int?> _workoutIdForEntry(int entryId) async {
    final rows = await db.query('workout_exercises',
        columns: ['workout_id'],
        where: 'id = ?',
        whereArgs: [entryId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['workout_id'] as int;
  }

  Future<int?> _entryIdForSet(int setId) async {
    final rows = await db.query('workout_sets',
        columns: ['workout_exercise_id'],
        where: 'id = ?',
        whereArgs: [setId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['workout_exercise_id'] as int;
  }

  Future<void> _recomputePrFlagsForSet(int setId) async {
    final entryId = await _entryIdForSet(setId);
    if (entryId != null) await _recomputePrFlagsForEntry(entryId);
  }

  Future<void> _recomputePrFlagsForEntry(int entryId) async {
    final workoutId = await _workoutIdForEntry(entryId);
    if (workoutId != null) await _recomputePrFlags(workoutId);
  }

  /// Recomputes and persists the PR flag for every set in [workoutId].
  ///
  /// The flag is a function of the whole session: a set is a PR only when it
  /// beats the prior-session best *and* every earlier set in this session, so
  /// editing or deleting one set can change the verdict for the sets after it.
  /// Recomputing the session in one pass keeps the stored flags consistent
  /// with the detection rule instead of drifting from it.
  ///
  /// The same exercise can appear more than once in a workout, so the session
  /// baseline is accumulated across every entry for that exercise, ordered by
  /// when each set was performed (insertion order breaks ties). Building it per
  /// entry would let a lighter set in a later entry claim a PR it does not own.
  ///
  /// Only completed sets are flagged: an untouched placeholder is not a
  /// performed set, and completing it is what triggers the celebration.
  ///
  /// Runs in a transaction so a mid-pass failure cannot leave the session with
  /// a half-updated set of flags.
  Future<void> _recomputePrFlags(int workoutId) async {
    await db.transaction((txn) async {
      final entries = await txn.query('workout_exercises',
          where: 'workout_id = ?',
          whereArgs: [workoutId],
          orderBy: 'position, id');
      final byExercise = <int, List<WorkoutSet>>{};
      for (final entry in entries) {
        final rows = await txn.query('workout_sets',
            where: 'workout_exercise_id = ?', whereArgs: [entry['id'] as int]);
        byExercise
            .putIfAbsent(entry['exercise_id'] as int, () => <WorkoutSet>[])
            .addAll(rows.map(WorkoutSet.fromMap));
      }
      for (final group in byExercise.entries) {
        final prior = await _priorBestKg(txn, group.key, workoutId);
        final sets = [...group.value]..sort((a, b) {
            final ac = a.completedAt;
            final bc = b.completedAt;
            if (ac != null && bc != null && ac != bc) return ac.compareTo(bc);
            if (ac == null && bc != null) return 1;
            if (ac != null && bc == null) return -1;
            return a.id.compareTo(b.id);
          });
        final earlier = <(double, int)>[];
        for (final set in sets) {
          final assessment = assessPr(
            weightKg: set.weightKg,
            reps: set.reps,
            isWarmup: set.isWarmup,
            priorBestKg: prior,
            earlierSets: earlier,
          );
          final isPr = set.completedAt != null && assessment.isPr;
          final prE1rm = isPr ? assessment.e1rmKg : null;
          if (set.isPr != isPr || set.prE1rmKg != prE1rm) {
            await txn.update(
                'workout_sets', {'is_pr': isPr ? 1 : 0, 'pr_e1rm_kg': prE1rm},
                where: 'id = ?', whereArgs: [set.id]);
          }
          if (!set.isWarmup && set.reps >= 1 && set.weightKg >= 0) {
            // Only performed sets count as "earlier in this session": a heavier
            // set that is still an untouched placeholder must not suppress the
            // PR for a set the user actually completed.
            if (set.completedAt != null) earlier.add((set.weightKg, set.reps));
          }
        }
      }
    });
  }

  /// The personal records set in [workoutId], one row per exercise, with the
  /// prior-session best and the delta.
  ///
  /// Reads the persisted flags rather than recomputing, so the summary and the
  /// history agree with what the user was shown at the time.
  Future<List<PrSummary>> prSummary(int workoutId) async {
    final rows = await db.rawQuery('''
        SELECT we.exercise_id, e.name, s.pr_e1rm_kg
        FROM workout_exercises we
        JOIN exercises e ON e.id = we.exercise_id
        JOIN workout_sets s ON s.workout_exercise_id = we.id
        WHERE we.workout_id = ? AND s.is_pr = 1 AND s.pr_e1rm_kg IS NOT NULL
        ORDER BY we.position, s.position, s.id''', [workoutId]);
    final byExercise = <int, ({String name, double best})>{};
    for (final r in rows) {
      final id = r['exercise_id'] as int;
      final value = (r['pr_e1rm_kg'] as num).toDouble();
      final existing = byExercise[id];
      if (existing == null || value > existing.best) {
        byExercise[id] = (name: r['name'] as String, best: value);
      }
    }
    final summaries = <PrSummary>[];
    for (final entry in byExercise.entries) {
      final previous = await _priorBestKg(db, entry.key, workoutId);
      summaries.add(PrSummary(
        exerciseId: entry.key,
        exerciseName: entry.value.name,
        previousBestKg: previous,
        newBestKg: entry.value.best,
      ));
    }
    return summaries;
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
               (SELECT COUNT(*) FROM workout_exercises we WHERE we.workout_id = w.id) exercise_count,
               (SELECT COUNT(*) FROM workout_sets s2
                  JOIN workout_exercises we2 ON we2.id = s2.workout_exercise_id
                 WHERE we2.workout_id = w.id AND s2.is_pr = 1) pr_count
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
              prCount: (r['pr_count'] as num?)?.toInt() ?? 0,
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
  /// [to] exclusive), grouped by habit id. One query instead of one per habit.
  ///
  /// The coach's status tool reads the in-memory cache, so this serves range
  /// reporting and the regression tests rather than the tool loop.
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

  // ------------------------------------------------------------ day planner

  /// The blocks planned for [day]'s local day, in chronological order.
  ///
  /// Ordered by start time, then the stored position, then id, so two blocks
  /// that start at the same minute keep a deterministic order.
  Future<List<PlanBlock>> planBlocksForDay(DateTime day) async {
    final rows = await db.query('plan_blocks',
        where: 'day = ?',
        whereArgs: [planDayKey(day)],
        orderBy: 'start_min, position, id');
    return rows.map(PlanBlock.fromMap).toList();
  }

  /// The block with [id], or null when it was deleted.
  ///
  /// The coach's update/delete tools need the stored row to validate a partial
  /// edit against the merged values; the planner screen always has the block it
  /// is editing, so this exists for the tool surface.
  Future<PlanBlock?> planBlockById(int id) async {
    final rows = await db
        .query('plan_blocks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : PlanBlock.fromMap(rows.single);
  }

  /// Creates a block on [day]'s plan. Throws [StoreException] when the title is
  /// blank or too long, or the times are out of range or not increasing, so the
  /// planner dialog and any future coach tool share one validation boundary.
  Future<int> createPlanBlock({
    required DateTime day,
    required String title,
    required int startMin,
    required int endMin,
  }) async {
    final error =
        planBlockError(title: title, startMin: startMin, endMin: endMin);
    if (error != null) throw StoreException(error);
    final key = planDayKey(day);
    // MAX(position)+1 is not atomic: two concurrent creates on the same day can
    // share a position. Harmless in a single-user app — the id tie-break in
    // `chronological` keeps the order deterministic.
    final posRows = await db.rawQuery(
        'SELECT MAX(position) m FROM plan_blocks WHERE day = ?', [key]);
    final position = ((posRows.first['m'] as int?) ?? -1) + 1;
    final id = await db.insert('plan_blocks', {
      'day': key,
      'title': title.trim(),
      'start_min': startMin,
      'end_min': endMin,
      'done': 0,
      'done_at': null,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'position': position,
    });
    notifyListeners();
    return id;
  }

  /// Updates a block in place. A no-op for an unknown id (the row was deleted
  /// from under the editor), matching [updateHabit]'s contract.
  ///
  /// Validation runs against the merged row, so changing only the end time
  /// cannot produce an end before the stored start.
  ///
  /// [done] is applied in the same UPDATE as the editable fields, so the coach's
  /// "move and check off" call cannot half-apply (review Nit 4).
  Future<void> updatePlanBlock(int id,
      {String? title, int? startMin, int? endMin, bool? done}) async {
    final rows =
        await db.query('plan_blocks', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    final current = PlanBlock.fromMap(rows.single);
    final nextTitle = title ?? current.title;
    final nextStart = startMin ?? current.startMin;
    final nextEnd = endMin ?? current.endMin;
    final error = planBlockError(
        title: nextTitle, startMin: nextStart, endMin: nextEnd);
    if (error != null) throw StoreException(error);
    await db.update(
        'plan_blocks',
        {
          'title': nextTitle.trim(),
          'start_min': nextStart,
          'end_min': nextEnd,
          if (done != null) 'done': done ? 1 : 0,
          if (done != null)
            'done_at': done ? DateTime.now().millisecondsSinceEpoch : null,
        },
        where: 'id = ?',
        whereArgs: [id]);
    notifyListeners();
  }

  /// Marks a block done ([done] true) or clears it. `done_at` is stamped from
  /// the clock on completion and cleared on undo.
  Future<void> setPlanBlockDone(int id, bool done) async {
    await db.update(
        'plan_blocks',
        {
          'done': done ? 1 : 0,
          'done_at': done ? DateTime.now().millisecondsSinceEpoch : null,
        },
        where: 'id = ?',
        whereArgs: [id]);
    notifyListeners();
  }

  Future<void> deletePlanBlock(int id) async {
    await db.delete('plan_blocks', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  // ------------------------------------------------------------ helpers

  /// Per-local-day pillar activity for the half-open local-day range
  /// [from, to): the heatmap's data source.
  ///
  /// One grouped query per pillar source — workouts, meals, the three
  /// mood/mind tables, habit completions and plan blocks — so the cost is a
  /// fixed five queries regardless of how many days the range spans (no
  /// per-day loop, no N+1). Timestamped tables are bucketed with SQLite's
  /// `date(..., 'localtime')`, which uses the same OS timezone as Dart's
  /// `DateTime`, so a row at 23:59 local lands on that day and a row at 00:00
  /// lands on the next one. Habit completions and plan blocks are already keyed
  /// by local `YYYY-MM-DD`, the same convention [habitDayKey] produces.
  ///
  /// Days with no activity are absent from the map; callers treat a missing
  /// key as intensity 0. Rows with `count <= 0` are ignored, matching
  /// [habitCompletedDays].
  Future<Map<String, PillarDay>> dailyPillarActivity(
      DateTime from, DateTime to) async {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day);
    if (!end.isAfter(start)) return {};
    final fromMs = start.millisecondsSinceEpoch;
    final toMs = end.millisecondsSinceEpoch;
    final fromKey = habitDayKey(start);
    final toKey = habitDayKey(end);

    final workoutRows = await db.rawQuery('''
      SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day,
             COUNT(*) AS c
      FROM workouts
      WHERE started_at >= ? AND started_at < ?
      GROUP BY day''', [fromMs, toMs]);
    final nutritionRows = await db.rawQuery('''
      SELECT date(timestamp / 1000, 'unixepoch', 'localtime') AS day,
             COUNT(*) AS c
      FROM meals
      WHERE timestamp >= ? AND timestamp < ?
      GROUP BY day''', [fromMs, toMs]);
    final mindRows = await db.rawQuery('''
      SELECT day, COUNT(*) AS c FROM (
        SELECT date(timestamp / 1000, 'unixepoch', 'localtime') AS day
        FROM moods WHERE timestamp >= ? AND timestamp < ?
        UNION ALL
        SELECT date(timestamp / 1000, 'unixepoch', 'localtime') AS day
        FROM meditations WHERE timestamp >= ? AND timestamp < ?
        UNION ALL
        SELECT date(timestamp / 1000, 'unixepoch', 'localtime') AS day
        FROM thought_records WHERE timestamp >= ? AND timestamp < ?
      )
      GROUP BY day''', [fromMs, toMs, fromMs, toMs, fromMs, toMs]);
    final habitRows = await db.rawQuery('''
      SELECT day, COUNT(*) AS c
      FROM habit_completions
      WHERE day >= ? AND day < ? AND count > 0
      GROUP BY day''', [fromKey, toKey]);
    final planRows = await db.rawQuery('''
      SELECT day, COUNT(*) AS c
      FROM plan_blocks
      WHERE day >= ? AND day < ?
      GROUP BY day''', [fromKey, toKey]);

    final counts = <String, List<int>>{};
    List<int> bucket(String day) =>
        counts.putIfAbsent(day, () => List<int>.filled(5, 0));
    for (final row in workoutRows) {
      final day = row['day'] as String?;
      if (day == null) continue;
      bucket(day)[0] += (row['c'] as int?) ?? 0;
    }
    for (final row in nutritionRows) {
      final day = row['day'] as String?;
      if (day == null) continue;
      bucket(day)[1] += (row['c'] as int?) ?? 0;
    }
    for (final row in mindRows) {
      final day = row['day'] as String?;
      if (day == null) continue;
      bucket(day)[2] += (row['c'] as int?) ?? 0;
    }
    for (final row in habitRows) {
      final day = row['day'] as String?;
      if (day == null) continue;
      bucket(day)[3] += (row['c'] as int?) ?? 0;
    }
    for (final row in planRows) {
      final day = row['day'] as String?;
      if (day == null) continue;
      bucket(day)[4] += (row['c'] as int?) ?? 0;
    }

    return {
      for (final entry in counts.entries)
        entry.key: PillarDay(
          day: entry.key,
          workoutCount: entry.value[0],
          nutritionCount: entry.value[1],
          mindCount: entry.value[2],
          habitCount: entry.value[3],
          planCount: entry.value[4],
        ),
    };
  }

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
