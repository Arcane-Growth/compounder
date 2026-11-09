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

---

# Round 2 — fix batch `06bb2d5`

- Reviewed commit: `06bb2d5` (fix(planner): stale-day load guard, DST test, sheet scroll test, dead-code cleanup)
- Base: `5fc702d`; prior gate `1c883e0`
- Pinned worktree: `/home/barry/.cache/review-wt/planner-r2` (detached at `06bb2d5`), clean before and after
- Date: 2026-11-09

## Verdict: APPROVE WITH FIXES

MAJOR-1 is genuinely fixed and the guard is non-vacuous. MINOR-1, MINOR-2, MINOR-3 and MINOR-5
are closed with non-vacuous guards. **MINOR-6 is not closed** despite the commit message claiming
"drawer/home: Day planner route + tile tests" — no such tests were added. One new Minor
(MINOR-7) was introduced by the NIT-3 timer gate. No Blocker, no data-loss path.

## Round-2 findings

### MINOR-6 (still open) — Drawer "Day planner" and Home "Day plan" tile are still untested
`06bb2d5` touched only `test/activity_heatmap_test.dart`, `test/backlog_minors_test.dart`,
`test/plan_test.dart` and `test/planner_test.dart`. `test/drawer_a11y_test.dart` was last changed
at `5fc702d` (a comment only) and has no tap on `Day planner`:

```
$ grep -n "tap(" test/drawer_a11y_test.dart   # taps: menu, Mind, Settings, Habits, Activity, Fitness
$ grep -rn "tap(find.text('Day plan'))" test/   # no match
```

`lib/ui/drawer.dart:187` (`Day planner` → `_openPlanner`) and `lib/ui/home.dart:383`
(`case pillarPlan: _openPlanner(context)`) remain unexercised. The Home test at
`test/activity_heatmap_test.dart:543` only asserts the `Day plan` label exists; it taps
`Nutrition` and the plan card, never the tile. Fix: add a drawer test mirroring the Habits one
(`expect(find.byType(PlannerScreen, skipOffstage: false), findsOneWidget)`) and a Home test that
taps `Day plan` and expects `PlannerScreen`. The commit message should not claim tests it did not add.

### MINOR-7 (new) — Midnight rollover leaves a stale "Now" marker on yesterday's plan
`lib/ui/planner.dart:63-67` gates the minute tick on `planDayKey(_day) == planDayKey(_now())`.
When the screen is open on today across midnight, the 00:00 tick now returns early, so the last
frame keeps `isToday == true` and paints a stale `Now 23:59` marker on yesterday's date. Probe
(planner open on 2026-11-09 23:59, clock advanced to 2026-11-10 00:01, one tick):

```
fixed code:   before midnight: Now marker=1   after midnight: Now marker=1
pre-fix code: before midnight: Now marker=1   after midnight: Now marker=0
```

Pre-fix the marker was dropped at midnight; the NIT-3 gate regressed that. Suggested minimal fix:
rebuild once when the day rolls over, e.g. track `bool _showedToday` and `setState` when
`planDayKey(_day) == planDayKey(now)` flips to false, then skip subsequent ticks.

## Round-2 closures verified (revert → quoted failure)

| Item | Status | Revert proof |
|---|---|---|
| MAJOR-1 generation guard | CLOSED | removed `++_generation` + both `generation != _generation` checks → `Expected: exactly one matching candidate / Actual: Found 0 widgets with text "Block for day 11"` |
| MINOR-1 DST test crosses boundary | CLOSED | probe: first `2026-11-01 01:30 -0400` epoch `1793511000000`, second `2026-11-01 01:30 -0500` epoch `1793514600000`, distinct; both `planDayKey` = `2026-11-01`. Reverting to the old constructor → `Expected: Duration:<-5:00:00.000000> / Actual: Duration:<-4:00:00.000000>` |
| MINOR-2 sheet scroll test | CLOSED | removed `SingleChildScrollView` in `_DayDetailSheet` → `Expected: null / Actual: FlutterError:<A RenderFlex overflowed by 404 pixels on the bottom.>` |
| MINOR-3 dead code | CLOSED | `hasPlanForDay` has zero refs in `lib/`+`test/`; `dayHasPlan` wired at `lib/ui/home.dart:527` and covered — forcing `dayHasPlan` to `false` → `Found 0 widgets with text "Next: Deep work"` |
| MINOR-5 import copy guard | CLOSED | dropped `day plans` from `importConfirmText` → `Expected: contains 'day plans' / Actual: 'Importing replaces all workouts, meals, accounts, net-worth history, reminders and mind data on this device.'` |
| MINOR-6 drawer/home tile tests | **OPEN** | see above |

NIT-1 (`_save` generic catch), NIT-2 (`MergeSemantics` + block-title label), NIT-3 (timer gate,
see MINOR-7), NIT-4 (position comment) are all addressed. NIT-2 has no semantics assertion in
`test/planner_test.dart`; acceptable for a nit.

## Round-2 gates run in the pinned worktree

- `flutter analyze` → `No issues found! (ran in 1.9s)`
- `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` → `+507: All tests passed!` (505 at `5fc702d`; +2 = stale-day guard + sheet scroll)
- `JAVA_HOME=/home/barry/Android/jdk21 flutter build apk --debug` → `✓ Built build/app/outputs/flutter-apk/app-debug.apk` (27.5s)
- Stale-day race: the new test drives two rapid day shifts with a 400 ms day-10 query and a 20 ms
  day-11 query; header `Wed, Nov 11, 2026` and `Block for day 11` agree, `Block for day 10` absent.
  Without the guard the day-10 result lands last and the day-11 block disappears (quoted above).

## Round-2 not verified

- Real-device rendering (no adb transport).
- iOS build (no hardware).
- Coach still has no plan tool (`lib/coach/agent.dart` tool list); prose now names planning as a
  pillar, so the coach claims a pillar it cannot read. Already queued as backlog (coach planner tool).
