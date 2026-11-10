# Dependabot pub batch — PRs #2, #3, #4, #5 (compounder)

- **Task**: compounder Dependabot pub batch: unblock PR #4 (compileSdk), re-run PR #2, gate #2/#3/#4/#5
- **Repo**: `Arcane-Growth/compounder` (public; direct pushes to `main` blocked, 1 approval + Code Owners required)
- **Date**: 2026-11-10
- **Owner of merges**: the human. Nothing in this batch was merged or pushed to `main`.
- **Branches touched**: `dependabot/pub/permission_handler-13.0.2` (fix commit `5f88278`), `dependabot/pub/flutter-minor-patch-fbd56fded5` (guard test commit `5bf18e1`). PRs #3 and #5 were reviewed only — no commits added.

## PR #4 — permission_handler 12.0.3 → 13.0.2 (real CI break)

**Root cause (corrected from the triage note).** The failing constants are **API 37**, not 36:
`permission_handler_android-14.1.1/android/src/main/java/com/baseflow/permissionhandler/PermissionUtils.java:608`
says "The ACCESS_LOCAL_NETWORK permission is introduced in API level 37 (Cinnamon Bun)", and the
plugin's own `android/build.gradle.kts` declares `compileSdk = 37`. The app's root
`android/build.gradle.kts` forced **every** plugin down to `compileSdk 36`
(`setProperty("compileSdk", 36)` in `afterEvaluate`), which is what broke
`:permission_handler_android:compileReleaseJavaWithJavac`. Pinning 36 would not have fixed it.

**Fix** (`5f88278`, path-scoped to `android/app/build.gradle.kts` + `android/build.gradle.kts`):
- `android/app/build.gradle.kts`: `compileSdk = 37` (was `flutter.compileSdkVersion`, i.e. 36).
  AGP refuses to build an app whose compileSdk is lower than a dependency's, so the app had to move too.
- `android/build.gradle.kts`: plugin alignment raised from 36 to 37, with a comment explaining why
  plugins must not be lowered below their own requirement.
- `targetSdk` untouched (`flutter.targetSdkVersion` = 36), `minSdk` untouched (26).

**Why not pin permission_handler 12.x:** the SDK bump is in scope — API 37 is a released base SDK
(`~/Android/Sdk/platforms/android-37.0/source.properties`: `AndroidVersion.ApiLevel=37.0`,
`IsBaseSdk=true`, `PreviewSdkInt=0`), AGP 9.1.0 builds against it locally, and staying on 12.x would
just defer the same break to the next bump.

**Local verification (pinned worktree `/home/barry/.cache/wt-pr4` @ `5f88278`):**
- Pre-fix reproduction on the same worktree: `flutter build apk --release` →
  `PermissionUtils.java:97: error: cannot find symbol … ACCESS_LOCAL_NETWORK`,
  `:612 … CINNAMON_BUN`, `:616`, `:618` → `BUILD FAILED in 38s`.
- Post-fix: `flutter build apk --release` → `✓ Built build/app/outputs/flutter-apk/app-release.apk (68.3MB)`;
  `flutter build appbundle --release` → `✓ Built build/app/outputs/bundle/release/app-release.aab (65.3MB)`.
- `flutter analyze` → `No issues found!`.
- Merged manifest: `android:minSdkVersion="26"`, `android:targetSdkVersion="36"`;
  `aapt2 dump badging` → `compileSdkVersion='37'`, `targetSdkVersion:'36'`.

## PR #2 — flutter-minor-patch group (gpt_markdown 1.3.4, image_picker 1.2.4, shared_preferences 2.5.6, timezone 0.10.1)

**Red check was infra.** Run 42716640900 attempt 2, job 129526881741 ("Build release APK") was
cancelled at 14m with "The runner has received a shutdown signal"; attempt 1 failed at "Set up job".
No compile error in the log. Re-ran the failed job (`gh run rerun 42716640900 --failed`, attempt 3);
that attempt was then superseded by the guard-test commit below (concurrency group cancels in-flight
runs on the same ref), so the green evidence is the run on the final head `5bf18e1`.

