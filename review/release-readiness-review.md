# Gate: release readiness (repo hygiene + workflows + release build + app ID)

**Reviewed commit:** `4b98f12` (main, detached worktree at
`/home/barry/.cache/review-wt/compounder-4b98f12`)
**Batch under review:** `05e23ca`, `c4b1ae8`, `142ffd1`, `f18eb17`, `4b98f12`
**Date:** 2026-11-09
**Reviewer:** Code Reviewer

## Verdict: APPROVE WITH FIXES

No code-level blocker. The signing guard, R8 minification, app-ID rename, secret
hygiene and workflow definitions all hold up under revert tests and real builds.
The fixes are documentation-vs-reality gaps and GitHub settings that are not
actually in force on this plan, plus one CI job whose green state is unproven.

---

## Blocker

None found in the reviewed code.

## Major

### M1 — Branch protection is not enforced at all (docs claim it is)
`gh api repos/arcane-growth/compounder/branches/main/protection` returns
`403 Upgrade to GitHub Pro or make this repository public to enable this
feature.` The org plan is `free` and the repo is `private`.

`docs/branching-and-protection.md` presents the whole protection table as
"enforced in GitHub settings", and `CONTRIBUTING.md:76` says "`main` is
protected: no direct pushes, no force-push, no deletion". Today none of that is
true: `main` can be force-pushed, deleted, and pushed to directly. Evidence that
it already happened: `origin/main` is at `142ffd1` — three of the five batch
commits were pushed straight to `main`.

Fix (DevOps): either make the repo public or buy GitHub Pro/Team, then apply the
rules; until then, mark the table in `docs/branching-and-protection.md` as
"intended, not yet enforceable on the current plan".

### M2 — Secret scanning and push protection are not enabled
`gh api repos/arcane-growth/compounder` returns `security_and_analysis: null`,
and `gh api repos/arcane-growth/compounder/secret-scanning/alerts` returns
`404`. Both are GitHub Advanced Security features that free private repos do not
get.

`SECURITY.md:83-85` states secret scanning is "enabled, with push protection
enabled for all branches", and `SECURITY.md:94-96` calls push protection "the
one that actually prevents a leak". Reality: the only scanner is the gitleaks
job in CI, which runs *after* the push. The gitleaks job itself is good (see
verified evidence) — the doc just overstates the control.

Fix: correct `SECURITY.md` and `docs/branching-and-protection.md` to say
"gitleaks in CI is the scanner; push protection requires GHAS/public repo".

### M3 — Private vulnerability reporting is not enabled
`gh api repos/arcane-growth/compounder/private-vulnerability-reporting` returns
`404`. `SECURITY.md:23-25` names GitHub private vulnerability reporting as the
**preferred** channel and links
`https://github.com/arcane-growth/compounder/security/advisories/new`. That link
404s for reporters today; only the `security@arcanegrowth.com` fallback works.

Fix (DevOps): enable it under Settings → Code security, or demote it to
"fallback" in `SECURITY.md`.

### M4 — (resolved during review) CI `Release build (ephemeral CI key)` on main
Run `42716190175` (push to `142ffd1`) was still `in_progress` when this review
started; it later completed **success** on all four jobs, including the release
build with the ephemeral CI key. No action needed — recorded here so the
timeline is honest. The job took ~25 minutes on a cold runner; if that creeps
toward the 45-minute timeout, cache Gradle/Flutter.

## Minor

### m1 — Merge methods contradict "squash merge only"
Repo metadata: `allow_merge_commit: true`, `allow_rebase_merge: true`,
`allow_squash_merge: true`, `delete_branch_on_merge: false`.
`docs/branching-and-protection.md:91` says "**Squash merge only.**" Fix: disable
merge-commit and rebase in repo settings, or soften the doc.

