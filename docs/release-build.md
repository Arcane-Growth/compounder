# Release builds

How Compounder is built, signed and versioned for distribution. Everything here
is enforced by `android/app/build.gradle.kts` unless marked *manual*.

## Versioning

`pubspec.yaml` carries the single source of truth:

```
version: <major>.<minor>.<patch>+<buildNumber>
```

- **Semver** for the user-visible version (`flutter.versionName` →
  `versionName` on Android, `CFBundleShortVersionString` on iOS).
- **Build number** is the Android `versionCode` and the iOS `CFBundleVersion`.
  It must strictly increase for every upload to Play or App Store Connect; Play
  rejects a re-used `versionCode` and App Store Connect rejects a re-used
  `CFBundleVersion` for the same version string.
- Never reuse or decrement a build number, including for a rejected upload.
- `lib/ui/settings.dart` (`appVersionLabel`) must match the semver part;
  `test/backlog_minors_test.dart` fails if it drifts.
- Tag releases in git as `v<semver>` (e.g. `v0.4.0`) once the artifact is
  uploaded.

Current: `0.4.0+10` — release candidate. `1.0.0` is the owner's call, not
something a build change should invent.

## Android signing

The upload keystore lives outside the repository (currently
`/home/barry/.android-keystores/compounder-upload.jks`, alias
`compounder-upload`). `android/key.properties` is gitignored and points at it:

```
storeFile=/absolute/path/to/compounder-upload.jks
storePassword=...
keyAlias=compounder-upload
keyPassword=...
```

`android/app/build.gradle.kts` fails the build before any release task runs if
`key.properties` is missing, incomplete, or points at a keystore that does not
exist. There is no silent fallback to the debug key: a debug-signed artifact
installs and runs fine locally, so the mistake would otherwise only surface when
Play rejects the upload.

Local escape hatch, for `flutter run --release` on a machine without the
keystore: put `compounder.allowDebugSigning=true` in
`~/.gradle/gradle.properties`. That file is user-level and never committed, so
CI stays strict. Do not put it in the repository's `android/gradle.properties`.

Production keys: the current keystore is a placeholder. When the owner supplies
production keys, replace `key.properties` and the keystore file; nothing else
changes. Enrol in Play App Signing before the first production upload.

## Android release build

R8 is enabled for release (`isMinifyEnabled`, `isShrinkResources`, full mode)
with `android/app/proguard-rules.pro`. Rules are only added for code that is
reached reflectively or through JNI (Gson in flutter_local_notifications, Tink
in flutter_secure_storage, Health Connect models, plugin entry points). Do not
add blanket `-keep class ** { *; }` rules — they defeat shrinking.

Build commands:

```bash
# APK for device testing
flutter build apk --release --obfuscate --split-debug-info=build/symbols

# Play upload artifact
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
```

`--obfuscate` renames Dart symbols; `--split-debug-info` writes
`build/symbols/app.android-*.symbols`. **Archive that directory with the
artifact** — without it, Dart stack traces from release crashes cannot be
symbolicated (`flutter symbolize -i <stack> -d build/symbols/app.android-arm64.symbols`).
Both are gitignored (`app.*.symbols`, `app.*.map.json`), so CI must upload them
as build artifacts rather than commit them.

CI (`release.yml`) runs exactly:

```bash
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
flutter build apk --release --obfuscate --split-debug-info=build/symbols
```

then proves the APK carries the upload certificate (not the debug key), writes
`SHA256SUMS.txt`, uploads the AAB, APK and `build/symbols/` as workflow
artifacts, and publishes them to a GitHub Release. The keystore and
`key.properties` are materialised from CI secrets before the build; the build
fails loudly if they are absent.

## iOS

- Bundle identifier: `com.arcanegrowth.compounder` (final; matches the Android
  `applicationId`. Irreversible after the first App Store upload).
- Deployment target: iOS 15.0 (`IPHONEOS_DEPLOYMENT_TARGET` in
  `Runner.xcodeproj`), above Flutter's minimum.
- `CFBundleShortVersionString` / `CFBundleVersion` come from
  `FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`, i.e. `pubspec.yaml`.
- `ios/Podfile` is not committed; `flutter build ipa` generates it on first run
  on macOS. Commit the generated Podfile afterwards so plugin versions are
  pinned.
- Usage strings for `image_picker` (camera, photo library) are in
  `ios/Runner/Info.plist`; HealthKit strings are already present.

What the owner must supply before `flutter build ipa` can produce a signed
artifact (none of this is needed for CI until iOS builds run on a macOS
runner):

1. Apple Developer Program membership and the Team ID
   (`DEVELOPMENT_TEAM` in `Runner.xcodeproj`, currently unset).
2. An App Store Connect app record with the final bundle identifier.
3. A distribution certificate and provisioning profile, or App Store Connect API
   key credentials for `xcodebuild -exportArchive` / `flutter build ipa
   --export-options-plist`.
4. HealthKit entitlement approval if the app is to write Health data (read-only
   import works without it).

## Verification checklist

```bash
flutter analyze
TMPDIR=/home/barry/.cache/flutter-tmp flutter test
flutter build apk --release
flutter build appbundle --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
# Android 17 renamed the field to `ResumedActivity` (no `m` prefix); the
# optional `m` keeps this working on older devices too.
adb shell dumpsys activity activities | grep -m1 -E 'm?ResumedActivity'
adb logcat -d | grep -E "FATAL|AndroidRuntime"
```

A minified build must be launched and exercised on a device before shipping:
R8 breakage (missing Gson fields, stripped JNI entry points) does not show up at
build time.
