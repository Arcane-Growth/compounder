# Gate: day planner drag-to-size timeline UX

**Reviewed commit:** `82dd783` (`feat(planner): direct-manipulation day timeline`) plus the
uncommitted working-tree diff (`lib/ui/planner.dart` +24, `test/planner_test.dart` +26).
**Reviewer:** Code Reviewer. **Date:** 2026-11-10.
**Worktree:** `/home/barry/.cache/review-planner-ux` (detached at `82dd783`, working-tree patch applied).

## Verdict: BLOCK

Three data-loss/correctness bugs, three accessibility/clipping defects, and three
regression guards that are provably vacuous (removing the fix leaves the suite green).
The feature is close — the architecture (local-day minute offsets, no schema change,
single validation boundary) is sound — but it is not shippable as-is.

## What I ran

```
flutter analyze                       -> No issues found! (ran in 3.5s)
flutter test test/planner_test.dart   -> 00:02 +15: All tests passed!
```

Both run by me in the pinned worktree with `TMPDIR=/home/barry/.cache/flutter-tmp`.
Schema v13 and `PlanBlock` are untouched (`lib/domain/plan.dart` unchanged in the commit);
existing blocks load through `planBlocksForDay` unchanged. No migration risk.

## Blockers

### B1. A drag that returns to its origin silently moves/resizes the block and persists it
`lib/ui/planner.dart:370` — `if (delta == 0) return;` skips the `setState`, so the live
candidate times are never recomputed from `_dragBaseStart`/`_dragBaseEnd` when the
cumulative delta snaps back to zero. The block stays at the last snapped position and
`_endDrag` writes it.

Reproduced (probe, 400x900, block 01:00-02:00):
```
PROBE7 start=75 end=135   (drag +20px then -20px; expected 60/120)
PROBE8 start=60 end=135   (resize +20px then -20px; expected 60/120)
```
Fix: drop the early return and always recompute `_dragStart`/`_dragEnd` from the base
(`_dragBaseStart + delta`). Verified: with the early return removed, PROBE7/8 pass and
the full suite stays green.

### B2. Starting a drag discards an open inline editor — typed text is lost
`lib/ui/planner.dart:358-359` — `_beginDrag` clears `_creatingStart` and `_editingId`
without committing. `_startCreate`/`_startEdit` commit the previous editor first; the
drag path does not.

Reproduced:
```
PROBE17 aTitle=Block A   (edited A to "Renamed A", then dragged B; expected "Renamed A")
PROBE18 titles=[Block B] (typed "New thing" in a create editor, then dragged B)
```
Fix: in `_beginDrag`, commit `_commitCreate()` / `_commitEdit(current)` before clearing.
Verified: with that guard added, PROBE17/18 pass and the full suite stays green.

### B3. Undo after a day switch recreates the block on the wrong day
`lib/ui/planner.dart:444` — `_undoDelete` uses the *current* `_day`, not the day the
block was deleted from. The snackbar outlives a day shift.

Reproduced:
```
PROBE2 original=0 next=1   (deleted on 11-09, shifted to 11-10, tapped Undo)
```
Fix: capture `final day = _day;` in `_deleteBlock` and pass it to `_undoDelete`.
Verified: with that change, PROBE2 passes (`original=1 next=0`).

## Major

### M4. Resize handle is a 16dp touch target
`lib/ui/planner.dart:26` (`_handleHeight = 16`), `:825` (`height: _handleHeight`).
Measured: `PROBE4 handle=16.0 body=80.0`; for a 15-minute block `PROBE11 body=32.0
handle=16.0`. The Material minimum is 48dp. The handle is the only way to resize, and
it is the smallest target on the screen. Fix: keep the visual strip 16dp but wrap it in
a 48dp-tall `GestureDetector` (or use `Padding`/`SizedBox` with `behavior: opaque`).

### M5. Blocks and editors at the end of the day are clipped by the Stack
`lib/ui/planner.dart:569` — the `Stack` uses the default `Clip.hardEdge`; `:668` clamps
the card to `_minCardHeight` (48dp) without accounting for the grid's 2304dp extent.

Reproduced:
```
PROBE13 gridBottom=868.0 handleTop=876.0 handleBottom=892.0  (23:45-24:00 block)
PROBE14 gridBottom=900.0 fieldBottom=922.0                   (create editor at 23:45)
```
The resize handle for a 23:45-24:00 block is entirely below the grid bottom — invisible
and unreachable. Fix: `clipBehavior: Clip.none` on the Stack, or clamp the card top so
`top + height <= 2304`.

### M6. Compact card overflows at 320dp / 2.0 text scale
`lib/ui/planner.dart:766-779` — the compact `Row` puts the time label in a bare `Text`
after `Expanded(title)`; the label has no width constraint.

Reproduced:
```
PROBE15 exception=A RenderFlex overflowed by 256 pixels on the right.
```
The existing 320dp/2.0 test (`test/planner_test.dart:408-425`) uses a 60-minute block,
which takes the non-compact `Column` path, so it never exercises this. Fix: wrap the
time label in `Flexible` with `overflow: TextOverflow.ellipsis`, or drop the label when
`compact`.

