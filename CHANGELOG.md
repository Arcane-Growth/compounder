# Changelog

All notable changes to Compounder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html). Release tags are
`v<major>.<minor>.<patch>`; the Android/iOS build number lives in
`pubspec.yaml` as the `+<n>` suffix.

This file was seeded from the repository history at the point the project moved
to `github.com/arcane-growth`. Earlier entries are summarised from commit
history, not from contemporaneous release notes.

## [Unreleased] — 0.4.0+10

Release candidate. Not yet tagged.

### Added

- **Day planner and planning pillar** — chronological day planning with schema
  v13 `plan_blocks`, plus coach tools to read, add, move, check off and delete
  plan blocks.
- **Personal records** — detection, celebration, workout summary and history
  views for new bests.
- **Rest-timer audio cues** — 5-second warning tick, go tone at zero, and a mute
  setting.
- **Activity heatmap and gamified daily home screen** — streak and consistency
  view over logged activity.
- **Habit tracker** — schema v10 CRUD, coach tools, backup format 4.
- **Nutrition browsing by date** with a weekly macro/calorie tracker.
- **Manual meal logging** and a macro-to-calorie calculator.
- **Expand/collapse per-set detail** in past workout summaries.
- **Compounder AI subscription** — Play/StoreKit purchase, gateway verification,
  source routing, trialing and past-due grace states.
- **Fitness tab and navigation split** — bottom bar Home/Fitness/Macros/Wealth/
  Coach; Mind moved to the drawer.

### Changed

- Release builds are minified and resource-shrunk with R8 and obfuscated Dart
  symbols; symbol files are archived with each artifact.
- Release signing fails loudly when `android/key.properties` is missing instead
  of silently falling back to the debug key.
- Version bumped to `0.4.0+10`; `appVersionLabel` is asserted against
  `pubspec.yaml` by a test so the two cannot drift.

### Fixed

- Coach planner: non-finite plan times guarded, days isolated, stale-day load
  guard, midnight marker rollover.
- Workout: PR prior-best scoped to earlier sessions; one session baseline shared
  across duplicate entries; elapsed timer ellipsised at narrow widths.
- Coach approval card: the Approve button was clipped off-screen.
- Meal edit no longer loses data on a no-op edit.
- Backup import: exercise ids remapped so workout history keeps its exercises;
  unknown-column imports no longer abort.
- Net-worth history is deterministic and database-derived.
- Coach turn history is bounded and trimmed on turn boundaries so a request never
  starts with `role: tool`.
- Calendar-day arithmetic replaces `Duration` day stepping (DST correctness).
- Health Connect sync: 1-day chunking, `largeHeap`, resumable per-chunk sync;
  sleep history loss fixed with composite sleep UUIDs and schema 5/6/7 recovery.

### Security

- CI now runs a gitleaks scan over every commit on every ref.
- Dependabot monitors `pub` and `github-actions`.
- Workflows run with least-privilege `permissions` and third-party actions pinned
  to commit SHAs.
- Repository hygiene: signing material, `.env*`, local SDK paths and build
  reports are gitignored; a tracked Gradle build report was removed.

## [0.3.1] — 2026-11-05

### Added

- Meal notes and a meal gallery.
- Gallery meal picker restored.

### Changed

- Health tab renamed to Fitness; number formatting unified.

### Fixed

- Sleep total calculation.
- Integer breathing countdown restored.

## [0.3.0] — 2026-11-05

### Added

- Google Health Connect import (read-only) with coach health tools across sleep,
  heart rate, HRV, steps, distance, calories, workouts, body measurements and
  vitals.
- MIT LICENSE file added (the README already claimed MIT).

### Fixed

- Health Connect sync OOM: 1-day chunking, `largeHeap`, resumable per-chunk sync.
- Sleep history loss: composite sleep UUIDs and schema 5/6/7 recovery.

## [0.2.2] — 2026-11-05

### Added

- Net-worth trend and quick balance updates.
- Workout logging overhaul.

## [0.2.1] — 2026-09-12

### Fixed

- Startup hang when the configured AI endpoint is unreachable.

## [0.2.0] — 2026-09-12

### Added

- File uploads, financial upside tools, reminders, markdown rendering and guided
  breathing.

## [0.1.0] — 2026-09-12

### Added

- Initial release: Flutter port of OpenFit expanded into health, wealth and mind
  domains, with a bring-your-own-AI coach.
