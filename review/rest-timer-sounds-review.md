# Gate review — rest-timer audio cues + mute toggle

- **Task**: Gate: rest timer audio cues + mute toggle (compounder)
- **HEAD reviewed**: `34d21bd` ("Rest timer audio cues: 5s warning tick, go tone at zero, mute setting")
- **Worktree**: `/home/barry/.cache/review-wt/rest-sounds` (pinned at `34d21bd`, detached; not the shared checkout)
- **Date**: 2026-11-09
- **Verdict**: **APPROVE WITH FIXES** — the feature works and every load-bearing guard is non-vacuous. Two Minors (a 5s-rest off-by-one and a missing asset-path test) and four Nits remain; none blocks the batch.

## What I verified (commands + results)

1. **Hygiene** — `flutter analyze` in the pinned worktree → `No issues found! (ran in 1.1s)`.
2. **Full suite** — `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` → `00:14 +426: All tests passed!` (baseline 419 + 7 new).
3. **Feature tests** — `flutter test test/rest_sounds_test.dart` → `00:04 +7: All tests passed!`.
4. **Android build** — `JAVA_HOME=…/temurin-17.0.21+9 flutter build apk --debug` → `✓ Built build/app/outputs/flutter-apk/app-debug.apk` (34.3s). The new `audioplayers` dependency does not break the AGP 9 built-in-Kotlin build.
5. **Assets bundled** — `unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep sounds` → `assets/flutter_assets/assets/sounds/rest_go.wav` (20152 B) and `assets/flutter_assets/assets/sounds/rest_tick.wav` (6218 B). No network fetch: `AssetSource` reads the bundle.
6. **WAV format** — mono 16-bit PCM 44.1 kHz; tick 70 ms peak 0.16, go 228 ms peak 0.32. Small, no oversized assets.
7. **Silent-mode / music** — read the plugin sources: `audioplayers_android-5.3.0` `AudioContextAndroid.buildAttributes()` maps `usageType: media` → `AudioAttributes.USAGE_MEDIA` (STREAM_MUSIC, audible with the ringer off), and `FocusManager.maybeRequestAudioFocus()` returns `onGranted()` without requesting when `audioFocus == AUDIOFOCUS_NONE` (no ducking/interruption). `audioplayers_darwin-6.5.0` applies `AVAudioSessionCategory.playback` + `.mixWithOthers` (ignores the mute switch, mixes with other audio). The claims hold.
8. **Settings** — `lib/ui/settings.dart:348` switch is wired to `store.setRestSoundsEnabled`; `lib/data/store.dart:574-577` defaults to `true` and persists `restSoundsEnabled`; `lib/ui/workout.dart:237` reads the live value at cue time, so the mute is honoured by the timer path, not just stored.

## Non-vacuous guard proofs (revert → quoted failure)

- **Mute guard** — removed `if (!(_store?.restSoundsEnabled ?? false)) return;` (`lib/ui/workout.dart:237`): `the mute setting suppresses both cues` → `Expected: empty / Actual: [RestCue.fiveSeconds, RestCue.go]`.
- **Tick-once guard** — removed `&& !_restTickPlayed` (`lib/ui/workout.dart:216`): `plays one tick at 5s left and one go tone at zero` → `Expected: [RestCue.fiveSeconds] / Actual: [ … ]` (repeated tick).
- **Cancel guard** — removed `_restTimer?.cancel()` and `_restGeneration++` from `_cancelRest` (`lib/ui/workout.dart:229-233`): `cancelling the rest early produces no go tone` → `Expected: [RestCue.fiveSeconds] / Actual: [RestCue.fiveSeconds, RestCue.go]`.
- **Dispose audio guard** — removed `unawaited(_sounds.dispose());` (`lib/ui/workout.dart:62`): `disposing the screen mid-rest fires no cue and disposes audio` → `Expected: true / Actual: <false>`.
- **Dispose timer/mounted/generation chain** — removed `_restTimer?.cancel()` from `dispose`, the `generation != _restGeneration` check and the `!mounted` check: `A ValueNotifier<int> was used after being disposed.` at `test/rest_sounds_test.dart` (dispose test).
- **Restart guard** — removed `_restTimer?.cancel()` from `_startRest` and the generation check: `restarting the rest timer does not leak a stale cue` → `Expected: [RestCue.fiveSeconds, RestCue.go] / Actual: [RestCue.fiveSeconds, RestCue.go, RestCue.go]`.
- **Generation token alone** — removing only `generation != _restGeneration` leaves all 7 tests green: it is defense-in-depth behind `Timer.cancel()` + `mounted`, not independently exercised (see Nit 2).

