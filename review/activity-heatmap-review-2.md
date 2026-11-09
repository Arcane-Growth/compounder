# Gate review round 2 — activity heatmap + gamified home fixes

- **Task**: Gate round 2: heatmap + gamified home fixes (compounder)
- **HEAD reviewed**: `5a3bb7d` ("Gate fixes: guard half-open range, resume card, quick links, drawer Activity; fix a11y overflows and month-label alignment")
- **Round 1**: gate `c493d706` on `e78bd04` → REQUEST CHANGES (4 Majors, 7 Minors, 4 Nits)
- **Worktree**: `/home/barry/.cache/review-wt/heatmap-gate2` (pinned at `5a3bb7d`, detached; not the shared checkout — the shared checkout is dirty with other agents' in-flight edits)
- **Date**: 2026-11-09
- **Verdict**: **APPROVE** — all four Majors and Minors 1-2 are closed with non-vacuous guards, the two overflows are gone at 320×640/2.0, month labels align to 0.0px, and the five previously-proven guards still bite. Three Minors remain (one new, two pre-existing and already queued in the backlog); none blocks this batch.

## What I verified (commands + results)

1. **Hygiene** — `flutter analyze` in the pinned worktree → `No issues found! (ran in 0.9s)`.
2. **Full suite** — `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` → `00:11 +402: All tests passed!` (round 1 was 397; +5 new tests).
3. **Guard proofs** — each new guard reverted and the failure captured (below).
4. **Geometry** — measured with my own scratch harness, not the dev's test: `Mon=0.0 Jan=37.5 Jan1=37.5 Mar=165.5 Mar1=165.5` → label-to-column delta `0.0` for both Jan and Mar; with `showWeekdayLabels: false` `Jan=0.0 Jan1=0.0` → delta `0.0`.
5. **Overflow** — `HeatmapLegend` at 248dp and 320dp with `textScaler 2.0` → no exception; `SectionHeader` at 280dp/2.0 → no exception; full home at 320×640/2.0 scrolled 12 screens → no exception; home at 412×915/1.3 → no exception (round 1 saw a pre-existing 12px AppBar overflow there; the `Expanded` title fix removes it).
6. **Streak chip** — measured `Rect.fromLTRB(20.0, 138.0, 192.9, 174.0)` at 412dp: the chip still shrink-wraps (`mainAxisSize.min`), it did not become a full-width bar when moved from the `Row` into the `Column`.
7. **Reachability** — quick links push `HistoryScreen`/`ProgressScreen`/`HealthDataScreen`/`SettingsScreen` and select tabs 4 (Coach) / 2 (Wealth); drawer Activity pushes `HeatmapScreen` once and closes the drawer.

## Non-vacuous guard proofs (revert → quoted failure)

**New guards (round-1 Majors 1-4 + Minors 1-2):**

- **Half-open end-day exclusion** — flipped every `< ?` to `<= ?` in `dailyPillarActivity` (`lib/data/store.dart:1132,1138,1143,1146,1149,1155`): `the range is half-open: rows at the end boundary are excluded` → `Expected: equals ['2026-11-04'] unordered / Actual: ['2026-11-04', '2026-11-05']` at `test/activity_heatmap_test.dart:370`.
- **Active-workout resume card** — deleted `lib/ui/home.dart:120-141`: `shows the active-workout resume card and opens the workout` → failed at `test/activity_heatmap_test.dart:502`.
- **Home quick links** — deleted the `Wrap` at `lib/ui/home.dart:208-248`: `every quick link opens its screen or selects its tab` → `scrollUntilVisible` could not find `History`, failed at `test/activity_heatmap_test.dart:534`.
- **Drawer Activity route** — deleted the Activity `ListTile` at `lib/ui/drawer.dart:147-151`: `Activity pushes exactly one route and closes the drawer` → tap failed to find `Activity` at `test/drawer_a11y_test.dart:357`.
- **Home/legend overflow** — reverted `lib/ui/heatmap.dart`, `lib/ui/home.dart`, `lib/ui/widgets.dart` to `e78bd04`: `A RenderFlex overflowed by 31 pixels on the right.` + `A RenderFlex overflowed by 113 pixels on the right.` → `Expected: null / Actual: 'Multiple exceptions (2)...'` at `test/activity_heatmap_test.dart:612`. Reverting only `heatmap.dart` (legend) → `A RenderFlex overflowed by 16 pixels on the right.` at `:637`.
- **Month-label alignment** — reverted `lib/ui/heatmap.dart` to `e78bd04`: `Expected: a value less than <0.5> / Actual: <37.5>` at `test/activity_heatmap_test.dart:688`.

**Previously-proven guards (no regression):**

- **Local-day SQL bucketing** — removed `'localtime'` from the workouts query: `Null check operator used on a null value` at `test/activity_heatmap_test.dart:335`.
- **`count > 0` habit filter** — dropped the predicate: `Expected: false / Actual: <true>` at `test/activity_heatmap_test.dart:339`.
- **Today-empty streak fallback** — replaced the yesterday fallback with `return 0`: `Expected: <2> / Actual: <0>` at `test/activity_heatmap_test.dart:153`.
- **Heatmap in-range cell filter** — forced `inRange = true`: `Expected: exactly 90 matching candidates / Actual: Found 98 widgets` at `test/activity_heatmap_test.dart:662`.
- **DST calendar arithmetic** — replaced `previousDayKey` with `Duration(days: 1)`: `Expected: <3> / Actual: <2>` at `test/activity_heatmap_test.dart:179` (on this EST host).

## Findings (severity order)

### Minor 1 — the half-open guard only covers two of the six queries
`test/activity_heatmap_test.dart:343-374` seeds a boundary workout and a boundary `habit_completions` row, but no boundary meal/mood/meditation/thought record. I flipped **only** the meals query (`lib/data/store.dart:1138`) to `<= ?` and the test still passed (`00:00 +1: All tests passed!`). The production code is correct today; the guard would not catch a regression in the other four queries.
Fix: seed a meal and a mood at exactly `DateTime(2026, 11, 5)` and assert `days.containsKey('2026-11-05')` stays false.

### Minor 2 — month labels overlap the first cell row at accessibility text scale (pre-existing, touched code)
`_monthLabels` (`lib/ui/heatmap.dart:283-286`) returns a fixed `SizedBox(height: 16)`. At `textScaler 2.0` the label is 32px tall. Measured with `start: 2026-06-01` (a Monday): `Jun` label `Rect(70.5, 0.0, 138.0, 32.0)` vs the June 1 cell `Rect(70.5, 16.0, 84.5, 30.0)` → **16px vertical overlap**. No exception is thrown (the `Stack` uses `Clip.none`), so no test catches it. Pre-existing at `e78bd04`, but this change rewrote the surrounding layout.
Fix: size the label row from the label's intrinsic height (or `MediaQuery.textScalerOf(context).scale(16)`), and add the Activity-screen heatmap at 2.0 to the overflow test.

### Minor 3 — the DST guard is still host-dependent (pre-existing, already queued)
The test now builds `tz.TZDateTime` inputs (`test/activity_heatmap_test.dart:179-197`) and asserts the zone really springs forward, which is an improvement. But `previousDayKey` (`lib/domain/activity.dart:79-83`) constructs a host-local `DateTime` via `parseHabitDay`, so the broken `Duration(days: 1)` implementation still passes under `TZ=UTC`: I ran `TZ=UTC flutter test --plain-name "a DST transition day is one day"` with the broken code → `00:00 +1: All tests passed!`. A UTC CI runner silently loses this guard.
Fix: make `previousDayKey` zone-aware, or pin `TZ=America/New_York` in the documented test command. Tracked in the queued backlog task ("DST test pin").

### Nit 1 — `_StubHealthSource` is duplicated verbatim
`test/activity_heatmap_test.dart:24-62` and `test/drawer_a11y_test.dart:26-64` are byte-identical. Extract to `test/support/health_stub.dart`.

### Nit 2 — the resume-card test does not pin prominence
Round-1 Major 2 asked for the card to stay *prominent*. The new test asserts presence and navigation, but not that the card sits above the `Today` section. A positional assertion (`getTopLeft(card).dy < getTopLeft(find.text('Today')).dy`) would pin it.

### Nit 3 — no test asserts the resume card is *absent* for a finished workout
The original home test seeds a finished workout (`ended_at` set) but never asserts `find.textContaining('In progress since')` is empty. A one-line negative assertion would close the loop.

### Nit 4 — quick-link test verifies the callback, not the shell
`selectTab` is a captured closure, so the test proves the right index is requested, not that `ShellNav`/`IndexedStack` actually switches. Acceptable for a unit test; noted so it is a deliberate choice.

## Not re-raised (already queued)
Round-1 Minors 3-7 (per-store-notification query storm, full table scans, Activity screen staleness + raw error text, midnight staleness, 14px touch target) and Nits 1-4 are unchanged by this commit and are covered by the queued backlog task "heatmap gate minors (perf, staleness, DST test pin, nits)". Not blockers for this batch.

## Not verified
- Real-device rendering (Pixel 10) — widget tests only; overflow findings come from the test surface at 320dp/2.0 and 412dp/1.3.
- iOS: no hardware; the heatmap is pure Flutter so risk is low.
- SQLite `'localtime'` behaviour under a device timezone change mid-session (edge case, not exercised).
