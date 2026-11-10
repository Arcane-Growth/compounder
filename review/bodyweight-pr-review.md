# Gate: bodyweight rep-based personal records

- **Verdict:** **APPROVE**
- **Reviewed commit:** `7c94726` on `feat/bodyweight-pr` (off `feat/planner-timeline` @ `10a1390`)
- **Reviewer:** Code Reviewer
- **Date:** 2026-11-10
- **Scope:** 11 files, +995/−84. Detection (`lib/domain/domain.dart`), persistence
  (`lib/data/store.dart`, `lib/data/models.dart`), surfacing
  (`lib/ui/summary.dart`, `lib/ui/workout.dart`), backup comment
  (`lib/services/backup.dart`), and tests (`test/bodyweight_pr_test.dart` + version
  bumps in four existing test files).

## Verdict

APPROVE. The rep-based rule is correct and matches the owner spec on every axis I
could probe: strictly-greater-than prior best and earlier same-session bodyweight
sets, first-ever set establishes the baseline, warm-ups and reps < 1 excluded, no
double-flagging across duplicate entries, and a 0 kg set can never fake an e1RM PR
because both sides of the comparison exclude weighted work. Weighted e1RM behaviour
is byte-for-byte unchanged (the weighted branch of `assessPr` is untouched). The
v13→v14 migration is additive, idempotent, and adds no false PRs on a v13 database.
The recompute path re-derives flags for every entry of the exercise in one
transaction, so edits and deletes stay consistent. The UI renders rep PRs as reps
and fires the celebration cue; the e1RM chart drops bodyweight-only sessions instead
of plotting a flat 0 kg line.

No Blockers. No Majors. Three Nits (none blocking).

## What I verified (commands run by the reviewer, in worktree `wt-bodyweight-pr` at `7c94726`)

- `dart format --output=none --set-exit-if-changed lib test tool` → **clean**
  (100 files, 0 changed).
- `flutter analyze --no-pub` → **No issues found!**
- `TMPDIR=/home/barry/.cache/flutter-tmp flutter test --no-pub` → **00:16 +603: All
  tests passed!**
- Independent probe (my own 12-test harness, `test/reviewer_gate_bwpr_test.dart`,
  removed after the run): **all 12 passed**, covering the 0x10 → 0x12 sequence, the
  negative cases, weighted-unchanged, mixed history, no double-flagging, the v13→v14
  migration on a v13 DB, the chart exclusion, and the summary rep rendering.

## Acceptance criteria — independently reproduced

| Criterion | Result |
|---|---|
| 0x10 first session = PR | ✅ `prReps=10`, `prE1rmKg=null` (probe + `bodyweight_pr_test.dart:268`) |
| 0x12 later session = PR | ✅ `prReps=12`, `prE1rmKg=null` (probe + `bodyweight_pr_test.dart:279`) |
| 0x10 repeat = not PR | ✅ `isPr=false` (probe + `bodyweight_pr_test.dart:289`) |
| 0x8 = not PR | ✅ `isPr=false` (probe + `bodyweight_pr_test.dart:298`) |
| 0x20 warm-up = not PR | ✅ `isPr=false` (probe + `bodyweight_pr_test.dart:305`) |
| Weighted e1RM PR unchanged | ✅ `prE1rmKg=e1RM(110,5)`, `prReps=null` (probe + `bodyweight_pr_test.dart:314`) |
| Migration adds no false PRs on v13 DB | ✅ weighted flag preserved, bodyweight stays unflagged, `pr_reps` null on all migrated rows, idempotent re-run (probe + `bodyweight_pr_test.dart:442`) |
| prSummary renders reps | ✅ `isRepBased=true`, `previousBestReps=10`, `newBestReps=12`, `deltaReps=2` (probe + `bodyweight_pr_test.dart:380`) |
| New tests fail when the fix is reverted | ✅ proven below |

## Non-vacuity (revert the fix, quote the failure)

**Detection rule.** Reverted the bodyweight branch of `assessPr`
(`lib/domain/domain.dart:155`) and the v14 migration step, kept all tests, and ran
`test/bodyweight_pr_test.dart`. **16 tests failed** with clean assertion failures,
including:

