# Gate round 3: planner timeline — N1/N2 clipping fix (narrow confirmation)

**Reviewed commit:** `cc84025` (`fix(planner): derive the card body from the post-handle height`), branch `feat/planner-timeline`.
**Round-2 verdict:** `review/planner-ux-review-round2.md` @ `9b2fb32` (APPROVE WITH FIXES — N1/N2 Majors).
**Reviewer:** Code Reviewer. **Date:** 2026-11-10.
**Worktree:** `/home/barry/.cache/review-wt/planner-r3` (detached at `cc84025`, clean; only the throwaway `test/_r3_probe_test.dart` added, removed before the full-suite run).
**Scope:** N1 and N2 only. B1–B3 and M4–M10 are accepted as fixed and were not re-litigated.

## Verdict: APPROVE

N1 and N2 are fixed and independently reproduced with my own probes (not the developer's tests). The
new bounds-based guard is non-vacuous: reverting `lib/ui/planner.dart` to `cc84025^` fails all ten
new duration/scale cases plus the 320dp/2.0 case, with the exact clipping assertions quoted below.
Nothing outside scope regressed. No new Blockers or Majors.

## What I ran (pinned worktree, `TMPDIR=/home/barry/.cache/flutter-tmp`)

```
flutter analyze                                  -> No issues found! (ran in 3.2s)
dart format --output=none --set-exit-if-changed  -> Formatted 99 files (0 changed)
flutter test test/planner_test.dart              -> 00:04 +37: All tests passed!
flutter test test/_gate_probe_test.dart          -> 00:00 +1: All tests passed!
flutter test (full suite)                        -> 00:18 +556: All tests passed!
```

## N1 — 35/40/45/50/53-minute blocks render the full time label

Probe `test/_r3_probe_test.dart` (mine), 400x900 surface, block at 09:00, rects read with
`tester.getRect` on `plan-card-$id`, `plan-block-$id` and the rendered `Text` widgets. The grid
auto-scrolls to 12:00, so absolute tops are negative; the body/label relationship is what matters.

| duration | scale | cardH | bodyH | handleH | bodyBottom | labelBottom | labelBottom<=bodyBottom | titleBottom |
|---|---|---|---|---|---|---|---|---|
| 35 | 1.0 | 56.0 | 27.0 | 29.0 | 3.0 | -2.5 | yes (5.5dp margin) | -0.5 |
| 40 | 1.0 | 64.0 | 27.0 | 37.0 | 3.0 | -2.5 | yes (5.5dp) | -0.5 |
| 45 | 1.0 | 72.0 | 27.0 | 45.0 | 3.0 | -2.5 | yes (5.5dp) | -0.5 |
| 50 | 1.0 | 80.0 | 32.0 | 48.0 | 8.0 | 0.0 | yes (8.0dp) | 2.0 |
| 53 | 1.0 | 84.8 | 36.8 | 48.0 | 12.8 | 2.4 | yes (10.4dp) | 4.4 |
| 35 | 2.0 | 63.0 | 47.0 | 16.0 | 23.0 | 15.5 | yes (7.5dp) | 19.5 |
| 40 | 2.0 | 64.0 | 47.0 | 17.0 | 23.0 | 15.5 | yes (7.5dp) | 19.5 |
| 45 | 2.0 | 72.0 | 47.0 | 25.0 | 23.0 | 15.5 | yes (7.5dp) | 19.5 |
| 50 | 2.0 | 80.0 | 47.0 | 33.0 | 23.0 | 15.5 | yes (7.5dp) | 19.5 |
| 53 | 2.0 | 84.8 | 47.0 | 37.8 | 23.0 | 15.5 | yes (7.5dp) | 19.5 |

Raw probe lines (excerpt):

```
PROBE30 dur=45 scale=1.0 cardH=72.0 bodyBottom=3.0 handleH=45.0 labelBottom=-2.5 labelClippedV=false titleClippedV=false labelClippedH=false
PROBE30 dur=50 scale=1.0 cardH=80.0 bodyBottom=8.0 handleH=48.0 labelBottom=0.0 labelClippedV=false titleClippedV=false labelClippedH=false
PROBE30 dur=53 scale=1.0 cardH=84.8 bodyBottom=12.8 handleH=48.0 labelBottom=2.4 labelClippedV=false titleClippedV=false labelClippedH=false
PROBE30 dur=45 scale=2.0 cardH=72.0 bodyBottom=23.0 handleH=25.0 labelBottom=15.5 labelClippedV=false titleClippedV=false labelClippedH=false
```

The mechanism matches the commit: `lib/ui/planner.dart:798-804` now derives `compact`/`handleHit`
from the body left after the strip (`columnFits` at `:799`, `handleHit` at `:802-804`), and
`_cardHeight` (`:745-749`) guarantees `height >= compactContent + _minHandleHit + _minBodySlack`,
so the body can never be shorter than the one-line content. The `if (showTimes)` guards are gone
(`:862-879`, `:895-909`), so the label is always rendered. No horizontal truncation either
(`labelClippedH=false` at 400dp and at 320dp).

## N2 — 2.0 text scale: title and label are not vertically clipped

```
PROBE31 dur=30 scale=2.0 surface=320x640 cardH=63.0 bodyH=47.0 handleH=16.0
        titleBottom=19.5 labelBottom=15.5 bodyBottom=23.0
        titleClippedV=false labelClippedV=false titleClippedH=false labelClippedH=false
```

Title and label both end above `bodyBottom` at 320dp/2.0 (3.5dp and 7.5dp margins). The same holds
for 35–53 minutes at 2.0 on a 400dp surface (table above) and for 15- and 60-minute blocks
(`PROBE32`/`PROBE33`: 15-min 2.0 → bodyBottom 23.0, titleBottom 19.5, labelBottom 15.5; 60-min 2.0
→ bodyBottom 24.0, titleBottom 20.0, labelBottom 16.0).

## Non-vacuity — revert-and-quote

`git checkout cc84025^ -- lib/ui/planner.dart`, keeping the new tests:

```
flutter test test/planner_test.dart --plain-name "shows its full time label"
-> 00:02 +0 -9: Some tests failed.   (all ten duration/scale cases fail)
```

Exact failure for the 45-minute / 1.0 case (`test/planner_test.dart:688`):

```
Expected: a value less than or equal to <0.0>
  Actual: <16.0>
   Which: is not a value less than or equal to <0.0>
the time label must not be clipped by the card body
```

Exact failure for the 320dp / 2.0 case (`test/planner_test.dart:684`):

```
Expected: a value less than or equal to <0.0>
  Actual: <18.0>
   Which: is not a value less than or equal to <0.0>
the title must not be clipped by the card body
```

Restored `lib/ui/planner.dart` to `cc84025` → `flutter test test/planner_test.dart` → `+37: All
tests passed!`. The guard asserts rendered rects (`test/planner_test.dart:673-690`), not
`takeException()`, so it cannot pass while a `ClipRect` hides the overflow.

## Out-of-scope regression checks

- Fix commit touches only `lib/ui/planner.dart` and `test/planner_test.dart` (`git show
  --name-only cc84025`).
- Schema still v13 (`lib/data/store.dart:121`); `git diff --stat cc84025^ cc84025 -- lib/data/store.dart`
  is empty.
- `lib/domain/plan.dart` unchanged between `cc84025^` and `cc84025` (empty diff).
- Coach tools untouched: `lib/coach/tools.dart:1383` (`createPlanBlock`) is not in the commit; the
  full suite (556 tests, including `planner_coach_test.dart` and the coach suites) is green.
- `test/_gate_probe_test.dart` present (686 bytes, from `f1300de`) and passes 1/1.
- `dart format` clean (99 files, 0 changed); `flutter analyze` clean.
- No hardcoded prices/trial logic in this screen (not applicable).

## Minor observations (non-blocking, no action required for this batch)

1. **15-minute card resize strip is now 21dp at 1.0** (was 24dp before the fix): body content 25dp
   + 2dp slack leaves 21dp. Same family as round-2 N3 (sub-48dp strip on short cards), just 3dp
   smaller. The strip is still a real hit target and `Semantics(onIncrease/onDecrease)` at
   `lib/ui/planner.dart:922-925` exposes resize to assistive tech.
2. **16dp strip at 2.0 text scale** for 35–53 minute cards — a deliberate tradeoff (text wins over
   touch target) and documented in the code comment at `:793-797`.
3. **Cards grow past their slot at 2.0** (35-min: 63dp vs a 56dp slot; 15-min: 63dp vs 24dp), so a
   card can overlap the next slot by up to 15dp. Documented in the commit message; at 1.0 no card
   grows beyond the pre-existing 48dp minimum, so normal-scale layout is unchanged.
4. **Perf (opinion, Minor):** `_bodyContentHeights` (`:731-740`) runs three `TextPainter` layouts
   and is called twice per block per build (once in `_cardHeight`, once in `_blockCard`) — six
   short-text layouts per block per frame, including every drag update. Cheap for these strings,
   but caching the heights per text scale would remove it entirely.

## Residual risk

The invariant depends on `_lineHeight` (`:718-727`) matching the rendered line height. Measured
rendered lines are 20dp (title, 1.0) / 40dp (title, 2.0) / 16dp (label, 1.0), and `_lineHeight`
returns 21 / 41 / 17 respectively, so the +1dp headroom holds. If the theme's text styles change,
the same styles feed both the measurement and the layout, so the invariant recomputes consistently.

**APPROVE.** N1 and N2 are fixed, the guard is non-vacuous, and the reviewed commit is green on
format, analyze, planner suite and the full suite.
