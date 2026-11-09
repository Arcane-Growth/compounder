# Gate review — rest-timer audio backlog fixes (5s-minimum tick timing + asset-path test)

- **Task**: Gate: rest-timer audio backlog fixes (5s tick timing + asset-path test) at 41f8e60
- **HEAD reviewed**: `41f8e60` ("Rest timer audio: correct 5s-minimum tick timing; test real cue asset paths")
- **Worktree**: `/home/barry/.cache/review-wt/rest-sounds-fixes` (pinned at `41f8e60`, detached; not the shared checkout)
- **Date**: 2026-11-09
- **Scope**: only the two backlog Minors from `review/rest-timer-sounds-review.md` (Minor 1: 5s-rest off-by-one; Minor 2: no asset-path test). The rest-timer feature itself was gated at `34d21bd` and is not re-reviewed here.
- **Verdict**: **APPROVE** — both Minors are closed, both new guards are non-vacuous, analyze is clean and the full suite is green. Three Nits remain, none blocking.

## What changed

`lib/ui/workout.dart:209-216` — `_startRest` now fires the warning cue immediately when the configured rest is `> 0 && <= 5`, sets `_restTickPlayed = true`, and leaves the periodic path (`:224-227`) unchanged for rests ≥ 6s. The go tone at zero (`:229-232`) is untouched.

`test/rest_sounds_test.dart` — new widget test `a 5s rest ticks at five seconds left, not at four` (`:240`) and new asset test `every cue path resolves to a bundled asset` (`:348`), plus a `storeOpen` guard so the non-seeding asset test does not hit a `LateInitializationError` in `tearDown` (`:98,110,167`).

## What I verified (commands + results, all in the pinned worktree)

1. **Hygiene** — `flutter pub get && flutter analyze` → `No issues found! (ran in 1.9s)`.
2. **Feature file** — `TMPDIR=/home/barry/.cache/flutter-tmp flutter test test/rest_sounds_test.dart` → `00:04 +9: All tests passed!` (7 prior + 2 new).
3. **Full suite** — `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` → `00:14 +460: All tests passed!`.
4. **Timing logic read** — for `seconds = 5`: display `0:05`, immediate tick, flag set, ticks at 4/3/2/1 suppressed, go at 0. For `seconds >= 6`: unchanged (tick at `next == 5`). For `seconds` 1–4: tick at start (closest achievable to "5s remaining"); unreachable through Settings because `AppStore.setRestSeconds` clamps to `5..600` (`lib/data/store.dart:603`), but handled sanely if a stale pref holds a smaller value.
5. **Asset test is real, not a stub** — it loads `AssetManifest` from `rootBundle` and `rootBundle.load` for every `WorkoutCue.values` entry, including `personalRecord` (`pr_fanfare.wav`), and asserts non-zero bytes. All three WAVs are declared in `pubspec.yaml` and present in `assets/sounds/`.

## Non-vacuous guard proofs (revert → quoted failure)

- **Guard 1a — immediate tick at 5s.** Removed the whole `if (seconds > 0 && seconds <= 5) { … }` block (`lib/ui/workout.dart:213-216`), ran the new test:
  `Expected: [WorkoutCue:WorkoutCue.fiveSeconds] / Actual: []` — "the warning cue fires at five seconds remaining" (`test/rest_sounds_test.dart:252`). The pre-fix code fires at 4s remaining, so the assertion catches the original Minor.
- **Guard 1b — tick-once flag.** Kept the immediate tick but removed `_restTickPlayed = true;` from it:
  `Expected: [WorkoutCue:WorkoutCue.fiveSeconds] / Actual: [WorkoutCue:WorkoutCue.fiveSeconds, WorkoutCue:WorkoutCue.fiveSeconds]` — "the tick must fire once, not on every tick below five". The flag is load-bearing, not decorative.
- **Guard 2 — asset paths.** Changed `fiveSeconds('sounds/rest_tick.wav')` → `'sounds/rest_tick.wavv'` in `lib/services/rest_sounds.dart:9`:
  `Which: does not contain 'assets/sounds/rest_tick.wavv'` — "fiveSeconds must be declared in pubspec.yaml as assets/sounds/rest_tick.wavv" (`test/rest_sounds_test.dart:356`). A typo now fails CI instead of silently failing on device.

All three reverts were restored with `git checkout --`; the worktree is clean at `41f8e60` (`git status --short` empty).

## Findings

### Nit 1 — `storeOpen` is never reset, so `tearDown` double-closes the DB after the asset test
`test/rest_sounds_test.dart:98,110,167`. `storeOpen` is set `true` in `seed()` and never set back to `false`; the asset test does not seed, so its `tearDown` calls `store.db.close()` on a store already closed by the preceding test's `tearDown`. Harmless in practice (sqflite treats a second close as a no-op — the suite is green), but the flag does not express what it claims. Fix: `storeOpen = false;` after the close, or `addTearDown` per test.

### Nit 2 — the mute path is not pinned for the immediate tick
The new 5s test runs with sounds enabled; the existing mute test uses the default 7s rest. The immediate tick goes through the same `_playCue` mute check (`lib/ui/workout.dart:239-243`), so the behaviour is correct by construction, but no test would catch a future refactor that bypasses `_playCue` in the immediate branch. Optional: add `seed(restSeconds: 5, soundsEnabled: false)` and assert `played` stays empty.

### Nit 3 — a 1–4s rest fires the tick at start, not at 5s remaining (documented, unreachable)
`lib/ui/workout.dart:213`. For `seconds < 5` the cue fires at the start of the countdown (e.g. 3s remaining). That is the only sensible interpretation, and Settings clamps to 5s minimum, so it is unreachable in the app; the comment explains the intent. No action needed.

## Verdict

**APPROVE.** Minor 1 (5s-rest off-by-one) and Minor 2 (missing asset-path test) are both closed with tests that fail when the fix is reverted — proven above, not asserted. Analyze is clean, the feature file is 9/9 green, and the full suite is 460/460 green at the exact reviewed commit. The three Nits are optional cleanup; none blocks the batch.
