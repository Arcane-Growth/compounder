# Gate: personal records (PR detection, celebration, summary, history)

**Reviewed commit:** `8208b74` (`feat(workout): personal records — detection, celebration, summary, history`)
**Parent:** `e0e5b99` (rest-timer audio gate)
**Reviewer:** Code Reviewer
**Date:** 2026-11-09
**Worktree:** `/tmp/pr-review-wt` (detached at `8208b74`)

## Verdict: APPROVE WITH FIXES

The feature is well-built: the core detection rule is correct for the common case, the
schema migration is additive and safe, the backup round-trip preserves the PR columns, the
celebration is injectable and respects the mute, and the rest-timer batch is not regressed.
Two **Major** correctness defects remain in the summary/history surfaces; they are
display/count bugs, not data loss, but they are user-visible and reachable from the
History, Home and Fitness screens.

---

## Findings

### MAJOR-1 — `prSummary` computes "previous best" against a moving baseline; historical summaries are wrong

- **File:** `lib/data/store.dart:935` (`prSummary` calls `_priorBestKg(entry.key, workoutId)`).
- **Root cause:** `_priorBestKg` (`lib/data/store.dart:819-833`) selects the best e1RM across
  *every* finished session except `excludeWorkoutId` — including sessions that happened
  **after** the workout being summarized. The persisted `pr_e1rm_kg` (new best) is stable,
  but the previous best is recomputed against a baseline that moves forward.
- **Repro (PROBE A):** session A = 100 kg × 5 (first ever), then session B = 120 kg × 5.
  `prSummary(A)` returns `previousBestKg = e1RM(120,5) = 140`, `newBestKg = e1RM(100,5) = 110`,
  `deltaKg = -30`, `isBaseline = false`. The summary renders
  `Previous best 140 kg → new best 110 kg (+-30 kg)` instead of `First PR · 110 kg`.
- **Reachable:** `SummaryScreen` is opened for any past workout from `lib/ui/history.dart:38`,
  `lib/ui/home.dart:347`, `lib/ui/fitness.dart:233`.
- **Fix:** bound the prior-best query to sessions that started before this workout
  (e.g. `AND w.started_at < (SELECT started_at FROM workouts WHERE id = ?)`), or persist the
  previous best alongside `pr_e1rm_kg` at PR time. The stored snapshot must not depend on
  later sessions.
- **Evidence:** probe failed `Expected: <0>  Actual: <140.0>`.

### MAJOR-2 — Same exercise twice in one workout resets the session baseline per entry, producing false PRs

- **File:** `lib/data/store.dart:884` (`final earlier = <(double, int)>[];` inside the
  per-entry loop in `_recomputePrFlags`).
- **Root cause:** `earlier` is rebuilt for each `workout_exercises` row, so a set in the
  second entry of the same exercise does not see the first entry's performed sets. The
  spec says "every earlier performed set in the session".
- **Repro (PROBE B):** one workout with "Back squat" at position 0 (100 kg completed) and
  again at position 1 (90 kg completed). The 90 kg set is flagged `is_pr = 1` even though
  100 kg was already performed earlier in the same session.
- **Impact:** false PR badge in the workout/summary, and an inflated history PR count
  (`loadHistory` counts both flagged sets).
- **Fix:** accumulate `earlier` across entries that share the same `exercise_id` (key the
  accumulator by exercise), not per entry.
- **Evidence:** probe failed `Expected: <0>  Actual: <1>`.

### MINOR-1 — Prior-session incomplete placeholders suppress legitimate PRs (asymmetry)

- **File:** `lib/data/store.dart:819-833` (`_priorBestKg` filters `is_warmup = 0 AND reps >= 1`
  but not `completed_at IS NOT NULL`).
- The current session excludes incomplete sets from `earlier` (`lib/data/store.dart:901-906`),
  but the prior-session query includes them. A finished session with an untouched 120 kg
  placeholder and a completed 100 kg set makes a 110 kg set in the next session non-PR.
- This mirrors `progressFor`'s existing shape, so it is consistent with the chart, but it is
  a false negative for the celebration.
