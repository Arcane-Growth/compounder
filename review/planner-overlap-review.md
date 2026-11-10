# Gate: planner overlap lanes + back-to-back gap

**Reviewed commit:** `ad4a0f5` (`feat(planner): lay overlapping blocks out side by side in lanes`), branch `feat/planner-timeline`.
**Prior gate:** `review/planner-ux-review-round3.md` @ `cc84025` (APPROVE, N1/N2 clipping fix).
**Reviewer:** Code Reviewer. **Date:** 2026-11-10.
**Worktree:** `/home/barry/.cache/wt-planner-lanes` (detached at `ad4a0f5`, clean; two throwaway probe files added and removed before the final suite run).
**Scope:** lane layout for overlapping blocks and the visual gap between back-to-back blocks in `lib/ui/planner.dart`, plus `test/planner_lanes_test.dart`.

## Verdict: APPROVE

The lane layout is correct and deterministic, the gap is visual-only, the round-3 clipping fix still holds in a lane at 1.0 and at 320dp/2.0, and every new rect-based guard is non-vacuous (revert-and-quote below). No Blockers or Majors. Two pre-existing Minor defects are reported but do not block this change.

## What I ran (pinned worktree, `TMPDIR=/home/barry/.cache/flutter-tmp`)

```
dart format --output=none --set-exit-if-changed lib test tool
  -> Formatted 99 files (0 changed) in 0.18 seconds.        exit 0
flutter analyze
  -> No issues found! (ran in 2.8s)                          exit 0
flutter test test/planner_lanes_test.dart
  -> 00:01 +15: All tests passed!                            exit 0
flutter test test/planner_test.dart
  -> 00:04 +37: All tests passed!                            exit 0
flutter test (full suite)
  -> 00:18 +571: All tests passed!                           exit 0
```

## Independent reproduction on rendered rects (my probes, not the developer's tests)

400x900 surface unless stated; rects read with `tester.getRect` on `plan-card-$id`, `plan-block-$id`, `plan-resize-$id`.

| case | measured |
|---|---|
| 2-lane overlap 06:00-07:00 / 06:30-07:30 | lanes 56..222.5 and 225.5..392, disjoint, both inside 56..392 |
| 3-lane overlap | lefts 56.0 / 169.0 / 282.0, widths 110.0, disjoint |
| rebuild after a done-toggle (no time change) | lefts identical before/after: `[56.0, 169.0, 282.0]` |
| resize 06:00-07:00 into 07:30-08:30 mid-gesture | during: 56..222.5 vs 225.5..392, disjoint; stored 360..480 |
| 4 lanes at 320dp | card w=61.75, body w=33.96, strip w=33.96 h=48, `takeException()==null` |
| 3 lanes at 320dp/2.0 | card w=83.33, strip w=45.83 h=48, `takeException()==null` |
| 45-min in a 2-lane cluster, 1.0 | card h=70, body 27dp, title/label inside body |
| 45-min in a 2-lane cluster, 2.0 (400dp and 320dp) | card h=70, body 47dp, title bottom 20.5 / label bottom 16.5 vs body bottom 24.0 — inside, `takeException()==null` |
| back-to-back 30-min, 1.0 | cardA 681..727 (h=46), cardB 729..775, gap=2.0, stripA 708..727 (h=19), not covered |
| 23:45-24:00 block | card 820..868, grid bottom 868 — inside |
| 00:00 block | card top = grid top + 1.0 (the half-gap inset) |

Lane geometry is exact: for `lanes=n` the last lane ends at `width - _timelineRight` (`_laneGeometry` at `lib/ui/planner.dart:869-878`), so no lane overflows. `plannerLaneLayout` (`:87-132`) is a correct greedy interval-graph colouring: transitive clustering via `clusterEnd` (`:125-129`), lowest-free-lane assignment (`:101-116`), deterministic sort by `(start, id)` (`:88-92`). Touching blocks (`start == clusterEnd`) flush the cluster (`:126`), so they are not treated as overlapping. The layout is recomputed from `_dragStart/_dragEnd` for the dragged block (`:702-708`), so it follows move and resize gestures.

## Non-vacuity — revert-and-quote

Each guard was proven by reverting the fix in the pinned worktree and quoting the failure.

1. **`plannerLaneLayout` gutted** to `{id: PlannerLane(lane: 0, lanes: 1)}`:
   ```
   two overlapping blocks get two lanes:  Expected: <2>  Actual: <1>
   three mutually overlapping blocks:     Expected: Set:[3]  Actual: Set:[1]
   transitive overlap chain:              Expected: Set:[2]  Actual: Set:[1]
   partial overlap of three blocks:       Expected: Set:[3]  Actual: Set:[1]
   -> 00:00 +3 -4: Some tests failed.
   ```
2. **Rendering ignores lanes** (`lanes[block.id]!` -> `PlannerLane(lane: 0, lanes: 1)`):
   ```
   overlapping blocks must not paint over each other: 56.0..392.0 vs 56.0..392.0
   three overlapping blocks must occupy three lanes:  Actual: Set:[56.0] (length 1)
   the lanes must recompute while the block is under the finger: 56.0..392.0 vs 56.0..392.0
   the 45-minute block must sit in its own lane: 56.0..392.0 vs 56.0..392.0
   -> 00:01 +1 -4: Some tests failed.
   ```
3. **Live drag times reverted** (`start: block.startMin, end: block.endMin`):
   ```
   the lanes must recompute while the block is under the finger: 56.0..392.0 vs 56.0..392.0
   -> 00:00 +0 -1: Some tests failed.
   ```
4. **`_cardGap = 0`:**
   ```
   back-to-back blocks must not render flush: Expected: a value greater than <0>  Actual: <0.0>
   -> 00:01 +1 -1: Some tests failed.
   ```
