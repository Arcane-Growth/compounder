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

## Gate verdict

_Pending — Code Reviewer._