### m2 — Release tags are not signed
`docs/branching-and-protection.md:50-51` says release tags "must be **signed**
(`git tag -s`)" and to verify with `git tag -v v0.4.0`. Reality: `v0.1.0`–`v0.2.2`
are lightweight tags (`git tag -v` errors "cannot verify a non-tag object"),
`v0.3.0`–`v0.3.2` are annotated but carry no signature (`git tag -v` prints no
`gpg: Signature made`). No `v0.4.0` tag exists yet, so the policy is still
forward-looking — but the doc reads as if it is already true.

### m3 — "Require signed commits" is not true of existing commits
`docs/branching-and-protection.md:37` requires signed commits. `git log
--format='%h %G?'` shows `N` (unsigned) for all eight most recent commits. This
is consistent with M1 (no protection), and GitHub squash-merges are signed by
GitHub, so it will self-correct once protection is on. Flagging so the doc is
not read as a current fact.

### m4 — README describes a navigation layout that no longer exists
`README.md` architecture block says "shell (5 tabs: Health, Macros, Wealth, Mind,
Coach)". `lib/ui/shell.dart:107-113` defines Home/Fitness/Macros/Wealth/Coach,
with Mind drawer-only (`shell.dart:99-104`). Also "20 tools" — `lib/coach/tools.dart`
has 24 `ToolSpec` definitions.

### m5 — "Network access is only the AI endpoint" is no longer true
`README.md` ("Network access is only the AI endpoint") and `SECURITY.md:4-6`
("the only network traffic is to the AI endpoint *you* configure") predate the
subscription feature. `lib/subscription/gateway.dart` posts to
`https://gateway.arcanegrowth.com` (`lib/subscription/constants.dart:9`) for
entitlement/usage. The "no server of ours holding your life data" claim still
holds (the gateway sees entitlement, not health data), but the network claim
needs a sentence.

### m6 — Dependabot does not cover Gradle dependencies
`.github/dependabot.yml` covers `pub` and `github-actions` only. AGP, Kotlin,
and `desugar_jdk_libs` (`android/app/build.gradle.kts:141`) are unmonitored.
`SECURITY.md:77` says "Dependencies are monitored by Dependabot" without
qualification. Fix: add a `gradle` ecosystem entry for `/android`.

### m7 — Documented device-verification command returns nothing on Android 17
`docs/release-build.md:128`:
`adb shell dumpsys activity activities | grep -m1 mResumedActivity`.
On the Pixel 10 (Android 17) the field is `ResumedActivity:` — the grep prints
nothing. Verified: `grep -m1 mResumedActivity` → empty; `grep ResumedActivity` →
`ResumedActivity: ActivityRecord{… com.arcanegrowth.compounder/.MainActivity …}`.
Fix the doc to `grep -m1 ResumedActivity`.

### m8 — release-build.md understates what release.yml does
`docs/release-build.md:82-91` says CI "should run exactly" the appbundle command
and upload the AAB + symbols. `release.yml` builds **both** the AAB and the APK,
proves the signer, writes checksums and publishes a GitHub Release. Fix the
wording so the doc matches the pipeline.

### m9 — "Nothing pushed" is not true of this batch
`origin/main` = `142ffd1`, so `05e23ca`, `c4b1ae8` and `142ffd1` are already on
the remote; only `f18eb17` and `4b98f12` are local. If the intent was "gate
before push", three commits went out ahead of the gate. Harmless (they are the
docs/CI commits), but the acceptance criterion as written is not met.

### m10 — Five Dependabot PR runs are red from a transient policy state
Runs at 22:59 on `dependabot/*` branches failed at "Set up job" with:
`The action actions/cache@v5 is not allowed … All actions must also be pinned to
a full-length commit SHA.` (`actions/cache@v5` is a transitive dependency of
`subosito/flutter-action`). Current repo policy is
`sha_pinning_required: false`, `github_owned_allowed: true`, so a re-run should
pass. The PRs are still red; re-run them (DevOps) so the board is not showing
false failures.