5. **`slotHeight = height` (gap not accounted for in the compact decision):**
   ```
   the label must sit below the title, not beside it:
   Expected: a value greater than or equal to <714.0>  Actual: <696.0>
   -> 00:00 +0 -1: Some tests failed.
   ```
6. **Round-3 fix reverted** (`git checkout cc84025^ -- lib/ui/planner.dart`), keeping the new tests:
   ```
   flutter test test/planner_test.dart --plain-name "shows its full time label"
   -> 10/10 duration/scale cases fail, e.g. 45-min/1.0:
      the time label must not be clipped by the card body
      Expected: a value less than or equal to <0.0>  Actual: <16.0>
   flutter test test/planner_test.dart --plain-name "a compact block keeps its text inside the body at 320dp / 2.0"
   -> the title must not be clipped by the card body
      Expected: a value less than or equal to <0.0>  Actual: <18.0>
   ```
   Restored `lib/ui/planner.dart` to `ad4a0f5` -> `+37: All tests passed!`. The round-3 guards are still non-vacuous after this change.

## Findings

### Minor 1 — a 30-minute card is now 46dp tall, below the documented `_minCardHeight` floor (`lib/ui/planner.dart:862`)
`_cardHeight` returns `slot - _cardGap` for any slot >= 48, so a 30-minute block renders 46dp (measured: cardA h=46.0). `_minCardHeight = 48` is documented at `:26-27` as the smallest rendered card height "so a 15-minute block is still tappable", and the gap silently breaks that invariant for the most common block length. The whole card is tappable (body tap and strip tap both rename), so the effective target is 46dp — 2dp under the Material 48dp minimum. Fix: `final floor = slot < _minCardHeight + _cardGap ? _minCardHeight : slot - _cardGap;` so a 30-minute card keeps 48dp and only longer cards take the inset. Not blocking: 2dp, and the card is still a real target.

### Minor 2 (pre-existing, not introduced here) — vertical occlusion of the earlier block's resize strip
Cards grow past their slot when the text needs more room (`_cardHeight` floor at `:862`, `_minCardHeight` at `:27`). Back-to-back short blocks therefore overlap vertically and the later card paints over the earlier card's strip:
```
15-min back-to-back, 1.0: cardA 681..729, cardB 705..753, stripA 708..729 -> stripCoveredByB=true
  tap on stripA centre opened B15's editor (A15=1, B15=2, inline=1)
30-min back-to-back, 2.0: cardA 681..744, cardB 729..792, gap=-15, stripCoveredByB=true
15-min back-to-back, 2.0: cardA 681..744, cardB 705..768, gap=-39, stripCoveredByB=true
```
The strip is still reachable through `Semantics(onIncrease/onDecrease)` (`:1069-1072`), and the body tap still opens the right editor, so this is a touch-target gap, not a data-loss bug. It predates `ad4a0f5` (the same growth existed at `cc84025`) and is outside this change's scope; reported for a follow-up, not a blocker.

### Nit 1 — `44.0` and `0.45` are unnamed magic numbers (`lib/ui/planner.dart:960`)
The toggle width cap duplicates the old literal `44` and introduces an unexplained `0.45` share. A named constant (`_doneToggleWidth`, `_doneToggleMaxShare`) would match the file's convention of naming layout constants (`:14-53`).

### Nit 2 — `PlannerLane` / `PlannerSpan` / `plannerLaneLayout` are public only for tests (`:57-132`)
They are implementation details of the screen. `@visibleForTesting` on the classes and function would document that, as the rest of the file keeps helpers private.

### Nit 3 — three of the seven `plannerLaneLayout` unit tests pass against a degenerate implementation
`blocks that only touch are not overlapping`, `lane assignment is deterministic regardless of input order` and `every span gets an entry` all pass when the function returns `lane 0, lanes 1` for everything (experiment 1: `+3 -4`). They are targeted property checks, not lane guards; the four that fail are the real guards, and the widget rect tests cover the rest. No action required, but do not read the unit group as a complete lane proof.

### Nit 4 — no widget-level rebuild-stability guard
The determinism unit test covers input-order independence, which is the root cause, and I confirmed rect stability across a rebuild with my own probe (`[56.0, 169.0, 282.0]` before and after). A one-line rect comparison in the existing 3-lane widget test would make that property explicit in the suite.

## Out-of-scope regression checks

- Commit touches only `lib/ui/planner.dart` and `test/planner_lanes_test.dart` (`git show --stat ad4a0f5`); drag/resize math (`_beginDrag`/`_updateDrag`/`_endDrag`, `:465-525`) is untouched by the diff, so stored times and gesture mapping are unchanged. Confirmed by probe: resize wrote `360..480`, and the back-to-back test's stored times are `420/420`.
- Schema, `lib/domain/plan.dart` and coach tools are not in the commit; the full suite (571 tests, including the coach and planner suites) is green.
- No hardcoded prices or trial logic in this screen (not applicable).
- `dart format` clean (99 files, 0 changed); `flutter analyze` clean.

## Residual risk

The 60-minute two-line layout sits exactly on the compact/column boundary: with the gap the card is 94dp and the threshold is 95-96dp (experiment 5 flips it at 94 vs 96). A 1dp change in the theme's line metrics would silently downgrade a 60-minute card to the one-line row. The new test catches that, which is the point, but the margin is zero — worth knowing if the text theme changes.

**APPROVE.** Lane layout, gap, mid-gesture re-laning, semantics and the round-3 clipping fix are all verified on rendered rects; every new guard is non-vacuous; the reviewed commit is green on format, analyze, planner suite and the full suite.
