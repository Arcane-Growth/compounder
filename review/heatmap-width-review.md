# Home activity heatmap full-width fix — gate

- **Repo/commit:** `compounder` `3ad9427` ("fix(home): size the activity heatmap preview to the card width", 2 files: `lib/ui/home.dart`, `test/activity_heatmap_test.dart`).
- **Base:** `c1fbf13` (main).
- **Date:** 2026-11-10
- **Mode:** read-only adversarial gate. No source files modified by me. All probes/reverts were done in a pinned worktree (`/tmp/gate-heatmap`, detached at `3ad9427`), restored afterwards; worktree clean (`git status --porcelain` empty) at the reviewed commit.

## Verdict

**APPROVE** — no Blocker, no Major. The fix is correct, minimal, and well-guarded. The preview grid now spans the card content width at 360dp and 320dp/2.0 with no overflow; the cell math is sane (no division-by-zero, no negative/sub-pixel cells at realistic widths); the full-screen `HeatmapScreen` is byte-identical and behaviourally untouched. The new width test is **non-vacuous** (revert failures quoted below). My own gates pass in the pinned worktree:

- `dart format --output=none --set-exit-if-changed lib test tool` → `Formatted 101 files (0 changed)`, exit 0
- `flutter analyze` → `No issues found! (ran in 4.1s)`
- `TMPDIR=/home/barry/.cache/flutter-tmp flutter test test/activity_heatmap_test.dart` → `00:06 +39: All tests passed!`
- `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` (full suite) → `00:20 +610: All tests passed!`

All findings below are **Nit** and do not block merge. The owner may land as-is.

## What the fix does

The home preview previously hardcoded `cellSize: 6, gap: 2`, so the 13 Monday-first columns covered ~104dp of the ~280dp card content area — the squares filled only ~half the card. The fix wraps the `ActivityHeatmap` in a `LayoutBuilder`, derives the column count from the fixed 12-week window via `ActivityHeatmap.weeksFor(start, _today).length`, and computes `cellSize`/`gap` from the card's available width so the grid spans it, keeping cells square. A new `_previewGridMetrics(width, columns)` helper floors the cell to 0.01dp and collapses the gap to zero before cells would drop below 4dp, so a narrow card cannot overflow.

## Per-item verdicts

| # | Requirement | Verdict |
|---|---|---|
| 1 | Preview grid fills the card content width at 360dp and 320dp, no overflow at 320dp (no RenderFlex overflow / negative cell) | **PASS.** Measured from the day squares in a pinned worktree: 360dp → contentW=280, cellSize=19.53, gap=2.0, span=277.89, grid starts at the content edge (offset 20.00), rightSlack=2.11 (no overflow). 320dp/2.0 → contentW=240, cellSize=16.46, gap=2.0, span=237.98, offset 20.00, rightSlack=2.02 (no overflow). `tester.takeException()` is null in both. The 320dp/2.0 test also pins the accessibility text scale. |
| 2 | Cell sizing math is sane: no division-by-zero, no absurdly large or sub-pixel cells, gap/cell ratio still reads as a heatmap | **PASS.** `_previewGridMetrics` guards `columns <= 0 \|\| width <= 0` (no div-by-zero). If `width - gap*columns < 0`, the cell is negative, which is `< 4`, so it takes the gap-collapse branch and `cell = width/columns >= 0` (no negative cells). The cell is floored to 0.01dp, so `total = columns*(cell+gap) <= width` (floor only shrinks, never grows) — overflow is impossible. At realistic widths cells are 16–20dp with a 2dp gap (~10% ratio) — reads as a heatmap. See Nit n2 for the extreme-width sub-4dp case. |
| 3 | Full-screen `HeatmapScreen` untouched in behaviour (scrollable, cellSize, month/weekday labels) | **PASS.** `lib/ui/heatmap.dart` is **byte-identical** between `c1fbf13` and `3ad9427` (`git diff c1fbf13 3ad9427 -- lib/ui/heatmap.dart` is empty). The full-screen grid is `cellSize: 14, gap: 3` (`heatmap.dart:643`), `scrollable` (default true), `showMonthLabels`/`showWeekdayLabels` (default true). The new test "full-screen heatmap stays scrollable at cellSize 14" asserts `scrollable isTrue`, `cellSize 14`, `gap 3`, both label flags true. The pre-existing full-screen tests (opens on newest week, re-pins after failed load / resize, no overflow at 320dp/2.0) all pass. Note: the task text says "cellSize 13" — that is the constructor *default* (`heatmap.dart:139`); the full screen explicitly overrides to 14, and the test correctly pins 14. |
| 4 | New width test is non-vacuous: revert the fix and quote the failing assertion | **PASS.** Reverting `lib/ui/home.dart` to `c1fbf13` (old hardcoded `cellSize: 6, gap: 2`) makes **both** width tests fail on the span assertion (quotes below). I also confirmed the test's design choice is justified: the `ActivityHeatmap` widget box is 280dp wide in *both* the old and new layouts (the inner Row/Column fills the available width even when the squares cover only 102dp), so a widget-box assertion would have passed on the old layout and been vacuous. Measuring from the day squares is the correct, non-vacuous design. |
| 5 | Format/analyze/test run by the reviewer, not taken on trust | **PASS.** Commands and outputs above, all run by me in the pinned worktree at `3ad9427`. |

