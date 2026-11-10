# Gate round 2: planner timeline UX (B1–B3 + majors)

**Reviewed commit:** `ac66652` (`fix(planner): address gate round 1 — drag origin, editor commit, undo day, touch targets, clipping, semantics`), branch `feat/planner-timeline`.
**Round-1 verdict:** `review/planner-ux-review.md` @ `f8447eb` (BLOCK).
**Reviewer:** Code Reviewer. **Date:** 2026-11-10.
**Worktree:** `/home/barry/.cache/review-wt/planner-r2b` (detached at `ac66652`, clean; only the throwaway `test/_r2_probe_test.dart` added).

## Verdict: APPROVE WITH FIXES

All three round-1 blockers (B1–B3) and all seven majors (M4–M10) are fixed and independently
reproduced. The three vacuous guards are now non-vacuous (revert-and-quote below). One **new
Major** regression was introduced by the 48dp-handle fix: 35–53 minute blocks clip their time
label (and at 2.0 text scale the title) because the compact/non-compact decision uses the card
height, not the body height left after the handle. Fix that before merge; the rest is clean.

## What I ran (pinned worktree, `TMPDIR=/home/barry/.cache/flutter-tmp`)

```
flutter analyze                                  -> No issues found! (ran in 3.2s)
dart format --output=none --set-exit-if-changed  -> Formatted 98 files (0 changed)
flutter test test/planner_test.dart              -> 00:03 +27: All tests passed!
flutter test test/planner_coach_test.dart test/plan_test.dart -> 00:00 +47: All tests passed!
flutter test (full suite)                        -> 00:18 +557 -2 (the only 2 failures are my
                                                    throwaway PROBE20/21; every repo test passes)
```

Schema is still v13 (`lib/data/store.dart:121`); `lib/domain/plan.dart` is unchanged between
`82dd783` and `ac66652`; `planBlocksForDay` is untouched. The `createPlanBlock` change only adds
optional `position`/`createdAt` parameters, so the coach tool call site
(`lib/coach/tools.dart:1383`) and all existing callers are unaffected.

## Round-1 blockers — independently reproduced as fixed

Probes are mine (`test/_r2_probe_test.dart`), not the developer's tests.

- **B1 fixed.** `lib/ui/planner.dart:384-403` now always recomputes from `_dragBaseStart`/
  `_dragBaseEnd`; the `if (delta == 0) return;` early return is gone.
  `PROBE7 start=60 end=120` (move +20px then −20px) and `PROBE8 start=60 end=120` (resize
  +20px then −20px). Previously 75/135 and 60/135.
- **B2 fixed.** `lib/ui/planner.dart:359-367` commits `_commitCreate()`/`_commitEdit()` before
  clearing the editor in `_beginDrag`.
  `PROBE17 aTitle=Renamed A` (edited A, then dragged B) and
  `PROBE18 titles=[New thing, Block B]` (typed a create, then dragged B). Previously
  `Block A` and `[Block B]`.
- **B3 fixed.** `lib/ui/planner.dart:449-479` captures `final day = _day;` in `_deleteBlock` and
  passes it to `_undoDelete`, which also restores `position`/`createdAt`.
  `PROBE2 original=1 next=0` (deleted on 11-09, shifted to 11-10, tapped Undo). Previously
  `original=0 next=1`.

## Round-1 majors — independently reproduced as fixed

- **M4 (handle hit target).** `lib/ui/planner.dart:753` computes `handleHit` and `:877` uses it.
  `PROBE4 handle=48.0 body=48.0` for a 60-minute block. **Residual (Minor, see N3):** for a
  48dp card (15–30 min) the handle is 24dp (`PROBE11 body=24.0 handle=24.0`), below the 48dp
  Material minimum; the developer documents the split in the comment at `:750-752`.
- **M5 (end-of-day clipping).** `lib/ui/planner.dart:702-703` adds `_clampTop`, applied at
  `:712` and `:724`; the 24:00 divider/label are moved inside the grid at `:631`/`:653`.
  `PROBE13 gridBottom=868.0 handleTop=844.0 handleBottom=868.0` (23:45–24:00 block) and
  `PROBE14 gridBottom=900.0 fieldBottom=882.0` (create editor at 23:45). Previously 892 > 868
  and 922 > 900.
- **M6 (compact overflow).** `lib/ui/planner.dart:798-833` wraps the time label in
  `Flexible(flex: 2)` with ellipsis and gives the title `Expanded(flex: 3)`.
  `PROBE15 cardHeight=48.0 exception=null` at 320dp/2.0 with a 30-minute block (compact path).
  Previously `RenderFlex overflowed by 256 pixels`.
- **M7 (didChangeMetrics guard).** `lib/ui/planner.dart:164-176` now gates on a real inset
  growth and re-reveals the editor; test `test/planner_test.dart:126-155` scrolls the field low
  first. Non-vacuity proven below.
- **M8 (_snap guard).** `lib/ui/planner.dart:491-492`; test `test/planner_test.dart:417-436`
  taps at 380 and expects 375. Non-vacuity proven below.