## Nit

- n1 — `./gradlew build` / `./gradlew assemble` do not contain "Release" in
  `gradle.startParameter.taskNames`, so the signing guard does not fire for
  them. Flutter always passes `assembleRelease`/`bundleRelease`, so there is no
  practical impact; the doc's "covers every path Flutter uses" is accurate.
- n2 — `dist/` (created by the release.yml staging step) is not in
  `.gitignore`. Harmless locally; add it if anyone runs the staging step on a
  workstation.
- n3 — `release.yml` builds the AAB and then the APK into the same
  `--split-debug-info=build/symbols` directory. Verified byte-identical symbol
  hashes across both builds (`bcf4fe12…`, `57aae124…`, `5408451b…`), so the
  overwrite is harmless today. If Dart obfuscation ever becomes
  non-deterministic, use separate directories.

---

## Verified evidence

### Secrets
- `gitleaks 8.30.0 git --log-opts="--all" --redact`: **88 commits scanned, no
  leaks found** (exit 0). This is the same binary/version/checksum the CI job
  installs.
- `gitleaks dir .`: 2 findings, both in `android/key.properties` (untracked,
  gitignored) — expected.
- `git ls-files` matches for `*.jks|*.keystore|*.p8|*.p12|*.pem|key.properties|
  local.properties|.env`: none tracked.
- Keystore lives outside the repo (`/home/barry/.android-keystores/compounder-upload.jks`);
  `android/key.properties` is untracked and matched by both root `.gitignore`
  and `android/.gitignore`.
- No hardcoded secret in `lib/` or `.github/`: the keystore password appears
  only in the untracked `android/key.properties`; CI uses the literal
  `ci-only-password` for its throwaway keystore.
- No `.jks/.apk/.aab/.jar` was ever added in history (`git log --all
  --diff-filter=A`); only PNG/WAV assets.

### Workflows
- **Live CI proof:** run `42716190175` on `main` (`142ffd1`) completed
  **success** — `Secret scan (gitleaks)`, `Format check`, `Analyze and test`,
  `Release build (ephemeral CI key)` all green. The pipeline works end to end on
  the real repo, not just locally.
- YAML parse (python `yaml.safe_load`): `ci.yml`, `release.yml`,
  `dependabot.yml`, all three `ISSUE_TEMPLATE/*.yml` — OK.
- `actionlint 1.7.7` on both workflows: **exit 0, no findings**.
- All 14 `uses:` entries are pinned to 40-hex SHAs with version comments; no
  unpinned action.
- Permissions: `ci.yml` `contents: read`; `release.yml` `contents: write` only
  (needed for the Release). CI run log confirms the token got
  `Contents: read, Metadata: read`.
- `release.yml` "Validate signing secrets" simulated with no secrets:
  `::error::Missing repository secret(s): KEYSTORE_BASE64 KEYSTORE_PASSWORD
  KEY_ALIAS KEY_PASSWORD`, exit 1. With all four: exit 0.
- "Materialise keystore" simulated with the real keystore: base64 → 2766-byte
  `android/upload-keystore.jks` + `key.properties`, both non-empty, exit 0.
- Tag/version check simulated: tag `0.4.0` vs pubspec `0.4.0+10` → match.
- Signer-proof step simulated: keystore SHA-256
  `d53d2aeb941f696612305cb00ac2d18da252fa654e71812ab2af8c55afce9248` == APK
  signer SHA-256 → would pass.
- Build-break detection: injected a Kotlin syntax error into `MainActivity.kt`
  → `e: … Syntax error: Expecting an argument.` / `BUILD FAILED`, exit 1.
  Reverted.

### Release build (revert test)
- `android/key.properties` removed → `flutter build apk --release` exit 1:
  `FAILURE: Build failed with an exception. * Where: …/android/app/build.gradle.kts
  line: 119 * What went wrong: Release build is not signed with the upload key:
  - android/key.properties does not exist`.
