# Gate review — compounder app batch: coach approval card + device_token register

Date: 2026-11-09
Reviewer: Code Reviewer
Worktree: `/home/barry/.cache/review-wt/app-batch-gate` pinned at `f1300de` (detached), never the shared checkout.
Commits reviewed: `bd029e0` (coach approval card), `f1300de` (device_token register). Probe: `test/_gate_probe_test.dart`.

## Verdict: APPROVE WITH FIXES (no blockers)

Both fixes are correct, both regression guards are real and non-vacuous, analyze is clean and the full suite passes. The remaining items are minor test-coverage gaps and nits; none block the batch.

## What I verified myself

| Check | Command | Result |
|---|---|---|
| Analyzer | `flutter analyze` (pinned worktree, `TMPDIR=/home/barry/.cache/flutter-tmp`) | `No issues found! (ran in 1.6s)` |
| Full suite | `flutter test` (same worktree/TMPDIR) | `00:16 +352: All tests passed!` |
| Targeted tests | `flutter test test/_gate_probe_test.dart test/gateway_register_test.dart test/coach_approval_layout_test.dart` | `00:04 +15: All tests passed!` |
| Coach guard non-vacuous | reverted `lib/ui/coach.dart` to `bd029e0^`, ran `test/coach_approval_layout_test.dart` | `00:01 +0 -7: Some tests failed.` — every case fails with `BoxConstraints forces an infinite width.` |
| Device guard non-vacuous | reverted `register()` to the pre-fix `const {}` body, ran probe + register tests | `00:00 +1 -7: Some tests failed.` — probe fails `Expected: contains pair 'device_token' => anything` / `Actual: {}` / `Which: doesn't contain key 'device_token'`; register tests fail `Expected: not null` / `Actual: <null>` |
| Probe retained | `test/_gate_probe_test.dart` present in `f1300de` and executed by the full suite | present, passing |

Both reverts were restored with `git checkout --`; worktree ended clean.

## Findings

### Minor 1 — keyboard-open reveal is not covered by any test
`bd029e0` claims the card is "fully revealed with the keyboard open" and adds a double post-frame re-anchor in `_scrollToBottom` (`lib/ui/coach.dart:228-238`). No test sets `MediaQuery.viewInsets` (grep for `viewInsets` in `test/` returns nothing), and `test/coach_approval_layout_test.dart:78` performs its own `scroll.jumpTo(maxScrollExtent)` instead of exercising `_scrollToBottom`. So the re-anchor half of the fix is unverified. The layout half (both buttons on screen at 320dp / textScale 2.0) is genuinely covered.
Fix: add a widget test that pumps `CoachTab` with a non-zero `viewInsets.bottom` and asserts the card's action row is above the inset.

### Minor 2 — widget test asserts callbacks, not the write semantics
`test/coach_approval_layout_test.dart` passes counters as `onApprove`/`onCancel`, so it proves the buttons are tappable and wired, but not that Approve applies the pending write or that Cancel declines without writing. Those semantics are covered at the agent level in `test/coach_gate_test.dart` (`agent.approve` mutates, `agent.decline` leaves the store untouched, batch approve). Acceptable as a split, but the `CoachApprovalCard -> _decide` wiring itself is not exercised end-to-end.

### Nit 3 — `register()` persists `token` but returns `issued`
`lib/subscription/gateway.dart:101-112` saves the client-minted `token` and marks it registered, then returns the gateway-echoed `issued`. The gateway currently echoes the same trimmed token (`server/src/mobile/mod.rs:527`), so they match. If the gateway ever issued a different token, the store would mark the wrong one registered and the next call would send a token the gateway may not know. Cheap hardening: assert/return `token`, or persist `issued`.

### Nit 4 — platform fallback mislabels non-mobile platforms
`lib/subscription/gateway.dart:83`: `platform ?? (Platform.isIOS ? 'ios' : 'android')` reports `android` on macOS/Windows/Linux desktop and web. The app is mobile-only today, so this is cosmetic.

### Nit 5 — the global infinite `minimumSize` remains a trap
`lib/ui/widgets.dart:30` sets `filledButtonTheme.minimumSize = Size.fromHeight(48)` (infinite width). Any future `FilledButton` placed in a `Row`/unbounded main axis will hit the same clipping bug. Consider a finite width in the theme, or document the constraint next to it.

### Verified, not a bug — concurrent `register()` calls
I suspected a race where two concurrent `_deviceToken()` calls (restore + purchase verify) mint distinct identities. A throwaway probe (`Future.wait([client.register(), client.register()])`) showed both calls send the **same** token: the second sees the first's persisted token because `saveDeviceToken` completes before the POST. The gateway's register is idempotent on `token_hash`, so a duplicate POST does not create a second account. No finding.

## Contract checks (device_token)