### M7. Vacuous guard: `didChangeMetrics` is not tested
`lib/ui/planner.dart:163-171`, test `test/planner_test.dart:123-147`.
Removing the whole `didChangeMetrics` override leaves the suite green:
```
=== A: revert didChangeMetrics (keyboard reveal) ===
00:00 +1: All tests passed!
```
The test taps 07:00, which `_revealEditor` (called from `_startCreate`) already puts at
20% of the viewport, so the inset change never needs to move anything. Either delete the
handler (it is redundant for the create/edit paths) or add a test that scrolls the field
toward the bottom before changing insets — PROBE12 shows the handler does move the field
(281 vs 188) in that case.

### M8. Vacuous guard: the create-path snap is not tested
`lib/ui/planner.dart:462-463` (`_snap`), test `test/planner_test.dart:89-121`.
Replacing `_snap` with a plain clamp leaves the suite green:
```
=== D: revert 15-min snap in _snap ===
00:00 +1: All tests passed!
```
The create test taps exactly 375 (a 15-minute boundary), and the resize test exercises
`_updateDrag`, not `_snap`. PROBE9 (tap at 380) confirms the snap works (375), but no
committed test would catch its removal.

### M9. Vacuous guard: the minimum card height is not tested
`lib/ui/planner.dart:668`, test `test/planner_test.dart:211-230`.
Removing the `_minCardHeight` clamp leaves the suite green:
```
=== F: revert _minCardHeight clamp ===
00:00 +1: All tests passed!
```
The move test uses a 60-minute block (96dp), so the clamp never applies. A 15-minute
block is the case that needs it.

### M10. Accessibility: the resize handle has no action; the done toggle announces no state
`lib/ui/planner.dart:826-827` — `Semantics(label: 'Resize ...')` with no `onIncrease`/
`onDecrease`/custom action. A screen-reader user can hear the label but cannot resize.
`lib/ui/planner.dart:859-861` — `Semantics(label: block.title)` on the done toggle omits
`checked`/`toggled`, so the state is not announced (the comment claims the icon reports
it, but the icon is a child of the `Semantics` node and its own semantics are merged
away by the explicit label). Fix: `Semantics(button: true, checked: block.done, ...)` and
`onIncrease`/`onDecrease` (or `CustomSemanticsAction`) for resize.

## Minor

- **M11.** Tapping the resize strip does nothing (`lib/ui/planner.dart:828-835`): it has
  only drag handlers, so the bottom 16dp of every card is a dead zone for the tap-to-rename
  gesture. PROBE6: `inline=0`. Add `onTap: () => _startEdit(block)`.
- **M12.** `_deleteBlock` (`lib/ui/planner.dart:427-435`) shows "Deleted ..." even when
  `_runWrite` failed and already showed an error snackbar — two contradictory snackbars.
- **M13.** `_commitCreate` error path (`lib/ui/planner.dart:283-293`) calls
  `_inlineFocus.unfocus()` then restores `_creatingStart` without refocusing, so the
  keyboard closes and the user must tap the field again to shorten the title.
- **M14.** `_setDay` (`lib/ui/planner.dart:225-236`) clears `_creatingStart`/`_editingId`
  but not `_inline.text`; the stale text is visible for one frame if an editor reopens.
- **M15.** `_undoDelete` (`lib/ui/planner.dart:443-448`) recreates the row with a new id
  and a fresh `position`/`createdAt`; the block's ordering among same-start blocks can
  change after undo.
- **M16.** `_updateDrag` calls `setState` on every pointer event (`lib/ui/planner.dart:366-383`),
  rebuilding the whole timeline including the static 73-widget grid (`:588-629`). At
  60-120Hz this is a per-event rebuild storm; the grid should be a separate `const`/cached
  subtree behind a `RepaintBoundary`, and the drag should be driven by a `ValueNotifier`
  rather than `setState`.

## Nits

- **N17.** The hour-24 divider (`lib/ui/planner.dart:596-606`) sits at `top: 2304` and is
  clipped by the Stack; harmless but dead.
- **N18.** `_scrollToNow` (`lib/ui/planner.dart:215-222`) sets `_scrolledToNow = true`
  before the post-frame callback; if the controller is not attached, it never retries.
- **N19.** `didChangeMetrics` (`lib/ui/planner.dart:163-171`) fires on rotation and any
  inset change, `jumpTo`-ing the grid and fighting a user scroll. If kept, gate it on a
  real keyboard-inset delta.

## Verified clean

- `flutter analyze`: no issues.
- `flutter test test/planner_test.dart`: 15/15 pass.
- No schema change; `PlanBlock`/`planBlockError`/`planBlocksForDay` untouched.
- Existing blocks load and render; resize/move persist through `updatePlanBlock` with
  merged-row validation.
- Stale-day query guard (`_generation`) is non-vacuous: reverting it fails the stale-query
  test (`Found 0 widgets with text "Block for day 11"`).
- Midnight rollover guard (`_showedToday`) is non-vacuous: reverting it fails the rollover
  test (`Found 1 widget with text "Now 23:59"`).
- Cumulative drag delta (`_dragDelta`) is non-vacuous: reverting it fails the resize test
  (`Expected: <180> Actual: <165>`).
- 320dp/2.0 non-compact path and the empty state do not overflow.
- No hardcoded prices/trial logic in this screen (not applicable).

## Required before re-review

1. Fix B1, B2, B3 (each has a verified patch above).
2. Fix M4, M5, M6.
3. Make M7, M8, M9 non-vacuous (add the missing tests or delete the dead handler).
4. Address M10 (semantics) — or document the deferral.

Probe files used for this gate (`test/probe_test.dart`, `probe2`-`probe7`) are throwaway
and were not committed; each finding above quotes the failing assertion.