- `storeFile` pointing at a missing keystore → exit 1: `keystore file not found
  at '/home/barry/.android-keystores/does-not-exist.jks'`.
- Blank `storePassword` → exit 1: `android/key.properties is missing:
  storePassword`.
- Escape hatch `-Pcompounder.allowDebugSigning=true` with no key.properties →
  builds (69.3 MB), proving the documented local path works.
- Restored key.properties → `flutter build apk --release --obfuscate
  --split-debug-info=build/symbols` exit 0 (64.4 MB) and `flutter build
  appbundle …` exit 0 (62.0 MB).
- `apksigner verify --print-certs`: `CN=Compounder Upload … SHA-256
  d53d2aeb…9248`, `Verified using v2 scheme: true`. `jarsigner -verify` on the
  AAB: `CN=Compounder Upload` (signed, not debug).
- Minify/shrink **actually applied**, not just declared:
  `build/app/outputs/mapping/release/mapping.txt` = 25,257,647 bytes / 229,509
  lines, header `# compiler: R8`, `# compiler_version: 9.1.31`, `# min_api: 26`;
  `resources.txt` = 115,120 bytes (resource-shrink report);
  `shrunk_resources_binary_format/release/shrunk-resources-binary-format-release.ap_`
  = 446,212 bytes; `classes.dex` contains **0** occurrences of
  `io.flutter.plugins.pathprovider` (renamed) while
  `com.arcanegrowth.compounder.MainActivity` is kept (manifest-referenced).
- `aapt2 dump badging`: `package: name='com.arcanegrowth.compounder'
  versionCode='10' versionName='0.4.0'`, `application-label:'Compounder'`.
- AAB manifest (protobuf) contains `com.arcanegrowth.compounder` and `0.4.0`.

### Device (Pixel 10, Android 17 / API 37)
- `adb install -r` → `Success`; `dumpsys package` → `versionCode=10
  versionName=0.4.0`, `lastUpdateTime` advanced.
- `am start -W -n com.arcanegrowth.compounder/.MainActivity` → `Status: ok`;
  `dumpsys activity activities` → `ResumedActivity: ActivityRecord{… 
  com.arcanegrowth.compounder/.MainActivity …}`.
- Process alive (`pidof` → 9826) after several minutes; Impeller/Vulkan backend
  initialised; `logcat -b crash` empty; `grep -cE "FATAL EXCEPTION|ANR in"` → 0.
- Only benign warnings: one SELinux `max_map_count` denial and a
  `UiContextUtils` non-UI-context warning.

### App ID
- `grep -rn "dev\.compounder\.compounder"` over the tree (excluding `.git`,
  `build`, `.dart_tool`): **zero hits**. History still contains 25 (old
  commits; no rewrite, which is correct).
- Android: `namespace` and `applicationId` = `com.arcanegrowth.compounder`
  (`android/app/build.gradle.kts:50,62`); `MainActivity.kt` package matches and
  the file moved to `kotlin/com/arcanegrowth/compounder/`.
- iOS: `PRODUCT_BUNDLE_IDENTIFIER = com.arcanegrowth.compounder` (app) and
  `com.arcanegrowth.compounder.RunnerTests` (tests) in
  `ios/Runner.xcodeproj/project.pbxproj:386,402,419,434,567,589`.
- Play subscription URL uses `?package=com.arcanegrowth.compounder`
  (`lib/subscription/constants.dart:38`).

### Gates at the reviewed commit
- `dart format --output=none --set-exit-if-changed lib test tool`: 98 files,
  0 changed, exit 0.
- `flutter analyze`: `No issues found!`, exit 0.
- `TZ=America/New_York flutter test`: **530 passed**, exit 0.
- `TZ=UTC flutter test` (43 files, DST files excluded as CI does): **469
  passed**, exit 0.