## Non-vacuity proof

Probe applied in the pinned worktree, then reverted (`cp` back to the fixed file); worktree clean afterwards.

**Revert** — `git show c1fbf13:lib/ui/home.dart > lib/ui/home.dart` (restores the old hardcoded `cellSize: 6, gap: 2`, removes the `LayoutBuilder` + `_previewGridMetrics`). Re-ran `flutter test test/activity_heatmap_test.dart --plain-name "home preview grid spans the card width"`:

```
00:01 +0 -1: home screen home preview grid spans the card width at 360dp [E]
  The following TestFailure was thrown running a test:
  Expected: a value greater than or equal to <277.0>
    Actual: <102.0>
     Which: is not a value greater than or equal to <277.0>
  the preview squares must span the full card content width at 360dp, not the old fixed 6dp cell (~112dp)
  #4 main.<anonymous closure>.expectGridFillsCard (test/activity_heatmap_test.dart:1097:7)

00:01 +0 -2: home screen home preview grid spans the card width at 320dp/2.0 [E]
  The following TestFailure was thrown running a test:
  Expected: a value greater than or equal to <237.0>
    Actual: <102.0>
     Which: is not a value greater than or equal to <237.0>
  the preview squares must span the full card content width at 320dp/2.0, not the old fixed 6dp cell (~112dp)
  #4 main.<anonymous closure>.expectGridFillsCard (test/activity_heatmap_test.dart:1097:7)
```

The old layout's square span is 102dp (13×6 + 12×2), far below the 277/237 thresholds — so the guard catches the regression. Restoring the fix re-ran green (`+39: All tests passed!`).

**Why measuring from the squares (not the box) is the right call** — probed `tester.getRect(find.byType(ActivityHeatmap)).width` in both layouts at 360dp:

```
NEW layout (3ad9427):  BOX 360dp: ActivityHeatmap width=280.0 leftOff=40.0
OLD layout (c1fbf13):  BOX 360dp: ActivityHeatmap width=280.0 leftOff=40.0
```

The box is 280dp in both, so a box-width assertion would pass on the old (broken) layout — vacuous. The day-square span (102dp old vs 277.89dp new) is what actually discriminates. This matches the commit message's stated rationale.

## Findings

### Nit

**n1 — Task text says "cellSize 13"; the full-screen grid is 14.**
- The task's check item reads "cellSize 13". The full-screen `HeatmapScreen` passes `cellSize: 14` (`lib/ui/heatmap.dart:643`); `13` is only the `ActivityHeatmap` constructor default (`:139`). The new test correctly asserts `14`. No code change needed — this is a task-description inaccuracy, flagged so the record is precise.

**n2 — `_previewGridMetrics` doc: "gap collapses … before cells would drop below 4dp" is slightly imprecise at extreme widths.**
- The gap collapses when the *with-gap* cell would be `< 4dp` (i.e. `width < 6*columns`, ~78dp for 13 columns). After collapsing, `cell = width/columns`, which can itself drop below 4dp if the card is narrower than ~52dp (e.g. a 10dp card → 0.77dp cells). That is sub-pixel, but it cannot overflow (floor + gap-collapse keep `total <= width`). At every realistic width (320dp and up) cells are 16–20dp, so the 4dp threshold is never reached in practice. The key guarantee ("can never overflow") holds. Optional: tighten the doc to "the gap collapses to zero once cells would drop below 4dp; below that the cells shrink but never overflow."

**n3 — The 320dp/2.0 test duplicates the provider/host setup instead of reusing `host`.**
- The 360dp test uses the `host(...)` helper, but the 320dp/2.0 test builds its own `MultiProvider`/`MaterialApp`/`ShellNav` because it needs to inject `textScaler: 2.0`, which `host` does not accept. This is a reasonable choice, but it duplicates the three-provider setup. Optional: add a `TextScaler?` (or `double textScale`) parameter to `host` and route both tests through it. Style/maintainability only.

**n4 — `weeksFor` is computed twice for the preview.**
- The `LayoutBuilder` calls `ActivityHeatmap.weeksFor(start, _today).length` for the column count, and `ActivityHeatmap.build` calls `weeksFor(start, end)` again to lay out the grid. For a 12–13 column window this is negligible, but it is duplicated work on every rebuild. Optional: compute the columns once and pass the count in, or cache. Not a defect.

## Residual risk

- **Tests only; no device run.** The width behaviour is covered by widget tests at 360dp and 320dp/2.0 (measured from the rendered squares), not by a real-device screenshot. The math is deterministic and the probe confirms the rendered sizes, so risk is low.
- **The 4dp gap-collapse threshold is a heuristic, not a hard minimum.** At extreme card widths (< ~52dp) cells go sub-4dp (see n2) but never overflow. No realistic phone/split-screen width reaches this.
- **Trailing gap.** Each grid column carries a right `gap`, so the last column's trailing 2dp is empty space; the square span is ~2dp narrower than the content width. This is inherent to `ActivityHeatmap`'s column layout (same as the full-screen grid) and is within the test's 3dp tolerance. Consistent, not a regression.
