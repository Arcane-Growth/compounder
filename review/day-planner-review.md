# Gate: day planner + planning pillar (schema v13)

- Reviewed commit: `5fc702d` (feat(planner): chronological day planner + planning pillar (schema v13))
- Baseline: `b00ed7f`
- Pinned worktree: `/home/barry/.cache/review-wt/planner` (detached at `5fc702d`)
- Date: 2026-11-09

## Verdict: APPROVE WITH FIXES

One Major correctness defect (stale day query can render the wrong day's blocks under the
selected date header), plus test-quality gaps. Migration, pillar bits, validation, backup
round-trip, overflow and semantics all check out. No Blocker.

## Findings

### MAJOR-1 — PlannerScreen has no generation guard: a stale day query overwrites the selected day
`lib/ui/planner.dart:80-95` (`_load`), reached from `_setDay` (`:104`), `didChangeAppLifecycleState`
(`:77`) and `_runWrite` (`:339`). `_load` captures `_day` at call time but applies the result
unconditionally:

```dart
final blocks = await store.planBlocksForDay(_day);
if (!mounted) return;
setState(() { _blocks = blocks; _loaded = true; });
```

Two rapid day shifts (or a slow DB) let the earlier query land last. Proven with a probe store
that delays the 11-10 query by 400 ms and the 11-11 query by 20 ms, then taps "next day" twice:

```
TEXT: Wed, Nov 11, 2026
TEXT: Block for day 10
TEXT: 09:00–10:00 · 1h
```

The header says Nov 11; the list shows Nov 10's block. `HomeTab._reload` already solves exactly
this with `_generation` (`lib/ui/home.dart:139-158`); the planner should copy it:

```dart
int _generation = 0;
Future<void> _load() async {
  final store = _store;
  if (store == null) return;
  final generation = ++_generation;
  final day = _day;
  try {
    final blocks = await store.planBlocksForDay(day);
    if (!mounted || generation != _generation) return;
    ...
```

No data loss (edits/deletes act on the real block id), but the user sees the wrong plan for the
day they selected.

### MINOR-1 — The DST fall-back test is vacuous
`test/plan_test.dart:184-190`:

```dart
final firstOneThirty = tz.TZDateTime(ny(), 2026, 11, 1, 1, 30);
final secondOneThirty = tz.TZDateTime(ny(), 2026, 11, 1, 1, 30);
```

Both constructors resolve the ambiguous local time to the *same* instant (EDT, offset -04:00).
Probe output:

```
a=2026-11-01 01:30:00.000-0400 utc=2026-11-01 05:30:00.000Z
b=2026-11-01 01:30:00.000-0400 utc=2026-11-01 05:30:00.000Z
identical instant: true
```

So the second assertion re-tests the first. The real second 01:30 (EST) is never exercised.
Fix: `final secondOneThirty = firstOneThirty.add(const Duration(hours: 1));` (probe confirms
that lands on 01:30 -0500, same calendar day). Production `planDayKey` is correct; only the
test is weak.

### MINOR-2 — The `_DayDetailSheet` scroll fix has no regression test
`lib/ui/heatmap.dart:359` wraps the sheet body in `SingleChildScrollView` with the comment
"Five pillar rows no longer fit a compact bottom sheet at large text scales". No committed test
opens the sheet at 320dp/2.0. Reverting the wrapper and running a probe at 320dp/2.0:

```
Actual: FlutterError:<A RenderFlex overflowed by 404 pixels on the bottom.>
```

The fix is real and necessary, but a future edit can undo it silently. Add a test that calls
`showDayDetail` at 320dp/2.0 and asserts `tester.takeException()` is null.

### MINOR-3 — Dead production code: `dayHasPlan` and `hasPlanForDay`
`lib/domain/plan.dart:151` and `lib/data/store.dart:1489` are called only from `test/plan_test.dart`.
Nothing in `lib/` uses them; `HomeTab` and the heatmap derive "planned" from `planCount`/`_plan`
instead. Two documented public APIs that will drift. Either wire them in or drop them.

### MINOR-4 — The planning pillar is invisible to the coach
`lib/coach/agent.dart:68` still says "Compounder compounds four areas of life" and lists only
health/wealth/mind. There is no planner tool (`getPlan`, `create_plan_block`, …) in the tool list.
A user asking the coach "what's on my plan today?" gets nothing. Either add a read tool or state
the omission deliberately.

### MINOR-5 — `importConfirmText` guard does not cover the new table
`test/backlog_minors_test.dart:298-308` asserts the import dialog names every wiped table, but the
list does not include `day plans`. The copy was updated (`lib/ui/settings.dart:28`) without extending
the guard, so a future edit could drop it and the test would still pass. Add `'day plans'`.

### MINOR-6 — Drawer entry and pillar tile are untested
`test/drawer_a11y_test.dart` has "pushes exactly one route and closes the drawer" tests for
Settings, Habits and Activity, but not for the new "Day planner" tile. Likewise the Home test taps
`Nutrition` and `Activity` but never the `Day plan` tile, so `_openPillar`'s `pillarPlan` branch
(`lib/ui/home.dart:382-383`) is unexercised.

