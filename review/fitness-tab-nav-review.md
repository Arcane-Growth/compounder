# Gate: Fitness tab + nav split + heatmap auto-scroll (7debe8b)

**Verdict: APPROVE WITH FIXES** — the change is correct on every primary path and
the regression guards are genuinely non-vacuous. Three Minor items and three Nits
below; none of them is a data-loss or crash risk. Fix Minor 1 and 2 before calling
this done.

- Reviewed commit: `7debe8b` ("Add real Fitness tab, drop Mind from bottom bar, open
  Activity heatmap on newest week"), parent `df0c5c7`.
- Pinned worktree: `/home/barry/.cache/review-wt/fitness-nav-gate` (detached at
  `7debe8b`), `TMPDIR=/home/barry/.cache/flutter-tmp`. Shared checkout untouched.
- Device verification was **not** re-run (owner was using the phone); the dev's
  uiautomator dumps are the device evidence and are consistent with the code.

## Findings

### Minor 1 — heatmap loses the newest-week pin after a failed load + "Try again"
`lib/ui/heatmap.dart:435` (`_pinnedToNewest`), `:520-527` (`_onGridMetrics`),
`:545-553` (error branch).

`_pinnedToNewest` is never reset when the grid subtree is torn down. The `_error`
branch replaces the `ListView` with a `Column`, so the `SingleChildScrollView` and
its `ScrollPosition` are destroyed. On "Try again" the grid is rebuilt with a fresh
position at offset 0; `_onGridMetrics` then sees the same `viewportDimension`, so
`resized` is false and `_pinnedToNewest` is still true → no re-pin. The screen shows
the oldest week again — the exact defect this change fixes.

Proven with a throwaway probe (fake store that throws on the first
`dailyPillarActivity`, then succeeds): after error → retry the today cell rect is
`Rect.fromLTRB(961.5, 268.0, 975.5, 282.0)` (off-screen at 800dp), versus
`Rect.fromLTRB(743.0, 268.0, 757.0, 282.0)` on the normal path.

Fix (minimal): set `_pinnedToNewest = false` in the `catch` branch that sets
`_error`. Fix (robust): remember the pinned `ScrollPosition` and reset the flag when
`_gridScroll.position` is a different object, e.g.

```dart
ScrollPosition? _pinnedPosition;
// in _onGridMetrics:
final position = _gridScroll.hasClients ? _gridScroll.position : null;
if (position != _pinnedPosition) { _pinnedPosition = position; _pinnedToNewest = false; }
```

### Minor 2 — bottom-bar order is not pinned by any test
`test/fitness_nav_test.dart:140-146`, `lib/ui/shell.dart:107-113`.

The test asserts presence and `destinations.length == 5`, not order. Swapping
`Macros` and `Wealth` in `ShellBottomBar.destinations` leaves all 45 nav/heatmap
tests green (verified: `00:05 +45: All tests passed!`). Because the bar index *is*
the tab index, a reorder silently opens the wrong tab — the exact failure mode this
gate is meant to catch.

Fix: assert the sequence, e.g.
`expect(ShellBottomBar.destinations.map((d) => d.label).toList(), ['Home','Fitness','Macros','Wealth','Coach'])`,
and/or tap each destination and assert the resulting `IndexedStack.index`.

### Minor 3 — new bottom bar has no small-screen / textScale overflow test
`lib/ui/shell.dart:105-213`.

The repo convention is to pin every new UI surface at 320dp / textScale 2.0
(`test/activity_heatmap_test.dart:845`, `test/drawer_a11y_test.dart:164`). The new
`ShellBottomBar` is not covered by any such test. I probed it directly: clean at
320x640 / textScale 2.0 (no exception, `All tests passed!`), so this is a coverage
gap, not a defect. Fix: add the assertion to `fitness_nav_test.dart`.

### Nit 1 — heatmap test bound is the screen width, not the grid viewport
`test/activity_heatmap_test.dart:790`. `width` is 800 while the grid viewport is
~728 (20dp page padding + 16dp card padding each side). The assertion would still
pass if the newest cell sat under the card padding. Tighten it to the grid's
viewport rect.

### Nit 2 — exercise library pops on tap
`lib/ui/picker.dart:97`. `ExercisePickerScreen(title: 'Exercises')` is opened as a
browser, but tapping any row pops the route and discards the id. Harmless, but the
user is ejected from the library on the first tap. Consider a no-op `onTap` or a
detail sheet in library mode.

### Nit 3 — two hand-maintained destination lists
`lib/ui/drawer.dart:75-82` and `lib/ui/shell.dart:107-113` must stay aligned with
`tabHome..tabMind`. One source of truth (a single list plus a `bottomBarCount`)
would remove the drift risk.

## What I verified (all run by me at 7debe8b in the pinned worktree)

**Gates**
- `flutter analyze` → `No issues found! (ran in 1.7s)`.
- `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` → `00:12 +416: All tests
  passed!` (exit 0), re-run after every experiment: same result.
- `dart format --output=none --set-exit-if-changed` on the 10 changed files → 5
  dirty (`heatmap.dart`, `home.dart`, `picker.dart`, `activity_heatmap_test.dart`,
  `drawer_a11y_test.dart`). All 5 are **already dirty at `df0c5c7`** (verified by
  formatting `git show df0c5c7:<path>` copies), so this change adds no new
  formatting debt. Not a finding.

**Non-vacuity proofs (revert the fix, quote the failure)**
1. Comment out `_gridScroll.jumpTo(max)` (`heatmap.dart:514`) → both new tests fail:
   `Expected: a value less than or equal to <800.0> / Actual: <975.5>` and
   `Expected: ... <400.0> / Actual: <975.5>`.
2. Remove only the resize branch (`if (!_pinnedToNewest || resized)` →
   `if (!_pinnedToNewest)`) → the resize test fails
   `Expected: ... <400.0> / Actual: <757.0>` while the open test still passes
   (`+1 -1`), so the resize guard is independently pinned.
3. Remove the FitnessTab visibility gate (`if (_visible) _reload()` → `_reload()`)
   → `fitness_nav_test` fails `Expected: <0> / Actual: <1>` (`+1 -3`).
4. Swap `Mind`/`Coach` in `AppDrawer.destinations` → `drawer_a11y_test` and
   `fitness_nav_test` fail `Expected: <5> / Actual: <4>` (`+12 -2`), so the
   drawer↔IndexedStack mapping is pinned.

**Code review (clean)**
- Nav indices: `tabHome..tabMind` = 0..5, `AppDrawer.destinations` order matches
  exactly, `ShellBottomBar.destinations` = 0..4, `_tabs` matches, drawer
  `currentIndex` highlights Mind at 5, bar shows `-1` for Mind. No literal indices
  remain in `lib/` (all call sites use the constants).
- Mind is drawer-only and reachable; `HomeTab`'s Mind pillar now calls `tabMind`.
- FitnessTab reuses `WorkoutScreen`/`HistoryScreen`/`ProgressScreen`/
  `ExercisePickerScreen`; `askWorkoutName` moved to `widgets.dart` with no duplicate
  copy left in `home.dart`. Resume card is driven by `store.activeWorkout()` and
  reloads after the workout route pops.
- Visibility gate mirrors the `ShellNav.visible` pattern (debounced listener,
  `becameVisible` catch-up, generation counter, `mounted` checks). Dispose cancels
  the debounce timer and removes the store listener; no `WidgetsBindingObserver` is
  added, so there is nothing else to leak.
- Heatmap: `hasClients` + `max <= 0` guards mean no jump before first layout and no
  exception when `maxScrollExtent` is 0; `_gridScroll.dispose()` is called; the
  post-frame callback is `mounted`-guarded. The grid stays alive across a
  -3000dp/+3000dp scroll of the screen's ListView (probed: rect unchanged), so the
  detach/reattach path is not reachable in this layout.
- Bottom bar: `Semantics(button, selected, label, onTap, excludeSemantics)` is
  correct — the tap action is declared because `excludeSemantics` drops the
  InkWell's own action; the test pins it.
- Tests updated for the new nav: `drawer_a11y_test` uses the tab constants, taps
  Mind from the drawer, and asserts index 5; `activity_heatmap_test` uses
  `tabMacros`/`tabCoach`/`tabWealth`. No assertion was weakened except the
  `ShellNav` stability test now reads `.first` (HomeTab's) instead of the single
  shell-wide `ShellNav` — acceptable, since per-tab `ShellNav`s are the new design.

## Residual risk
- Device smoke test was done by the dev, not re-run here (phone in use). The
  heatmap fix is proven by widget test at 800x600 and 400x800; real-device
  rotation was not exercised.
- Minor 1 only manifests after a transient DB failure; the normal open path is
  correct.
