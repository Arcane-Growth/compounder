## What and why

<!-- What changes, and what problem it solves. Link the issue or audit id. -->

Closes #

## How it was verified

<!-- Exact commands and their results. Paste the output, not a summary. -->

```
flutter analyze
TZ=America/New_York flutter test
TZ=UTC flutter test $(ls test/*_test.dart | grep -v -e dst_day_windows_test.dart -e digest_dst_test.dart -e nutrition_dst_test.dart -e activity_heatmap_dst_test.dart)
```

## Regression guard

<!-- For a bug fix: which test fails without this change, and what does it say?
     A guard that passes on the broken code is not a guard. -->

## Risk and rollback

<!-- Blast radius: who is affected, what breaks if this is wrong, and how to undo
     it. "Revert the commit" is a valid answer if it is true. -->

## Checklist

- [ ] `dart format lib test tool` produces no diff
- [ ] `flutter analyze` is clean
- [ ] Both test passes are green (TZ pinned, `TMPDIR=/home/barry/.cache/flutter-tmp`)
- [ ] New behaviour has tests; the regression guard fails without the fix
- [ ] No secrets committed (`*.jks`, `*.keystore`, `android/key.properties`, `.env*`)
- [ ] `CHANGELOG.md` updated under *Unreleased* (user-visible changes only)
- [ ] Docs updated if behaviour, pipeline or process changed
- [ ] No unrelated files touched; formatting-only changes are a separate PR
- [ ] Release builds still work (`flutter build apk --release` / `appbundle`)