**Transitive swap reviewed.** gpt_markdown 1.3.4 drops `flutter_svg` 2.3.0 + `flutter_math_fork` 0.7.4
and adds `val_latex_flutter`/`val_highlight`/`val_highlight_flutter` (plus `cupertino_ui`,
`material_ui`, `flutter_localizations`). `GptMarkdown`'s constructor still accepts the exact call the
app makes (`lib/ui/coach.dart:343`: `GptMarkdown(text, style:, isStreaming: false)`) — no API break.
The coach prompt (`lib/coach/agent.dart:126`) asks for headers, bullets and tables, not LaTeX or SVG,
so the maths-engine swap is low risk; the guard test covers it anyway.

**Guard added** (`5bf18e1`, `test/coach_markdown_render_test.dart`): renders representative coach
output (heading, bullets, table, prices, inline LaTeX, bold, inline code) and asserts the text reaches
the screen. Passes on 1.3.4 **and** on 1.2.1 (pre-bump worktree `/home/barry/.cache/wt-pr2-base` @
`142ffd1`), i.e. rendering parity, not just a green check.

**Local verification (`/home/barry/.cache/wt-pr2` @ `5bf18e1`):** `flutter analyze` → `No issues found!`;
`TZ=America/New_York flutter test` → `+530: All tests passed!`; `flutter test test/coach_markdown_render_test.dart`
→ `+4: All tests passed!`; `dart format --set-exit-if-changed` on the new file → clean.

## PR #3 — flutter_lints 6.0.0 / lints 6.1.0

Diff is `pubspec.yaml` + `pubspec.lock` only. `flutter_lints-6.0.0/lib/flutter.yaml` is byte-identical
to 5.0.0; `lints-6.1.0` adds four rules (`no_wildcard_variable_uses`, `unnecessary_underscores`,
`use_null_aware_elements`, `strict_top_level_inference`). `flutter_lints 6.0.0` requires SDK `^3.8.0`
(project is on Dart 3.13.3). No code changes needed.

**Local verification (`/home/barry/.cache/wt-pr3` @ `e933dcb`):** `flutter analyze` → `No issues found!`
(the four new rules produce zero findings); `TZ=America/New_York flutter test` → `+530: All tests passed!`.
CI on this head was 4/4 green including the release build.

## PR #5 — cupertino_icons 1.0.9 → 2.0.0

Diff is `pubspec.yaml` + `pubspec.lock` only. `cupertino_icons-2.0.0/pubspec.yaml` still declares
`family: CupertinoIcons` with `assets/CupertinoIcons.ttf` (asset present in the package), and
`cupertino_ui` is a **dev_dependency** of the package, not a runtime dependency — so the lock gains no
new transitive package. The app never references `CupertinoIcons` (`grep -rn CupertinoIcons lib/` → no
hits), so there is no icon-name or font-family breakage surface.

**Local verification (`/home/barry/.cache/wt-pr5` @ `24df4d6`):** `flutter analyze` → `No issues found!`;
`TZ=America/New_York flutter test` → `+530: All tests passed!`. CI on this head was 4/4 green including
the release build.

## CI runs

| PR | Head | Run | Result |
| --- | --- | --- | --- |
| #4 | `5f88278` | https://github.com/Arcane-Growth/compounder/actions/runs/42742307714 | 4/4 success — release build job 129587215815 (9m6s), `✓ Built … app-release.apk (63.4MB)` + `✓ Built … app-release.aab (60.5MB)` |
| #2 | `5bf18e1` | https://github.com/Arcane-Growth/compounder/actions/runs/42743120545 | 4/4 success — release build job 129590101928 (6m52s), `✓ Built … app-release.apk (74.4MB)` + `✓ Built … app-release.aab (72.7MB)` |
| #3 | `e933dcb` | https://github.com/Arcane-Growth/compounder/actions/runs/42716657311 | 4/4 success |
| #5 | `24df4d6` | https://github.com/Arcane-Growth/compounder/actions/runs/42716682571 | 4/4 success |

`gh pr list` at 2026-11-10: all four PRs `MERGEABLE`, `REVIEW_REQUIRED`, zero failing checks.
No merges performed; `main` untouched.

## Round 2 — fixes for the gate's Minors

Round 1 verdicts were APPROVE WITH FIXES (no Blockers, no Majors). The three cheap Minors were fixed
on the Dependabot branches; PR #2 M1 (integration-level coach-screen guard) is left as a follow-up
because it needs store/agent scaffolding and does not affect shipped behaviour.