- `appVersionLabel` guard proven non-vacuous: changed to `Compounder v0.3.9` →
  `test/backlog_minors_test.dart:117` fails (`Differ at offset 14`); restored →
  passes.

### Hygiene
- No tracked build artifacts (`build/`, `.dart_tool/`, `.gradle/`, `*.apk`,
  `*.aab`, `problems-report.html`): none. The problems report was removed in
  `c4b1ae8`.
- Largest tracked blob 76,802 bytes (`third_party/health/lib/src/health_plugin.dart`);
  `.git` is 6.4 MB. No large binaries.
- `.gitignore` covers `android/key.properties`, `*.jks`, `*.keystore`, `*.p8`,
  `*.p12`, `*.pem`, `.env*`, `android/local.properties`, `/build/`,
  `app.*.symbols`, `app.*.map.json`.
- `.gitattributes`: LF normalisation, binary patterns for images/audio/archives,
  `linguist-generated` for lockfile/build output, `linguist-vendored` for
  `third_party/**`. Sane.
- `LICENSE` MIT (Barry Deen, 2026); `third_party/health/LICENSE` and
  `third_party/pdfx/LICENSE` present.
- `proguard-rules.pro`: 19 targeted `-keep` rules, no blanket
  `-keep class ** { *; }`.

### Version control
- Remote: `origin https://github.com/arcane-growth/compounder.git` (fetch+push).
- Per-commit file lists reviewed: each of the five commits touches a coherent
  set (repo docs/CI; problems-report removal; signer-proof fix; Android/iOS
  release hardening; app-ID rename). No unrelated files swept in.
- `origin/main` = `142ffd1`; local `main` = `4b98f12` (ahead 2). See m9.
- Reviewer did not push.

## What the owning agents need to fix
- **DevOps:** M1 (branch protection / plan), M2 (secret scanning claim), M3
  (private vulnerability reporting), m1 (merge methods), m6 (Dependabot gradle),
  m10 (re-run stale Dependabot CI).
- **Mobile App Developer / docs owner:** m2/m3 (tag/commit signing claims),
  m4/m5 (README nav, tool count, network claim), m7/m8 (release-build.md
  commands).
- **Whoever pushed:** m9 — decide whether the three pushed commits were
  intentional; if not, note it and keep the remaining two local until the gate
  clears.

## Status update — 2026-11-10 (settings applied, docs reconciled)

The findings above are the record of the state at review time. The repository has
since been made **public** and the settings were applied; re-verified with `gh api`
on 2026-11-10:

- **M1 resolved** — `branches/main/protection` now returns a rule: 1 required
  approval, Code Owners review, dismiss stale approvals, approval of the latest
  push, four required checks (`Secret scan (gitleaks)`, `Format check`,
  `Analyze and test`, `Release build (ephemeral CI key)`), strict up-to-date,
  conversation resolution, signed commits, linear history, no force-push, no
  deletion, enforced for admins.
- **M2 resolved** — `security_and_analysis.secret_scanning` and
  `.secret_scanning_push_protection` are `enabled`; `secret-scanning/alerts` is
  `[]` (no open alerts). Non-provider patterns and validity checks remain off.
- **M3 resolved** — private vulnerability reporting is now `{"enabled":true}`;
  the `security/advisories/new` link works.
- **m1 resolved** — squash-only (`allow_merge_commit: false`,
  `allow_rebase_merge: false`, `delete_branch_on_merge: true`).
- **Tag protection** — ruleset `Protect release tags (v*)` is active for
  `refs/tags/v*` (deletion + non-fast-forward blocked). No tag is pushed to
  `origin` yet; `v0.4.0` is the first tag that must be signed.
- **m2/m3/m4/m5/m6/m7/m8** — corrected in `README.md`, `SECURITY.md`,
  `docs/branching-and-protection.md`, `docs/release-build.md`,
  `docs/release-process.md` and `.github/dependabot.yml`.