- Body: `device_token` (43-char base64url from 32 `Random.secure()` bytes, inside the gateway's 8-512 window) + `platform`. Matches `RegisterRequest` in `server/src/mobile/mod.rs:141-146` and the 8-512 validation at `:485-487`.
- Persist-before-send: `saveDeviceToken` is awaited before `_post` (`gateway.dart:101`), and `deviceTokenRegistered` resets to false, so a failed register retries with the same identity. Covered by `gateway_register_test.dart:91-115`.
- No churn across restarts: token and registered flag are persisted in prefs and reloaded in `AppStore.open` (`store.dart:108-112`); covered by `gateway_register_test.dart:117-138`.
- No plaintext token in logs: no `debugPrint`/`print`/`developer.log` in `lib/subscription/`, `lib/data/store.dart`, or `lib/main.dart`; the only debug prints are in health/summary/seeder and none include the token.
- Header path: verify/restore still send `X-Device-Token` (`gateway.dart:177-179`); the gateway reads `x-device-token` in `authenticate_mobile` (`server/src/mobile/mod.rs:343-350`). Header names are case-insensitive, so they match.
- Failure path: `service.dart:243-251` catches `GatewayException` and returns null, so verification proceeds without a device token. `gateway_register_test.dart:176-190` covers a 200 response with no token (throws, `deviceTokenRegistered` stays false).

## Coach layout checks

- `Wrap` with `alignment: end`, `spacing/runSpacing: 8`, and a finite `FilledButton` `minimumSize: Size(64, 48)` (`coach.dart:518-534`). Both buttons on screen and tappable at 412x915 and 320x640 across textScale 1.0/1.3/2.0, and the batch "Approve all" at 320dp/2.0 — all pass.
- No `RenderFlex` overflow: `tester.takeException()` is asserted null in every case.
- Batch path intact: `many ? 'Approve all' : 'Approve'` unchanged; batch test taps it and asserts the callback fires.

## Probe test

`test/_gate_probe_test.dart` is present (not deleted) and is a real guard: reverting `register()` to the pre-fix empty body makes it fail with `Actual: {}` / `doesn't contain key 'device_token'`. It is intentionally minimal (key presence only); the length/platform/persistence assertions live in `gateway_register_test.dart`.

## Evidence summary

- `flutter analyze` → `No issues found! (ran in 1.6s)`
- `flutter test` → `00:16 +352: All tests passed!`
- Coach revert → `00:01 +0 -7: Some tests failed.` + `BoxConstraints forces an infinite width.`
- Device revert → `00:00 +1 -7: Some tests failed.` + `Expected: contains pair 'device_token' => anything` / `Actual: {}`
- Restored tree → `00:04 +15: All tests passed!`

## Resolution (2026-11-09, commit `e2478ca`)

| Item | Disposition |
|---|---|
| Minor 1 — keyboard-open reveal untested | **Fixed.** `test/coach_approval_widget_test.dart` pumps `CoachTab` with `viewInsets.bottom = 250` and asserts the card and Approve button sit entirely above the keyboard fold. Reverting `_scrollToBottom` to a no-op fails it (`Found 0 widgets with type "CoachApprovalCard"`). |
| Minor 2 — widget test asserts callbacks, not writes | **Fixed.** Same file drives a real turn through an injected agent/client: Approve writes the meal (`store.meals` length 1, dish Toast); Cancel leaves `store.meals` empty. Reverting the card wiring to no-op callbacks fails both (`Actual: []` / card still present). |
| Nit 3 — `register()` returns echoed `issued` | **Fixed.** `register()` now adopts a divergent gateway-issued token (`saveDeviceToken(issued)`) before marking registered, so the persisted identity is always the one the gateway knows. New test fails pre-fix (`Actual: <minted token>`). |
| Nit 4 — platform fallback reports `android` on desktop | **Fixed.** Fallback uses `defaultTargetPlatform` and reports `other` off mobile. New test with `debugDefaultTargetPlatformOverride = linux` fails pre-fix (`Actual: 'android'`). |
| Nit 5 — global infinite `minimumSize` trap | **Documented as accepted.** The infinite width is intentional (full-width primary actions in dialogs/forms); changing it app-wide would alter every dialog. The constraint is documented in `lib/ui/widgets.dart` and pinned by a test that asserts the theme minimum width is infinite, so a silent change is caught. Row users must override with a finite width (as `CoachApprovalCard` does). |

Verification in pinned worktree `/home/barry/.cache/wt-app-batch-minors` at `e2478ca`: `flutter analyze` → `No issues found!`; `flutter test` → `+366: All tests passed!`. Also fixed a pre-existing date-boundary flake in `test/habits_coach_test.dart` (hardcoded 2026-11-08 fell out of the current ISO week at the Nov 8/9 boundary; now logs on today's day key). No push, no device rebuild (no UI change landed).