**PR #4 `189697c`** (branch `dependabot/pub/permission_handler-13.0.2`) — closes M1 and M2:
- `android/build.gradle.kts` now reads each plugin's declared `compileSdk` and only raises it to the
  37 floor (`if (declared == null || declared < 37)`), so a plugin declaring 38 is never lowered.
  Probed at build time: `permission_handler_android declared=37` (left alone), the other 17 plugins
  declared 34–36 and were raised.
- `android/app/build.gradle.kts` uses `compileSdk = maxOf(37, flutter.compileSdkVersion)` instead of a
  hardcoded 37, so a future Flutter bump is followed automatically and the two files cannot silently
  diverge.
- Local: `flutter build apk --release` → `✓ Built … app-release.apk (68.3MB)`; `aapt2 dump badging` →
  `compileSdkVersion='37'`, `targetSdkVersion:'36'`; merged manifest `minSdkVersion="26"`.
- CI on `189697c`: run https://github.com/Arcane-Growth/compounder/actions/runs/42745638782 → 4/4
  success, release build job 129597980868 (8m57s), `✓ Built … app-release.apk (63.4MB)` +
  `✓ Built … app-release.aab (60.5MB)`.

**PR #2 `7686d83`** (branch `dependabot/pub/flutter-minor-patch-fbd56fded5`) — closes M2:
- `test/coach_markdown_render_test.dart` now asserts the U+FFFC object-replacement character that the
  embedded formula surfaces as, so the case fails if `val_latex_flutter` renders nothing.
- Local: `flutter test test/coach_markdown_render_test.dart` → `+4: All tests passed!`;
  `dart format --set-exit-if-changed` clean.
- CI on `7686d83`: run https://github.com/Arcane-Growth/compounder/actions/runs/42745665088 → 4/4
  success, release build job 129598050618 (8m24s), `✓ Built … app-release.apk (74.4MB)` +
  `✓ Built … app-release.aab (72.7MB)`.

**PR #3 / PR #5** — unchanged (`e933dcb`, `24df4d6`), both still 4/4 green.

## Gate verdict

