-- Reproduces the non-health tables the five hot-path plans touch (baseline
-- audit m1) and prints those plans before and after the v8/v9 indexes. It is
-- not the full schema: health_daily and health_sync_state are omitted because
-- none of the five plans reference them. Run with:
--   sqlite3 :memory: < tool/plan_check.sql
CREATE TABLE exercises(
  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, muscle_group TEXT NOT NULL,
  equipment TEXT NOT NULL DEFAULT '', is_custom INTEGER NOT NULL DEFAULT 0);
CREATE TABLE workouts(
  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, started_at INTEGER NOT NULL,
  ended_at INTEGER, note TEXT);
CREATE TABLE workout_exercises(
  id INTEGER PRIMARY KEY AUTOINCREMENT, workout_id INTEGER NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
  exercise_id INTEGER NOT NULL, position INTEGER NOT NULL);
CREATE TABLE workout_sets(
  id INTEGER PRIMARY KEY AUTOINCREMENT, workout_exercise_id INTEGER NOT NULL
  REFERENCES workout_exercises(id) ON DELETE CASCADE,
  position INTEGER NOT NULL, weight_kg REAL NOT NULL, reps INTEGER NOT NULL,
  completed_at INTEGER, is_warmup INTEGER NOT NULL DEFAULT 0);
CREATE TABLE meals(
  id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, image_path TEXT NOT NULL DEFAULT '',
  dish TEXT NOT NULL, description TEXT, calories REAL NOT NULL, protein REAL NOT NULL,
  carbs REAL NOT NULL, fat REAL NOT NULL,
  foods_json TEXT NOT NULL DEFAULT '[]', is_auto INTEGER NOT NULL DEFAULT 0);
CREATE TABLE accounts(
  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, balance REAL NOT NULL,
  currency TEXT NOT NULL DEFAULT 'USD', updated_at INTEGER NOT NULL);
CREATE TABLE moods(
  id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, mood INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '');
CREATE TABLE meditations(
  id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, minutes INTEGER NOT NULL, kind TEXT NOT NULL DEFAULT 'Meditation');
CREATE TABLE thought_records(
  id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, situation TEXT NOT NULL,
  thought TEXT NOT NULL, reframe TEXT NOT NULL DEFAULT '');
CREATE TABLE balance_snapshots(
  id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER NOT NULL,
  balance REAL NOT NULL, taken_at INTEGER NOT NULL);
CREATE TABLE reminders(
  id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, due_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS health_records(
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
  synced_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_health_records_type_date ON health_records(type, date_from);
CREATE INDEX IF NOT EXISTS idx_health_records_date ON health_records(date_from);

.print '=== workout_sets by workout_exercise_id (store.dart:408)'
EXPLAIN QUERY PLAN SELECT * FROM workout_sets WHERE workout_exercise_id = 1 ORDER BY position;
.print '=== workout_exercises by workout_id (store.dart:401)'
EXPLAIN QUERY PLAN SELECT * FROM workout_exercises WHERE workout_id = 1 ORDER BY position;
.print '=== meals by timestamp (store.dart:284)'
EXPLAIN QUERY PLAN SELECT * FROM meals ORDER BY timestamp DESC;
.print '=== balance_snapshots join (store.dart:297)'
EXPLAIN QUERY PLAN SELECT s.account_id, s.balance, s.taken_at, a.type
  FROM balance_snapshots s JOIN accounts a ON a.id = s.account_id ORDER BY s.taken_at;
.print '=== reminders due_at (store.dart:317)'
EXPLAIN QUERY PLAN SELECT * FROM reminders WHERE due_at > 0 ORDER BY due_at;

-- v8 migration (lib/data/store.dart _createV8Indexes)
CREATE INDEX IF NOT EXISTS idx_workout_sets_workout_exercise_id ON workout_sets(workout_exercise_id);
CREATE INDEX IF NOT EXISTS idx_workout_exercises_workout ON workout_exercises(workout_id);
CREATE INDEX IF NOT EXISTS idx_meals_timestamp ON meals(timestamp);
CREATE INDEX IF NOT EXISTS idx_balance_snapshots_account_taken ON balance_snapshots(account_id, taken_at);
CREATE INDEX IF NOT EXISTS idx_reminders_due_at ON reminders(due_at);

.print ''
.print '=== AFTER v8 ==='
.print '=== workout_sets by workout_exercise_id (store.dart:408)'
EXPLAIN QUERY PLAN SELECT * FROM workout_sets WHERE workout_exercise_id = 1 ORDER BY position;
.print '=== workout_exercises by workout_id (store.dart:401)'
EXPLAIN QUERY PLAN SELECT * FROM workout_exercises WHERE workout_id = 1 ORDER BY position;
.print '=== meals by timestamp (store.dart:284)'
EXPLAIN QUERY PLAN SELECT * FROM meals ORDER BY timestamp DESC;
.print '=== balance_snapshots join (store.dart:297)'
EXPLAIN QUERY PLAN SELECT s.account_id, s.balance, s.taken_at, a.type
  FROM balance_snapshots s JOIN accounts a ON a.id = s.account_id ORDER BY s.taken_at;
.print '=== reminders due_at (store.dart:317)'
EXPLAIN QUERY PLAN SELECT * FROM reminders WHERE due_at > 0 ORDER BY due_at;

-- v9 migration (lib/data/store.dart _createV9Indexes)
CREATE INDEX IF NOT EXISTS idx_balance_snapshots_taken ON balance_snapshots(taken_at, account_id, balance);

.print ''
.print '=== AFTER v9 ==='
.print '=== balance_snapshots join (store.dart:297)'
EXPLAIN QUERY PLAN SELECT s.account_id, s.balance, s.taken_at, a.type
  FROM balance_snapshots s JOIN accounts a ON a.id = s.account_id ORDER BY s.taken_at;
.print '=== deleteAccount (store.dart:696)'
EXPLAIN QUERY PLAN DELETE FROM balance_snapshots WHERE account_id = 7;
