# Gate review — habit tracker (schema v10, CRUD, coach tools, backup)

- **Task**: 3639e439
- **HEAD reviewed**: `f494428` (feature `9559cea`, drawer guard `f494428`)
- **Worktree**: `/home/barry/.cache/review-wt/habits-gate` (pinned, not the shared checkout)
- **Date**: 2026-11-08
- **Verdict**: **APPROVE WITH FIXES** — no blockers, no data-loss or security defects. Four minors, all safe to defer to the queued backlog task.

## What I verified (commands + results)

1. **Hygiene** — `flutter analyze` → `No issues found! (ran in 2.0s)`. Full `flutter test` with `TMPDIR=/home/barry/.cache/flutter-tmp` → `00:10 +286: All tests passed!`. Targeted habit/drawer suites → `00:06 +54: All tests passed!`. No `print(` in `lib/` (only `debugPrint`); no TODO/FIXME/XXX in new files. Commits are path-scoped and touch only feature files.
2. **v9→v10 migration on real data** — copied `/home/barry/compounder-db-backup-2026-11-07/pre/databases/compounder.db` (`user_version=9`, `health_records=55958`), ran the production `AppStore.open` upgrade. Result: `user_version=10`, every v9 table schema byte-identical, row counts unchanged (health_records still 55958), `PRAGMA integrity_check` = ok, `PRAGMA foreign_key_check` empty, new habit tables usable. Migration is additive; no in-place edit of v9 objects.
3. **Non-vacuous regression guards** — reverted each validation and quoted the failure:
   - `_safeText` → `(args[key] as String?)?.trim() ?? ''`: `create_habit rejects a missing name, bad cadence and bad target` failed with `type 'int' is not a subtype of type 'String?' in type cast` at `lib/coach/tools.dart:743` → `845` → `test/habits_coach_test.dart:101`.
   - `parseHabitDay` round-trip check → `return DateTime(year, month, day);`: `rejects malformed and impossible dates` failed with `Expected: null Actual: DateTime:<2026-03-02>` for `2026-02-30` at `test/habits_test.dart:137`.
   - `_int` → `args[key] as int?`: `habit_status rejects a bad date and an unknown habit id` failed with `type 'String' is not a subtype of type 'int?' in type cast` at `lib/coach/tools.dart:58` → `1096` → `test/habits_coach_test.dart:143`.
   All three restored; suite green again.
4. **Backup round-trip / edge cases** — format-4 file with habits but no `habitCompletions` key imports; orphan completion fails the import and rolls back; unicode/quote habit names round-trip; full-replace import replaces local habits; format-2 and format-3 imports (no habit keys) clear local habits without error.
5. **Cadence/streak edge probes** — weekly streak across a month boundary; unfinished current week preserves the prior streak; archived habits excluded from the active checklist but keep history; delete cascades completions; toggle idempotency (double toggle returns to absent, no duplicate row).
6. **Query plan** — `EXPLAIN QUERY PLAN` on a populated v10 DB: per-habit history uses `(habit_id=? AND day>? AND day<?)`; the range query uses the same index via `ANY(habit_id)` skip-scan. The schema comment claiming the implicit index serves both queries is accurate.

## Findings (severity order)

### Minor 1 — `create_habit` silently coerces a string `target` to 1
`lib/coach/tools.dart` `CreateHabitTool.run`: `final target = _int(args, 'target') ?? 1;`. `_int` returns null for a JSON string (`"target": "3"`), so the habit is created with target 1 and the tool reports `target: 1`. `UpdateHabitTool` correctly errors on a non-int target, so the two tools disagree. LLMs frequently emit numeric strings.
Fix: `final target = _int(args, 'target'); if (target == null && args['target'] != null) return _jsonError('target must be an integer');` then default to 1 only when the key is absent. Same for `summarize`.

### Minor 2 — dead code / stale doc comment
- `HabitProgress.fraction` (`lib/domain/habits.dart:118`) is never read.
- `Habit.toMap` and `HabitCompletion.toMap` are unused in `lib/` (the store writes raw maps; `Reminder` has no `toMap` at all, so this is not an established convention).
- `habitCompletionsFor` / `habitCompletionsInRange` are referenced only by tests; the doc comment on `habitCompletionsInRange` says "for the coach's status tool", but `HabitStatusTool` reads the in-memory cache instead.
Fix: delete `fraction` and the two `toMap`s, or wire them in; correct the doc comment.

### Minor 3 — UI callbacks drop errors and can throw after dismissal
`lib/ui/habits.dart`: `onChanged: (_) => store.toggleHabitCompletion(...)` and the popup-menu `store.updateHabit(...)` are unawaited, so a `StoreException` is silently swallowed. In `_editHabit`, `setDialogState` runs after `await store.createHabit/updateHabit`; if the dialog was dismissed while the write was in flight, it throws. `DateTime.now()` is computed inside `build`, so an app left open across midnight keeps yesterday's checklist until the next rebuild.
Fix: `await` the writes in an async handler with a `try/catch` + SnackBar; guard `setDialogState` with `if (context.mounted)`; hoist the date into state refreshed on resume/timer.

### Minor 4 — raw SQLite error surfaces on a malformed backup
Importing a format-4 file whose completion references a missing habit throws a raw `DatabaseException` (FK violation) rather than a `BackupException`. Rollback is correct and the UI shows "Import failed: …", but the message is a SQLite string. Fix: catch and wrap with a human-readable "backup contains a completion for a missing habit".

## Not defects (checked, clean)
- `parseHabitDay` rejects impossible dates, malformed strings and timestamps; `habitDayKey` uses local dates; period math is local-time and DST-safe (day arithmetic on `DateTime` components, not epoch offsets).
- Completion toggle is idempotent and uses `UNIQUE(habit_id, day)`; `count <= 0` rows do not satisfy a target.
- Coach tools return JSON errors for missing/invalid args; no unhandled null/type casts remain after the guards; tool names/schemas match the agent-loop dispatch.
- Backup format bump to 4 is backward compatible; full-replace semantics hold; older files without habit keys import cleanly.
- No secrets, no PII in logs, no new dependencies.

## Evidence artifacts
- Gate-only probes (untracked in the worktree): `test/zz_real_v9_migration_test.dart`, `test/zz_edge_probe_test.dart`, `test/zz_backup_edge_probe_test.dart`.
- Real v9 fixture: `/home/barry/compounder-db-backup-2026-11-07/pre/databases/compounder.db`.