- **M9 (_minCardHeight guard).** `lib/ui/planner.dart:709-710`; test
  `test/planner_test.dart:439-457` uses a 15-minute block. Non-vacuity proven below.
- **M10 (semantics).** `lib/ui/planner.dart:878-881` adds `onIncrease`/`onDecrease` to the
  resize node; `:930-935` adds `button: true, checked: block.done` to the done toggle.
  `PROBE10 increase=true decrease=true checked=CheckedState.isFalse`.

## Non-vacuity proofs (revert-and-quote)

Each guard was reverted in the pinned worktree, the named test run, and the failure quoted;
the file was restored with `git checkout -- lib/ui/planner.dart` afterwards.

1. **`didChangeMetrics` removed** (`lib/ui/planner.dart:164-176` deleted):
   ```
   flutter test test/planner_test.dart --plain-name "the inline field is pulled clear when the keyboard opens"
   Expected: a value less than or equal to <400>
     Actual: <521.2>
   ```
2. **`_snap` replaced with a plain clamp** (`lib/ui/planner.dart:491-492`):
   ```
   flutter test test/planner_test.dart --plain-name "a tap off the 15-minute boundary snaps the new block down"
   Expected: <375>
     Actual: <380>
   ```
3. **`_minCardHeight` clamp removed** (`lib/ui/planner.dart:709-710`):
   ```
   flutter test test/planner_test.dart --plain-name "a 15-minute block keeps the 48dp minimum card height"
   Expected: a value greater than or equal to <48>
     Actual: <24.0>
   ```

All three guards are now non-vacuous.

## New findings

### N1 (Major) — 35–53 minute blocks clip their time label
`lib/ui/planner.dart:749` sets `compact = height < 56` from the **card** height, but the body
box is `height - handleHit` (`:753`, `:777`). For a 35–53 minute block the card is 56–86dp,
`handleHit` is 32–48dp, so the body is only 24–38dp while the non-compact `Column` (`:834-867`)
needs ~38dp (title + 2 + time label). The `ClipRect` at `:788` silently clips the overflow.

```
PROBE20 cardBottom=272.0 bodyBottom=224.0 labelBottom=240.0 clipped=true   (45-min block)
PROBE21 bodyBottom=232.0 labelBottom=240.0 clipped=true                    (50-min block)
```

The time label is effectively hidden for a common duration range. Fix: base the compact
decision on the body height (`height - handleHit < 40`) or on the text scale, or cap
`handleHit` so the body keeps at least the content height.

### N2 (Major) — the 320dp/2.0 compact test does not detect vertical clipping
`test/planner_test.dart:670-690` only asserts `tester.takeException() == null`. Because the
`ClipRect` hides the overflow, no exception is thrown even when the text is cut off:

```
PROBE22 bodyBottom=224.0 titleBottom=242.0 titleClipped=true exception=null  (45-min, 2.0)
PROBE23 bodyBottom=224.0 titleBottom=242.0 titleClipped=true exception=null  (30-min compact, 2.0)
```

At 2.0 text scale the title is clipped on both the compact and the 45-minute paths. The test
should assert the rendered text rect stays inside the body rect, not just that no exception
was thrown.

### N3 (Minor) — sub-45-minute cards get a 24dp resize handle
`lib/ui/planner.dart:753`: for a 48dp card `handleHit = (48-24).clamp(24,48) = 24`. The 48dp
target only holds for cards ≥72dp. This is a documented tradeoff (a 48dp card cannot host two
48dp targets), but it means the round-1 M4 requirement is met only for normal-length blocks.

### Nit — the "now" line at 23:59 is still clipped
`lib/ui/planner.dart:669-694` positions the now line at `_topFor(nowMinute)` without clamping;
at 23:59 its text extends past the grid's 2304dp extent and is clipped by the Stack. The 24:00
divider was fixed (`:631`), but the now line was not.

## Verified clean

- `flutter analyze`: no issues.
- `dart format`: 0 files changed.
- Planner suite: 27/27 pass; coach/plan suites: 47/47 pass; full repo suite green (the only
  failures were my throwaway PROBE20/21).
- No schema change (v13), `PlanBlock`/`planBlockError`/`planBlocksForDay` untouched.
- Existing blocks load and render; undo restores `position`/`createdAt` so ordering is stable.
- Coach plan tools unaffected: `createPlanBlock`'s new parameters are optional and the coach
  call site does not pass them.
- Stale-day, midnight-rollover and cumulative-drag guards remain non-vacuous (round-1 proofs
  still hold; the code paths are unchanged).
- No hardcoded prices/trial logic in this screen (not applicable).

## Required before merge

1. Fix N1/N2: make the compact decision account for the body height left after the handle (or
   the text scale), and add a test that asserts the text rect stays inside the body rect.
2. Optional: N3 (24dp handle on sub-45-minute cards) and the 23:59 now-line nit.

Probe file `test/_r2_probe_test.dart` is throwaway and was not committed; `test/_gate_probe_test.dart`
is kept as instructed.