- **Fix:** add `AND s.completed_at IS NOT NULL` to `_priorBestKg`, or document the asymmetry.
- **Evidence:** probe failed `Expected: <1>  Actual: <0>`.

### MINOR-2 — `_prSection` silently swallows a `prSummary` failure

- **File:** `lib/ui/summary.dart:151-155`. The `FutureBuilder` uses
  `snap.data ?? const <PrSummary>[]` and never checks `snap.hasError`, so a DB error hides
  the PR section with no log. The rest of the summary has an explicit error path
  (`snap.hasError` at line 56).
- **Fix:** log `snap.error` (debugPrint) and/or show a small error row.

### NIT-1 — `_prDetail` always prefixes '+' to the delta

- **File:** `lib/ui/summary.dart:186`. `'+${trimZero(...)}'` renders `+-30 kg` when the delta
  is negative (which MAJOR-1 can produce). Fixing MAJOR-1 removes the negative case, but a
  defensive sign check is cheap.

### NIT-2 — `_recomputePrFlags` is not transactional

- **File:** `lib/data/store.dart:873-909`. A mid-loop failure leaves flags partially updated.
  Low risk (local SQLite), but a transaction would make it atomic.

### Pre-existing (out of scope) — `_ElapsedTimer` overflows at 320dp/textScale 2.0

- **File:** `lib/ui/workout.dart:682-691`. The `Row` has no `Flexible`/`Expanded`, so the
  `Text` takes its natural width and overflows the AppBar title. Confirmed identical failure
  on `e0e5b99` (parent commit), so **not** a regression from this PR. Worth a follow-up.

---

## What I verified

- Pinned worktree at `8208b74`; `flutter pub get`; `flutter analyze` → **"No issues found!"**.
- Full suite: `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` → **458 tests, "All tests passed!"**
  (including 42 `personal_records_test` lines and the `rest_sounds_test` file).
- Asset: `assets/sounds/pr_fanfare.wav` present, valid RIFF/WAVE, 44.1 kHz mono, 0.48 s;
  bundled in `pubspec.yaml`.
- Migration v11→v12: test passes; reverting the migration block fails with
  `no such column: s2.is_pr`.
- Backup round-trip: test passes; excluding the PR columns from export fails the test.
- Unit handling: lb display test passes; `fromKg` conversion used.
- Mute: test passes; removing the mute check fails the test.
- Celebration: test passes; removing the call fails the test.
- Zero-rep: test passes; reverting `reps < 1` to `reps < 0` fails the test.
- Strict inequality: test passes; reverting `>` to `>=` fails the test.
- Rest-timer: tests pass; reverting `next <= 5` to `next <= 6` fails the test.
- Summary/history at 320dp/textScale 2.0: summary PR section passes; history row passes;
  workout screen fails only on the pre-existing `_ElapsedTimer` overflow.
- Combined state at `41f8e60` (the rest-timer 5s-minimum fix, committed on top of the PR
  feature while this review ran): `flutter analyze` clean, **460 tests pass**. The
  rest-timer fix does not touch the PR logic, so the findings above still apply.

## Regression-guard non-vacuity proofs (quoted)

| Guard | Revert | Failure |
|---|---|---|
| strict prior-best inequality | `value > prior` → `value >= prior` | `Expected: false  Actual: <true>` |
| mute respected | remove `restSoundsEnabled` check | `Expected: empty  Actual: [WorkoutCue.personalRecord]` |
| zero-rep exclusion | `reps < 1` → `reps < 0` | test fails (`epley` ArgumentError) |
| migration v11→v12 | skip the v12 block | `no such column: s2.is_pr` |
| celebration fires | remove `_playCue(personalRecord)` | `Expected: contains personalRecord  Actual: []` |
| backup carries PR columns | drop PR columns from export | test fails |
| rest tick at 5 s | `next <= 5` → `next <= 6` | `Expected: empty  Actual: [WorkoutCue.fiveSeconds]` |

## Remaining risk

- MAJOR-1 and MAJOR-2 are display/count correctness bugs on historical and
  duplicate-exercise sessions; the persisted flags for the common single-entry case are
  correct and the migration cannot produce false PRs.
- The `_ElapsedTimer` overflow is pre-existing and out of scope for this gate.
