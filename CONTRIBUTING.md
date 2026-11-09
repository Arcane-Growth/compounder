# Contributing to Compounder

Thanks for helping. This document is the contract for changes to this repository:
how to branch, how to commit, what CI will check, and what a reviewer will expect.
Read it before opening a pull request.

By contributing you agree to the [Code of Conduct](CODE_OF_CONDUCT.md) and to
license your contribution under the project's MIT license.

## Before you start

- For anything larger than a typo, **open an issue first** so we can agree on the
  approach before you spend time on it.
- Security problems do **not** go in a public issue — see [SECURITY.md](SECURITY.md).

## Local setup

Prerequisites: Flutter stable (3.47.x is what CI pins), Android SDK for Android
builds, Xcode on macOS for iOS.

```bash
flutter pub get
```

### Verify your change

Run the same checks CI runs. Do not open a PR until they pass locally.

```bash
# Formatting — CI fails on any diff.
dart format lib test tool

# Static analysis — must be clean, no new warnings.
flutter analyze

# Tests. The DST regression guards assert on ambient-zone transitions and fail
# loudly rather than passing vacuously when the runner has none, so pin the zone.
TZ=America/New_York flutter test

# Second pass with local time == UTC, excluding the files that require a real
# DST transition in setUpAll.
TZ=UTC flutter test $(ls test/*_test.dart | grep -v -e dst_day_windows_test.dart -e digest_dst_test.dart -e nutrition_dst_test.dart -e activity_heatmap_dst_test.dart)
```

**TMPDIR caveat (this workspace):** `/tmp` is a 16 GB tmpfs that fills up during
Flutter test runs. The symptom is `Disk quota exceeded, errno 122` on
`listener.dart.dill`, followed by a hang after "All tests passed!" that gets
recorded as a timeout. Always run:

```bash
TMPDIR=/home/barry/.cache/flutter-tmp flutter test
```

and kill a hung run with `pkill -f "flutter_tools.snapshot test"`.

### Release builds

`flutter build apk --release` needs `android/key.properties` and a keystore; the
Gradle config fails loudly without them (there is no silent debug fallback). For
a local `flutter run --release` without the keystore, set
`compounder.allowDebugSigning=true` in `~/.gradle/gradle.properties` — never in
the repository's `android/gradle.properties`. Full details:
[docs/release-build.md](docs/release-build.md).

## Branches

Branch from `main`, keep the branch short-lived, and use a descriptive prefix:

| Prefix | Use |
| --- | --- |
| `feat/<slug>` | new user-visible capability |
| `fix/<slug>` | bug fix |
| `chore/<slug>` | tooling, CI, dependencies, docs |
| `release/<version>` | release preparation only |

`main` is protected: no direct pushes, no force-push, no deletion.

## Commits

- Conventional-commit style subject: `type(scope): summary` — e.g.
  `fix(workout): scope PR prior-best to earlier sessions`.
- Imperative mood, lower-case summary, no trailing period, ≤ 72 characters.
- The body explains **why** the change is needed and what it costs (migration,
  behaviour change, rollback). Reference the issue or audit id it closes.
- One logical change per commit. Do not mix formatting-only churn with behaviour
  changes — a reviewer cannot see the real diff otherwise.
- **Path-scoped commits.** This repository is shared with other agents and
  contributors; `git add -A` sweeps up work that is not yours. Commit explicitly:

  ```bash
  git commit -m "fix(workout): ..." -- lib/ui/workout.dart test/workout_test.dart
  ```

  (Note the argument order: `git commit -m "..." -- <paths>` works; the reverse
  order fails on this git version.)
- Never commit secrets. `android/key.properties`, `*.jks`, `*.keystore`, `.env*`
  are gitignored; if you need a new secret, add it to GitHub Actions secrets and
  reference it by name.

## Pull requests

Use the pull-request template. A PR is mergeable only when:

1. It has a linked issue (or explains why one is unnecessary).
2. Every CI job is green: **Secret scan (gitleaks)**, **Format check**,
   **Analyze and test**, **Release build (ephemeral CI key)**.
3. It has at least one approving review from a code owner
   (see [.github/CODEOWNERS](.github/CODEOWNERS)).
4. New behaviour has tests, and the tests fail without the fix (a regression
   guard that passes on the broken code is not a guard).
5. No unrelated files are touched. Formatting-only changes are a separate PR.

Reviewers: correctness, security, performance, and hygiene. A reviewer may ask you
to prove a guard is non-vacuous by reverting the fix and quoting the failure.

## Documentation

- User-facing behaviour changes update `README.md`.
- Release-relevant changes get a `CHANGELOG.md` entry under *Unreleased*.
- Pipeline or process changes update `docs/`.
