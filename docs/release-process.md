# Release process

How a Compounder release is cut, signed, published and — when it goes wrong —
rolled back. Build mechanics (versioning fields, R8, obfuscation, iOS
prerequisites) live in [release-build.md](release-build.md); this document covers
the pipeline and the decisions around it.

## Versioning

- User-visible version: semver `MAJOR.MINOR.PATCH`, set in `pubspec.yaml` as
  `version: <semver>+<buildNumber>`.
- Build number (`+<n>`): the Android `versionCode` and iOS `CFBundleVersion`. It
  must strictly increase for every store upload, including re-uploads after a
  rejection. Never reuse or decrement it.
- Git tag: `v<semver>` — exactly the semver part, no build number, no prefix
  other than `v`. `release.yml` refuses to build if the tag and `pubspec.yaml`
  disagree.
- Pre-release tags carry a suffix (`v1.0.0-rc1`) and publish as GitHub
  pre-releases.
- `lib/ui/settings.dart` (`appVersionLabel`) must match the semver part;
  `test/backlog_minors_test.dart` fails if it drifts.

## Signing material

Release artifacts are signed with the Android upload key. The keystore is **not**
in the repository. CI receives it as repository secrets:

| Secret | Contents |
| --- | --- |
| `KEYSTORE_BASE64` | the `.jks` file, base64-encoded, single line |
| `KEYSTORE_PASSWORD` | keystore password |
| `KEY_ALIAS` | key alias inside the keystore |
| `KEY_PASSWORD` | key password |

Producing `KEYSTORE_BASE64`:

```bash
base64 -w0 /path/to/compounder-upload.jks   # macOS: base64 -i file
```

Store these under **Settings → Secrets and variables → Actions**. `release.yml`
validates all four before doing any work and fails with an explicit
`::error::Missing repository secret(s): …` if one is absent — it never falls back
to a debug key.

`android/app/build.gradle.kts` independently fails the build when
`android/key.properties` is missing or points at a missing keystore, so a
misconfigured release cannot silently ship a debug-signed artifact.

**Key custody:** the upload keystore and its passwords are the single most
important secret in the project. Losing them means you cannot update the app on
Play under the same identity. Keep at least two offline copies, and enrol in Play
App Signing so Google holds the app-signing key rather than you.

The current keystore is a placeholder until production keys are supplied; see
[release-build.md](release-build.md).

## Cutting a release

1. **Prepare the version.** Bump `pubspec.yaml` (`version:` and `+buildNumber`)
   and `appVersionLabel` in `lib/ui/settings.dart` in one PR. Update
   `CHANGELOG.md` — move *Unreleased* entries under the new version heading.
2. **Verify locally.** `flutter analyze`, both `flutter test` passes (see
   [CONTRIBUTING.md](../CONTRIBUTING.md)), and a release build that is installed
   and exercised on a device. R8 breakage does not show up at build time.
3. **Merge to `main`** through a reviewed PR with all required checks green.
4. **Tag and push the tag:**

   ```bash
   git checkout main && git pull --ff-only
   git tag -s v0.4.0 -m "Compounder 0.4.0"
   git push origin v0.4.0
   ```

   Signed tags (`-s`) are expected; see
   [branching-and-protection.md](branching-and-protection.md). No tag has been
   pushed to `origin` yet, and `v0.1.0`–`v0.3.2` predate the policy (lightweight
   or unsigned annotated). **`v0.4.0` is the first tag that must be signed** —
   `git tag -v v0.4.0` must print a signature before the tag is pushed.
5. **Watch the Release workflow.** It builds the signed AAB and APK, proves the
   APK carries the upload certificate (not the debug one), writes
   `SHA256SUMS.txt`, and attaches the AAB, APK, symbol archive and checksums to a
   GitHub Release. A failure at any step means no release is published.
6. **Archive the symbols.** `compounder-<tag>-symbols.zip` is attached to the
   release and kept as a workflow artifact for 90 days. Without it, crash traces
   from the obfuscated build cannot be symbolicated. Copy it somewhere durable
   (object storage) before the artifact expires.
7. **Upload to the stores** (below).

## Store upload

### Google Play

1. Download `compounder-<tag>.aab` from the GitHub Release and verify it against
   `SHA256SUMS.txt`.
2. Create a new release in Play Console on the appropriate track (internal →
   closed → open → production). Upload the AAB.
3. Complete the release notes, data-safety form and content rating if they
   changed.
4. Roll out in stages (e.g. 10% → 50% → 100%) and watch Android vitals for
   crashes and ANRs before widening.

### Apple App Store

iOS builds are not produced by CI yet (they need a macOS runner and Apple
credentials). Build on a Mac with `flutter build ipa` once the prerequisites in
[release-build.md](release-build.md) are met, then upload with Transporter or
`xcrun altool`/`notarytool` and submit through App Store Connect.

## Rollback

Nothing in this pipeline mutates production automatically, so rollback is a
deliberate human action.

| Situation | Action |
| --- | --- |
| Bad artifact attached to a GitHub Release | Delete the release and the tag, fix, re-tag with a **new build number**. Never re-use a build number that reached a store. |
| Bad build already on Play (staged rollout) | Halt the rollout in Play Console. Users on the bad build stay on it until a fix ships. |
| Bad build at 100% on Play | Ship a hotfix with an incremented build number as fast as possible; Play does not allow downgrades. |
| Bad build on App Store | Remove from sale if severe, ship a hotfix; App Store Connect does not allow downgrades either. |
| Pipeline itself broken | Revert the workflow change on `main`; the previous tag's artifacts remain downloadable. |

Because stores do not permit downgrades, the only real rollback is a forward fix.
That is why staged rollouts and a device-tested release build are mandatory.

## Hotfix

1. Branch `fix/<slug>` from the released tag, not from `main`, if `main` has
   moved on.
2. Fix, add a regression test that fails without the fix, verify locally.
3. Bump the patch version and build number, update `CHANGELOG.md`.
4. PR into `main`, tag `v<new-patch>`, let `release.yml` publish, upload to the
   stores.

## Release checklist

- [ ] `pubspec.yaml` version and build number bumped; `appVersionLabel` matches.
- [ ] `CHANGELOG.md` updated.
- [ ] `flutter analyze` clean; both `flutter test` passes green.
- [ ] Release build installed and exercised on a real device.
- [ ] PR reviewed and merged with all required checks green.
- [ ] Signed tag pushed; Release workflow green.
- [ ] `SHA256SUMS.txt` verified against the downloaded artifacts.
- [ ] Symbol archive copied to durable storage.
- [ ] Store upload staged, not 100% on day one.
