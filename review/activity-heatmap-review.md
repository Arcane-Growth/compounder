# Gate review — activity heatmap + gamified home screen

- **Task**: Gate: activity heatmap + gamified home screen (compounder)
- **HEAD reviewed**: `e78bd04` ("Add activity heatmap and gamified daily home screen")
- **Worktree**: `/home/barry/.cache/review-wt/heatmap-gate` (pinned at `e78bd04`, detached; not the shared checkout)
- **Date**: 2026-11-09
- **Verdict**: **REQUEST CHANGES** — no correctness, security or data-loss blocker. The feature works and the core math is right, but four of the required behaviours have **no non-vacuous regression guard** (I deleted the code and the suite stayed green), and two new widgets overflow at accessibility text scale.

## What I verified (commands + results)

1. **Hygiene** — `flutter analyze` in the pinned worktree → `No issues found! (ran in 1.7s)`.
2. **Full suite** — `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` → `00:20 +397: All tests passed!`.
3. **Feature suite** — `flutter test test/activity_heatmap_test.dart` → `00:01 +19: All tests passed!`.
4. **Aggregation semantics** — read `dailyPillarActivity` (`lib/data/store.dart:1118-1190`) and the schema. Four grouped queries, no per-day loop, no N+1; parameters bound (no injection); `habit_completions` filtered `count > 0`; half-open range. `EXPLAIN QUERY PLAN` on the shipped schema: `SCAN workouts`, `SEARCH meals USING COVERING INDEX idx_meals_timestamp`, `SCAN moods`/`SCAN meditations`/`SCAN thought_records`, `SCAN habit_completions`, `USE TEMP B-TREE FOR GROUP BY` on all four.
5. **Streak / perfect-day math** — read `lib/domain/activity.dart`; calendar arithmetic (`DateTime(y,m,d-1)`), today-empty fallback, bounded walk, empty-map handling. Probed the edge cases below.
6. **Rendering** — measured geometry with a scratch widget test: `Jan=Offset(0.0,0.0)`, `Mon=Offset(0.0,16.0)`, `firstCell=Offset(37.5,64.0)` → month labels are 37.5px left of their columns. Cell count for 2026-01-01..2026-03-31 = 90 (31+28+31), correct.
7. **Real-device surfaces** — scratch widget tests at 412×915/1.0 (clean), 412×915/1.3 (pre-existing AppBar overflow only), 320×640/2.0 (two **new** overflows, see Minor 1).
8. **Reachability** — shell tab indices match the home quick links (`Macros`=1, `Wealth`=2, `Mind`=3, `Coach`=4; `lib/ui/shell.dart:66-75`). Drawer keeps Fitness/Macros/Wealth/Mind/Coach + Activity/Habits/Settings. No marketing copy anywhere in the new UI.

## Non-vacuous guard proofs (revert → quoted failure)

These guards are real; I reverted each fix and captured the failure:

- **Local-day SQL bucketing** — removed `'localtime'` from the workouts query: `aggregate store query returns correct per-day masks for a seeded range` → `Null check operator used on a null value` at `test/activity_heatmap_test.dart:279` (the 23:59 row moved to the next UTC day).
- **`count > 0` habit filter** — dropped the predicate: same test → `Expected: false Actual: <true>` at `test/activity_heatmap_test.dart:283` ("a count <= 0 completion is not a logged habit").
- **Today-empty streak fallback** — replaced the yesterday fallback with `return 0`: `an unfinished today does not zero a streak` → `Expected: <2> Actual: <0>` at `test/activity_heatmap_test.dart:102`.
- **Heatmap in-range cell filter** — forced `inRange = true`: `renders one cell per in-range day and the legend` → failed at `test/activity_heatmap_test.dart:400` (cell count ≠ 90).
- **DST calendar arithmetic** — replaced `previousDayKey` with `Duration(days: 1)`: `a DST transition day is one day, not zero or two` → `Expected: <3> Actual: <2>` at `test/activity_heatmap_test.dart:139`. **Caveat**: this only fails because this host is `America/New_York`; with `TZ=UTC` the same broken code passes (see Minor 5).

## Findings (severity order)

### Major 1 — the half-open range guard is vacuous
`test/activity_heatmap_test.dart:287-292` claims "the end day is excluded", but no seeded row sits at the boundary. I flipped **every** `< ?` to `<= ?` in `dailyPillarActivity` (`lib/data/store.dart:1132,1138,1143,1146,1149,1155`) and the test still passed (`00:00 +1: All tests passed!`). The query is correct today; the guard would not catch a regression to inclusive bounds.
Fix: seed a workout at exactly `DateTime(2026,11,5)` (midnight of the exclusive end) and a `habit_completions` row on `'2026-11-05'`, then assert both are absent.

### Major 2 — the active-workout resume card has no regression guard
The task requires the resume card to stay prominent. Deleting the whole `if (_active != null) ...[` block (`lib/ui/home.dart:110-131`) leaves `activity_heatmap_test.dart` + `drawer_a11y_test.dart` green (`00:02 +28: All tests passed!`). The home test seeds a **finished** workout (`ended_at` set), so `activeWorkout()` returns null and the branch never renders.
Fix: seed an unfinished workout (`ended_at` null) and assert `find.textContaining('In progress since')` plus a tap that pushes `WorkoutScreen`.

### Major 3 — "every pre-existing screen still reachable" has no guard
Deleting the entire `Wrap` of quick links (`lib/ui/home.dart:194-233`) leaves the suite green. Nothing asserts History/Progress/Coach/Health/Wealth/Settings are reachable from home.
Fix: assert the six buttons exist and that each pushes the expected screen or selects the expected tab.