### NIT-1 — `_save` only catches `StoreException`
`lib/ui/planner.dart:456`. A closed/failed DB throws a non-`StoreException`, which escapes as an
unhandled async error and leaves the dialog open with no message. `_runWrite` (`:333`) already
handles the generic case; mirror it.

### NIT-2 — Checkbox semantics label is a verb, unlike the rest of the app
`lib/ui/planner.dart:267-268` wraps the checkbox in `Semantics(label: 'Mark X done')`. The habit
screen (`lib/ui/habits.dart:138`) uses a bare `Checkbox` inside a `ListTile` and lets the tile name
the control. A screen reader announces "Mark Deep work done, checkbox, checked" — the action and
the state are duplicated. Prefer naming the block and letting the checkbox report state.

### NIT-3 — 1-minute timer rebuilds the whole screen
`lib/ui/planner.dart:51` calls `setState(() {})` every minute even when the screen is not showing
today. Cheap, but it rebuilds the full `ListView`. Gate it on `isToday`.

### NIT-4 — `MAX(position)+1` is not atomic
`lib/data/store.dart:1424`. Two concurrent creates on the same day can share a position. Harmless
in a single-user app (the id tie-break keeps the order deterministic), but worth a comment.

## Verified (commands run in the pinned worktree)

- `flutter analyze` → `No issues found!`
- `flutter test` → `+505: All tests passed!` (baseline was 419)
- `flutter build apk --debug` (JAVA_HOME=/home/barry/Android/jdk21) → `✓ Built build/app/outputs/flutter-apk/app-debug.apk`
- Migration SQL inspected: `_createV13Tables` is `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS`
  only; no `ALTER`, no `DROP`, no rewrite of an existing table. `_createSchema` also calls it, so fresh
  installs get the table. `oldVersion < 13` gate is correct.
- Migration test run: `upgrade 12 -> 13 adds plan_blocks without losing existing data` and
  `the 12 -> 13 step is safe to re-run (IF NOT EXISTS)` both pass.
- Pillar bits: 1/2/4/8/16, `allPillarsMask == 31` (asserted in `test/activity_heatmap_test.dart:174`).
  No collision. `grep` for hardcoded 4s in `lib/` found only stale prose in `coach/agent.dart:68`,
  `notify.dart:93` and an unrelated `backup.dart:354`.
- Heatmap ramp has 5 entries and clamps to index 4; legend loops 0..5; every "of N pillars" string
  reads 5 (`heatmap.dart:62,369,707`, `home.dart:429`). Home checklist iterates `allPillars` (5).
- Validation: `planBlockError` rejects blank/whitespace title, >80 chars, start/end outside 0..1440,
  and `endMin <= startMin`. `updatePlanBlock` re-validates the merged row. Store re-runs validation
  before writing.
- Day keys: `planDayKey` is a literal alias of `habitDayKey`; `localDayKey` is the same alias. One
  scheme. `_shiftDay` uses `DateTime(y, m, d + delta)`, never `Duration(days: 1)`.
- Backup: `planBlocks` exported, `plan_blocks` in the wipe list, inserted verbatim after the wipe.
  Probe: import the same file twice into a target that already had a local block →
  `after first import: 2 rows -> [Deep work, Gym]`, `after second import: 2 rows -> [Deep work, Gym]`,
  `new id after restore: 3` (no id collision). A format-4 file (no `planBlocks`) imports into v13 and
  leaves `plan_blocks` empty.
- `lib/ui/workout.dart` untouched: `git diff b00ed7f 5fc702d --name-only | grep -i workout` → empty.

## Regression guards proven non-vacuous (revert → quoted failure)

| Guard | Reverted | Failure |
|---|---|---|
| end<=start validation | removed `if (endMin <= startMin)` | `Expected: not null / Actual: <null>`; `Expected: throws StoreException / Actual: <Future<int>>` (2 failures) |
| perfect-day mask | `allPillarsMask` back to 15 | `Expected: false / Actual: <true>`; `Expected: <15> / Actual: <31>`; perfect-day count 2→0 (3 failures) |
| v13 migration | removed `_createV13Tables` from `oldVersion < 13` | `Expected: 'plan_blocks' / Actual: <null>` (2 failures) |
| backup export | removed `'planBlocks': await db.query('plan_blocks')` | `Expected: an object with length of <1> / Actual: <null>` |
| planner 320dp/2.0 | `Expanded` → `SizedBox(width: 400)` in `_blockTile` | `A RenderFlex overflowed by 232 pixels on the right` |
| home 320dp/2.0 | same break in `_PlanCard` | `A RenderFlex overflowed by 220 pixels on the right` |
| sheet scroll fix | removed `SingleChildScrollView` (probe only) | `A RenderFlex overflowed by 404 pixels on the bottom` |

## Not verified

- Real-device rendering (no adb transport; Pixel 10 CE-locked / off Wi-Fi).
- iOS build (no hardware).