**Reviewer**: Code Reviewer. **Date**: 2026-11-10. Every command below was re-run by me in the
pinned worktrees; nothing was merged and nothing was pushed. Dev evidence above was read first and
then independently checked — two numbers in it are stale (noted under PR #2).

### Per-PR verdicts

| PR | Verdict |
| --- | --- |
| #4 permission_handler 13.0.2 + compileSdk 37 | **APPROVE WITH FIXES** (2 Minor, non-blocking) |
| #2 flutter-minor-patch + markdown guard | **APPROVE WITH FIXES** (2 Minor, non-blocking) |
| #3 flutter_lints 6.0.0 | **APPROVE** |
| #5 cupertino_icons 2.0.0 | **APPROVE** |

No Blockers, no Majors. Both fixes are proven non-vacuous (quoted failures below).

### Commands run and results

**PR #4 — `/home/barry/.cache/wt-pr4` @ `5f88278`**
- `git diff 142ffd1..5f88278` → 4 files: `android/app/build.gradle.kts` (`compileSdk = 37`),
  `android/build.gradle.kts` (plugin alignment 36→37), `pubspec.yaml` (`permission_handler: ^13.0.2`),
  `pubspec.lock` (permission_handler_android 13.0.1→14.1.1).
- `flutter analyze` → `No issues found! (ran in 3.5s)`.
- `flutter build apk --release` → `✓ Built build/app/outputs/flutter-apk/app-release.apk (68.3MB)`
  (incremental, 4.4s; the clean-build evidence is CI run 42742307714, release job 129587215815).
- Merged manifest `build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml`
  → `android:minSdkVersion="26"`, `android:targetSdkVersion="36"`.
- `aapt2 dump badging app-release.apk` → `compileSdkVersion='37'`, `minSdkVersion:'26'`,
  `targetSdkVersion:'36'`, `package: name='dev.compounder.compounder'`.
- **Fix non-vacuity (revert-and-quote)**: set app back to `compileSdk = flutter.compileSdkVersion`
  and root back to `setProperty("compileSdk", 36)`, rebuilt →
  `PermissionUtils.java:97: error: cannot find symbol` (also `:612`, `:616`, `:618`),
  `BUILD FAILED in 5s`. Restored; worktree clean.

**PR #2 — `/home/barry/.cache/wt-pr2` @ `5bf18e1`**
- `flutter analyze` → `No issues found! (ran in 3.9s)`.
- `TZ=America/New_York flutter test` → `+534: All tests passed!` (dev file says 530 — stale; 530 + the
  4 new guard tests).
- `flutter test test/coach_markdown_render_test.dart` → `+4: All tests passed!`.
- Baseline parity `/home/barry/.cache/wt-pr2-base` @ `142ffd1` (gpt_markdown 1.2.1, sha256 `42887afa…`):
  guard → `+4: All tests passed!` ⇒ parity guard, not version-specific. Confirmed PR #2 lock is
  gpt_markdown 1.3.4 (sha256 `77f5af4b…`).
- **Guard non-vacuity (quoted)**: replaced the pumped `GptMarkdown(...)` with `const SizedBox.shrink()`
  (renderer emits no text) → all four tests fail:
  ```
  Expected: contains 'Weekly plan'
    Actual: ''
     Which: does not contain 'Weekly plan'
  ...
  Expected: contains '$5 and $10'
    Actual: ''
  ...
  Expected: contains 'deficit'
    Actual: ''
  ...
  Expected: contains 'Goal:'
    Actual: ''
  00:00 +0 -4: Some tests failed.
  ```
  Restored → `+4: All tests passed!`.
- **Coverage probe**: reverted `lib/ui/coach.dart:343` `GptMarkdown(...)` to `Text(m.text)` → guard
  still `+4: All tests passed!` ⇒ the guard does not cover the app's integration path (finding M1).
- **LaTeX probe**: added `expect(t, contains('500'))` → fails; rendered text is
  `Your deficit is ￼ kcal per day.` (U+FFFC placeholder) ⇒ the LaTeX assertion only proves the
  surrounding prose (finding M2).
- Transitive delta verified from the lock: dropped `flutter_svg`, `flutter_math_fork`, `path_parsing`,
  `tuple`, `vector_graphics*`; added `val_latex_flutter` 0.1.4 (useval.io), `val_latex`,
  `val_highlight`, `val_highlight_flutter`, `cupertino_ui` 1.1.6, `material_ui` 1.2.0
  (both flutter/packages), `flutter_localizations`. `GptMarkdown(text, style:, isStreaming:)` still
  compiles (analyze clean) — no API break.

**PR #3 — `/home/barry/.cache/wt-pr3` @ `e933dcb`**
- `gh pr diff 3` → `pubspec.yaml` + `pubspec.lock` only (flutter_lints 5.0.0→6.0.0, lints 5.1.1→6.1.0).
- `flutter analyze` → `No issues found! (ran in 2.8s)`.
- Rule delta verified from the pub cache: `flutter_lints-6.0.0/lib/flutter.yaml` is byte-identical to
  5.0.0; `lints-6.1.0` adds `no_wildcard_variable_uses`, `unnecessary_underscores`,
  `use_null_aware_elements` (recommended.yaml) and `strict_top_level_inference` (core.yaml) — four new
  rules, zero findings on this codebase.

**PR #5 — `/home/barry/.cache/wt-pr5` @ `24df4d6`**
- `gh pr diff 5` → `pubspec.yaml` + `pubspec.lock` only.
- `flutter analyze` → `No issues found! (ran in 3.0s)`; `TZ=America/New_York flutter test` →
  `+530: All tests passed!`.
- `cupertino_icons-2.0.0/pubspec.yaml` → `family: CupertinoIcons`, `asset: assets/CupertinoIcons.ttf`
  (file present, 257,628 bytes); `cupertino_ui` is under `dev_dependencies` only; lock delta adds no new
  package; `grep -rn CupertinoIcons lib/` → no hits.

**CI spot-check** (`gh pr checks`, not re-run): #2 4/4 pass (run 42743120545), #3 4/4 (42716657311),
#4 4/4 (42742307714), #5 4/4 (42716682571).

### Findings

**PR #4**
- **Minor (M1)** — `android/build.gradle.kts:19-26`: the comment says "Plugins that pin an older
  compileSdk are raised to it; plugins that need a newer one … must not be lowered below it", but line
  30 unconditionally sets 37 for every plugin. A plugin declaring compileSdk 38 would be lowered to 37
  and fail exactly as permission_handler did. Fix: reword to "every plugin is pinned to 37", or
  implement `max(37, declared)`.
- **Minor (M2)** — `android/app/build.gradle.kts:16`: hardcoded 37 while `flutter.compileSdkVersion` is
  36; nothing enforces the "keep in lockstep" comment. On the next Flutter upgrade the two silently
  diverge and the pin goes stale. Fix: single source of truth (root `val appCompileSdk = 37` referenced
  from the app module) or a CI grep assertion.
- **Nit** — raising plugin compileSdk is safe (AGP only errors when app < dependency); no runtime or
  permission change: targetSdk stays 36, minSdk stays 26.

**PR #2**
- **Minor (M1)** — the guard is package-level, not integration-level: reverting `coach.dart` to
  `Text(m.text)` still passes. Suggest a widget test that pumps the coach screen (or asserts
  `find.byType(GptMarkdown)` in `lib/ui/coach.dart`).
- **Minor (M2)** — "renders inline LaTeX through the new maths engine" only asserts `contains('deficit')`;
  LaTeX renders as U+FFFC, so `contains('500')` fails. The test would pass even if the maths engine
  rendered nothing. Fix: assert `contains('\uFFFC')` or `find.byType(Math)`.
- **Nit** — dev evidence line 62 reports `+530` for this head; actual is `+534`.
- **Nit** — the bump adds runtime transitive packages (`cupertino_ui`, `material_ui`,
  `val_latex_flutter`); supply-chain surface grew, sources are reputable, no API break.

**PR #3 / PR #5** — no findings.

### Rationale

All four heads analyze clean, tests pass locally, and CI is 4/4 green including the release APK+AAB.
Both fixes are proven non-vacuous by revert-and-quote. The two APPROVE WITH FIXES verdicts are
documentation/coverage gaps that do not affect shipped behaviour and can land as follow-ups after merge.

**Worktree hygiene note**: `/home/barry/.cache/wt-pr2` had a pre-existing dirty `pubspec.lock` (only the
`sdks:` constraint section, bumped by the local Flutter 3.47.0 — no package version changes), so the test
results above are valid. All my temporary edits were restored; `git status` clean in every worktree I
touched.

## Gate verdict — round 2

**Reviewer**: Code Reviewer. **Date**: 2026-11-10. Every gate below was re-run by me in the pinned
worktrees at the new heads; the dev's round-2 claims were checked, not trusted. Nothing merged, nothing
pushed.

### Per-PR round-2 verdicts

| PR | Head | Round-2 verdict |
| --- | --- | --- |
| #4 permission_handler 13.0.2 + compileSdk floor | `189697c` | **APPROVE** — M1 and M2 closed, both proven non-vacuous |
| #2 flutter-minor-patch + markdown guard | `7686d83` | **APPROVE** — M2 closed and proven non-vacuous; M1 accepted as a follow-up (non-blocking) |
| #3 flutter_lints 6.0.0 | `e933dcb` | **APPROVE** (unchanged) |
| #5 cupertino_icons 2.0.0 | `24df4d6` | **APPROVE** (unchanged) |

No Blockers, no Majors, and no Minor still blocks.

### PR #4 — `/home/barry/.cache/wt-pr4` @ `189697c`

Delta `5f88278..189697c` touches `android/app/build.gradle.kts` and `android/build.gradle.kts` only.

Commands and results:
- `flutter analyze` → `No issues found! (ran in 2.8s)`.
- `flutter build apk --release` → `✓ Built build/app/outputs/flutter-apk/app-release.apk (68.3MB)`.
- Merged manifest `build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml`
  → `android:minSdkVersion="26"`, `android:targetSdkVersion="36"`.
- `aapt2` (build-tools 36.0.0) `dump badging app-release.apk` → `compileSdkVersion='37'`,
  `minSdkVersion:'26'`, `targetSdkVersion:'36'`, `package: name='dev.compounder.compounder'`.
- `getProperty("compileSdk")` probe (temporary `println` in `afterEvaluate`, removed afterwards): 18
  plugins reported, `permission_handler_android declared=37` (left alone), the other 17 declared 34–36
  (`flutter_local_notifications` 34, `flutter_timezone`/`jni`/`jni_flutter`/`pdfx` 35, the rest 36) and
  were raised. Matches the dev's claim exactly; the read returns `java.lang.Integer`, so the `as? Int`
  cast is sound, and a null/non-Int read falls back to raising to 37 — the safe direction.

**Non-vacuity (revert-and-quote), two builds:**
- Guard intact, floor temporarily lowered to 36 (the original break level) → `✓ Built … (68.3MB)`:
  `permission_handler_android` stayed at 37, so the build survived.
- Guard replaced with the old unconditional `setProperty("compileSdk", 36)` →
  ```
  permission_handler_android-14.1.1/…/PermissionUtils.java:97: error: cannot find symbol
  …:612: error: cannot find symbol
  …:616: error: cannot find symbol
  …:618: error: cannot find symbol
  BUILD FAILED in 1s
  ```
  ⇒ the `declared < 37` branch is what prevents the regression; it is not decorative.

**M2 judgment**: `maxOf(37, flutter.compileSdkVersion)` closes M2 for the realistic case. If Flutter's
compileSdk moves to 38, the app moves to 38 while plugins stay at the 37 floor — app ≥ plugin, which AGP
accepts. The remaining divergence (root floor hardcoded 37 vs app derived) fails **loudly**, not silently:
raising the root floor above the app's compileSdk makes AGP error at configuration time ("dependency
requires compileSdk X"). So the trap is moved to a loud failure, which is acceptable. Residual **Nit**: the
literal 37 is still duplicated in two files; a shared `val` would be cleaner but is not required.
compileSdk is compile-time only — targetSdk 36 and minSdk 26 are unchanged, so no runtime/permission change.

### PR #2 — `/home/barry/.cache/wt-pr2` @ `7686d83`

Delta `5bf18e1..7686d83` touches `test/coach_markdown_render_test.dart` only.

Commands and results:
- `flutter analyze` → `No issues found! (ran in 3.3s)`.
- `TZ=America/New_York flutter test test/coach_markdown_render_test.dart` → `+4: All tests passed!`.
- `TZ=America/New_York flutter test` (full suite) → `+534: All tests passed!`.

**Non-vacuity (quoted)**: replaced the pumped markdown with plain prose `'Your deficit is 500 kcal per day.'`
(no LaTeX) →
```
Expected: contains '￼'
  Actual: 'Your deficit is 500 kcal per day.'
   Which: does not contain '￼'
…
file:///home/barry/.cache/wt-pr2/test/coach_markdown_render_test.dart line 77
00:00 +2 -1: Some tests failed.
```
Restored → `+4: All tests passed!`.

**Provenance probe**: added `expect(text, contains('500'))` on the LaTeX case →
```
Expected: contains '500'
  Actual: 'Your deficit is ￼ kcal per day.'
```
⇒ the U+FFFC is exactly the formula placeholder; the assertion bites on the maths path, not on the
surrounding prose. **M2 closed.**

Residual **Nit**: U+FFFC is gpt_markdown's generic embedded-widget placeholder
(`gpt_markdown-1.3.4/lib/custom_widgets/bidi_rich_text.dart:73`), so the assertion proves the formula was
routed to a widget, not that `Math.tex` (val_latex_flutter 0.1.4) painted glyphs. `takeException()` isNull
covers a throw; an engine that renders empty would still pass. A stronger assertion would be
`find.byType(Math)` (`Math` is a `StatefulWidget` in val_latex_flutter). Non-blocking.

**M1 (integration-level guard)**: accepted as a follow-up, does not block. The guard is package-level;
reverting `lib/ui/coach.dart:343` to `Text(m.text)` still passes (round-1 probe). It does not affect shipped
behaviour and CI's release build covers the compile path. Follow-up: a widget test that pumps the coach
screen and asserts `find.byType(GptMarkdown)`.

### CI spot-check (not re-run)

- `gh pr checks 2` → 4/4 pass (run 42745665088; release job 129598050618, 8m24s).
- `gh pr checks 4` → 4/4 pass (run 42745638782; release job 129597980868, 8m57s).

Matches the dev's numbers.

### Remaining risks

- PR #4: duplicated 37 literal (Nit); a plugin declaring a compileSdk above the app's fails loudly at AGP
  configuration time — acceptable.
- PR #2: the U+FFFC assertion does not prove the maths engine paints (Nit); integration guard deferred
  (M1 follow-up).
- Worktree hygiene: `wt-pr2` has the pre-existing dirty `pubspec.lock` (`sdks:` section only, local Flutter
  3.47.0); all my temporary edits were restored and `wt-pr4` is clean.

**No merges, no pushes.** Both PRs are ready for the human to merge.