```
assessPr bodyweight branch 0x10 as the first-ever bodyweight set is a baseline rep PR [E]
  Expected: true
    Actual: <false>
assessPr bodyweight branch 0x12 beats a prior-session bodyweight best of 10 reps [E]
  Expected: true
    Actual: <false>
store bodyweight PR detection and persistence prSummary reports a bodyweight PR as reps [E]
  Expected: an object with length of <1>
    Actual: []
workout screen: bodyweight PR badge and celebration tone completing a bodyweight PR ... [E]
  Expected: contains WorkoutCue:<WorkoutCue.personalRecord>
    Actual: []
```

**Schema.** Restored the domain fix, then removed `pr_reps` from the CREATE TABLE
(`lib/data/store.dart:181`) and the v14 migration block, and ran only the migration
test. It failed with:

```
store bodyweight PR detection and persistence migration 13 -> 14 adds pr_reps without false PRs [E]
  SqliteException(1): while preparing statement, no such column: pr_reps, SQL logic error (code 1)
    Causing statement: UPDATE workout_sets SET is_pr = ?, pr_e1rm_kg = ?, pr_reps = NULL WHERE id = ?
```

Both fixes restored; the file is green again (`00:03 +29: All tests passed!`).

## Findings

No Blockers. No Majors.

### Nits (non-blocking)

1. **`lib/services/backup.dart:39-44` — comment is slightly inaccurate for the
   v13→v14 downgrade path.** The comment says "An older build drops the PR columns it
   does not know and restores the sets as non-PR." That is true for a pre-v12 build,
   but a v13 build (which has `is_pr`/`pr_e1rm_kg` but not `pr_reps`) restoring a
   bodyweight rep PR keeps `is_pr=1` while dropping `pr_reps`, so the set restores as
   a PR with no snapshot — not "as non-PR." The behaviour is correct (the column
   filter at `backup.dart:188` is what does the work); only the prose overstates it.
   Cosmetic.

2. **`lib/domain/domain.dart` weighted branch — a 0.001 kg set is "weighted" but can
   never be a PR.** `weightKg == 0` is the bodyweight test, so a set logged at 0.001
   kg takes the weighted branch, where `formatE1rm(epley(0.001, reps))` rounds to 0
   and `value <= sessionBest` (≥ 0) is always true. It is therefore never a PR. This
   is consistent with the pre-change behaviour (0.001 kg was never a PR before
   either), and the UI clamps negative weights to 0 (`workout.dart:293`), so it is
   not reachable in practice. Noted for completeness, not a regression.

3. **`lib/data/store.dart:1096` — "weighted wins" hides a same-session bodyweight PR
   in `prSummary`.** When an exercise has both a weighted PR and a bodyweight PR in
   one session, the summary shows only the weighted row. This is documented
   (`store.dart:1063`) and the workout badge still shows the rep PR, so it is a
   deliberate design choice, not a defect. Flagging only so the owner is aware the
   summary is one-row-per-exercise by construction.

## Correctness notes (verified, no action needed)

- **Both sides of the bodyweight comparison exclude weighted work.** `assessPr`
  (`domain.dart:155`) folds `earlierSets` over `s.$1 == 0` only, and
  `_priorBestReps` (`store.dart:925`) filters `s.weight_kg = 0`. A 0 kg set therefore
  neither borrows nor fakes an e1RM.
- **The weighted branch is untouched.** The diff adds a bodyweight branch above it;
  the e1RM math, `formatE1rm`, and the `beatsPrior`/`sessionBest` logic are unchanged.
- **`_priorScope` is shared and correct.** Both `_priorBestKg` and `_priorBestReps`
  bound "prior" to sessions finished before the target (tie-broken by id), so a
  historical summary never sees a later session's numbers.
- **Recompute is transactional and per-exercise.** `_recomputePrFlags`
  (`store.dart:995`) accumulates the session baseline across every entry for an
  exercise (ordered by `completedAt`), so a duplicate entry cannot double-flag, and
  the whole pass runs in one `db.transaction`.
- **Migration is additive and idempotent.** `_addColumnIfMissing`
  (`store.dart:445`) guards the `ALTER TABLE`, and the step only adds a nullable
  column — no existing row is rewritten, so a v13 history can never show a false rep
  PR.
- **Chart exclusion is safe.** `sessionPoints` (`domain.dart:74`) drops only sessions
  whose best e1RM is 0 (bodyweight-only or zero-rep); mixed sessions keep their
  weighted e1RM.

## Risk

None known. The change is well-scoped, the weighted path is provably unchanged, and
the new behaviour is guarded by non-vacuous tests. The three nits are cosmetic or
documented design choices.