## Findings (severity order)

### Minor 1 — the 5s tick fires at 4s remaining when the rest is set to 5s
`lib/ui/workout.dart:216` fires the tick on the first tick where `next <= 5`. With `restSeconds = 5` (the minimum the Settings slider can store; `lib/data/store.dart:568` clamps to 5), the display starts at `0:05`, the first tick sets `next = 4`, and the cue fires at **4s remaining**, one second later than the spec's "at 5s remaining". For every rest ≥ 6s the timing is correct. Fix: fire the tick immediately in `_startRest` when `seconds <= 5` (and set `_restTickPlayed = true`), or gate on `next == 5` plus a start-time tick for short rests.

### Minor 2 — no test exercises the real asset paths
`test/rest_sounds_test.dart` injects `_FakeRestSounds`, so `AudioRestSounds` and `RestCue.asset` (`lib/services/rest_sounds.dart:10,13`) are never loaded. A typo in an asset path would pass all 7 tests and silently fail on device, because `AudioRestSounds.play` swallows the error (`lib/services/rest_sounds.dart:88`). I verified the APK contains both files, but the guard is missing. Fix: add a test asserting `RestCue.fiveSeconds.asset == 'sounds/rest_tick.wav'` and `RestCue.go.asset == 'sounds/rest_go.wav'`, and/or `rootBundle.load('assets/${cue.asset}')` succeeds.

### Nit 1 — fixed `playerId` can collide across two live screens
`lib/services/rest_sounds.dart:69` uses `playerId: 'compounder-rest-${cue.name}'`. If two `WorkoutScreen`s are alive, the second `create` overwrites the first's native player (`AudioplayersPlugin.kt:101`), and disposing the first then disposes the second's player; errors are swallowed, so the second screen's cues silently stop. Not reachable in current navigation (the summary uses `pushReplacement`, disposing the workout screen), but latent. Fix: append a unique suffix (`identityHashCode(this)` or a static counter).

### Nit 2 — the generation token is redundant and untested in isolation
`lib/ui/workout.dart:44,210` is defense-in-depth behind `Timer.cancel()` + `mounted`; removing it leaves all 7 tests green. The commit message presents it as the guard that prevents stale cues, which overstates it. Either add a test that isolates it (a timer that is not cancelled) or document it as belt-and-braces.

### Nit 3 — playback errors are swallowed with `debugPrint`
`lib/services/rest_sounds.dart:88` catches every error and logs at debug level. Acceptable per the comment (a workout must not break), but a broken audio route is invisible in release. Consider a one-time warning or a debug flag.

### Nit 4 — the tick's effective peak is very low (opinion)
`volume = 0.35` (`lib/services/rest_sounds.dart:44`) × the WAV's 0.16 peak = 0.056 (-25 dBFS). In a noisy gym the tick may be inaudible. Opinion, not a defect; consider raising the tick WAV peak or the per-cue volume.

## Verdict

**APPROVE WITH FIXES.** The feature is correct and verified: cues fire once at 5s and once at 0, the mute is honoured by the timer path, cancel/restart/dispose produce no stale cue, the audio player is disposed, the assets are bundled, the Android build succeeds, analyze is clean and the full suite is green. The two Minors (5s-rest off-by-one, missing asset-path test) should be closed in a follow-up; the Nits are optional.