### Major 4 — the new drawer Activity entry has no guard
Deleting the Activity `ListTile` (`lib/ui/drawer.dart:147-151`) leaves `drawer_a11y_test.dart` green (`00:01 +9: All tests passed!`). That file covers Settings and Habits with an "exactly one route" test but not Activity.
Fix: mirror the Settings/Habits tests — tap Activity, assert exactly one `HeatmapScreen` route and that the drawer closed.

### Minor 1 — two new widgets overflow at accessibility text scale
Scratch test at 320×640 with `textScaler: 2.0`:
- `_TodayHeader` (`lib/ui/home.dart:311`) — `A RenderFlex overflowed by 31 pixels on the right.` The streak chip is a fixed-width `Container` next to an `Expanded` column.
- `HeatmapLegend` (`lib/ui/heatmap.dart:87`) — `A RenderFlex overflowed by 24 pixels on the right.` Five swatches + "Less"/"More" in a non-flexible `Row`.
Both clip content in release builds. Fix: `Flexible`/`FittedBox` around the chip; `Wrap` or `FittedBox` for the legend.
(Pre-existing, not this change: AppBar title `Row` at `lib/ui/home.dart:94` overflows 113px at 320dp/2.0 and 12px at 412dp/1.3; `SectionHeader` at `lib/ui/widgets.dart:50` overflows 51px at 320dp/2.0.)

### Minor 2 — month labels are misaligned with their columns
`_monthLabels` (`lib/ui/heatmap.dart:283-286`) positions labels at `left: i * columnWidth` from x=0, but the grid `Row` starts with `_weekdayLabels` (`lib/ui/heatmap.dart:186`). Measured: `Jan` at x=0, first cell column at x=37.5. On the Activity screen (`showWeekdayLabels` defaults true) every month label sits over the weekday-label gutter.
Fix: offset the label `Stack` by the weekday-label width, or build the month row inside the same `Row` so both share the column origin.

### Minor 3 — home runs 5 DB queries on every store notification, even off-screen
`_reload` (`lib/ui/home.dart:59-81`) is registered as a store listener (`lib/ui/home.dart:48`), and `refreshAll()` calls `notifyListeners()` (`lib/data/store.dart:402`) after **every** mutation (meal, set, mood, habit, account, reminder). `HomeTab` lives in an `IndexedStack` (`lib/ui/shell.dart:66-75`), so it stays mounted on every tab: each mutation costs 4 aggregate queries + `activeWorkout()`. Overlapping `_reload` calls can also `setState` out of order.
Fix: gate on visibility (shell-provided flag or `TickerMode`), debounce, and drop stale results with a generation counter.

### Minor 4 — the new aggregate queries are full table scans
`EXPLAIN QUERY PLAN` (shipped schema): `SCAN workouts`, `SCAN moods`, `SCAN meditations`, `SCAN thought_records`, `SCAN habit_completions`, plus `USE TEMP B-TREE FOR GROUP BY` on all four queries. Only `meals` uses `idx_meals_timestamp`. Combined with Minor 3 this is the real cost of the feature.
Fix: add `workouts(started_at)`, `moods(timestamp)`, `meditations(timestamp)`, `thought_records(timestamp)`, `habit_completions(day)` in a schema bump, or document the bounded scan and accept it.

### Minor 5 — the DST guard only bites on a DST host
`test/activity_heatmap_test.dart:123-144` calls `localDayKey` on host-local `DateTime`s. With `TZ=UTC`, the broken `Duration(days: 1)` implementation passes (`00:00 +1: All tests passed!`); on this EST host it fails correctly. A UTC CI runner would silently lose the guard.
Fix: pin `TZ=America/New_York` for the test run (documented in the repo's test command), or assert through a zone-aware helper.

### Minor 6 — Activity screen goes stale and leaks raw errors
`HeatmapScreen` (`lib/ui/heatmap.dart:374-403`) loads once in `initState` and never subscribes to the store, so a background sync or a log made while the screen is open is not reflected. `_error` renders `e.toString()` (`lib/ui/heatmap.dart:401,415`), which surfaces raw SQLite text.
Fix: subscribe like `HomeTab` does; show a human message and log the raw error.

### Minor 7 — "today" can be stale across midnight
`_today` (`lib/ui/home.dart:39`) only updates on the next store notification. An app left open overnight shows yesterday's date and streak until something is logged.
Fix: refresh on `AppLifecycleState.resumed` and/or a midnight timer.

### Nit 1 — 14px heatmap cells are below the 48dp touch target
Documented in the file header, but the "accessible path" it claims (the per-day detail sheet) is itself only reachable by tapping a 14px square. Consider a per-day list view or larger cells on the full screen.

### Nit 2 — `_askWorkoutName` never disposes its `TextEditingController`
`lib/ui/home.dart:390`. Pre-existing, but the function was touched in this change.

### Nit 3 — first month label can name a month outside the range
`lib/ui/heatmap.dart:280` falls back to `columns[i].first.month`, which is the month of the first Monday and can precede `start` (e.g. start Nov 1 when Nov 1 is a Sunday → "Oct" at column 0).

### Nit 4 — `localDayKey` is a one-line alias for `habitDayKey`
`lib/domain/activity.dart:73`. Acceptable as a domain boundary; flagging only so it is a deliberate choice.

## Opinion (not a defect)
The old home had a `FilledButton.icon('Start workout')` as the primary CTA; it is now the Workout pillar tile ("Not yet — tap to log"). The path is preserved and the tile is the first checklist row, but the primary action changed from a filled button to a list tile. Product call, not a bug.

## Not verified
- Real-device rendering (Pixel 10) — widget tests only; the overflow findings come from the test surface at 320dp/2.0.
- iOS: no hardware; the heatmap is pure Flutter so risk is low.
- SQLite `'localtime'` behaviour under a device timezone change mid-session (edge case, not exercised).
