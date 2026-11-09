# Gate review — nutrition date/weekly tracker, manual meal logging, workout set expansion

Reviewer: Code Reviewer. Date: 2026-11-08.
Repo: compounder, branch `main`, HEAD `f778962` (detached worktree
`/home/barry/.cache/review-wt/nutrition-gate`).
Scope: commits `81af0e2` (manual meal logging + macro→calorie calculator), `c4b4912`
(per-date nutrition browsing + weekly tracker), `f778962` (expand/collapse sets in past
workout summaries). Read-only review; no production code changed.

## Verdict

**BLOCK — 1 blocker, 1 major, 6 minor, 3 nit.** The blocker is a real data-loss path in
edit mode: a no-op "Save changes" rewrites stored nutrition (calories and rounded
macros). The major is a vacuous guard in the proof script. Everything else is quality.

## Repo facts verified

- `git log --oneline -12` at review start: `f778962`, `c4b4912`, `81af0e2`, `b77c6b6`,
  `12dd17c`, … The three-feature batch tip is `f778962`; the review worktree is pinned
  there. (Main advanced to `9559cea`, the habit tracker / schema v10, while this review
  was running — that is a separate gate; the schema-v9 check below applies to `f778962`.)
- `git rev-parse origin/main` = `12dd17ce070831b40306023da0070a7121773f10` — nothing pushed.
- `lib/data/store.dart:80: version: 9` at `f778962` — no schema bump in this batch.
- `git diff --stat 12dd17c..HEAD -- third_party/` → empty — no third_party changes.
- Commit file lists are path-scoped to the files each claims (see "Commit scope").
- `flutter analyze` in the clean worktree: **No issues found! (ran in 1.7s)**.
- `TZ=America/New_York flutter test`: **+239: All tests passed!**
- `TZ=UTC flutter test` (CI's second pass, DST files excluded): **+179: All tests passed!**
- `TZ=UTC flutter test test/nutrition_dst_test.dart`: **fails loudly** in `setUpAll`
  ("ambient zone has no 2026-03-08 DST transition") — the DST guard is non-vacuous.

## Findings

### BLOCKER-1 — Edit mode rewrites stored calories and macros on a no-op save (data loss)

`lib/ui/macros.dart:688-693` pre-fills the macro controllers with
`widget.draft.protein.round().toString()` etc., so opening an existing meal silently
rounds every macro to a whole gram (32.4 → 32). `lib/ui/macros.dart:709-736`
(`_ReviewScreenState._save`) then always writes
`calories: caloriesFromMacros(_protein, _carbs, _fat)` and the rounded values, even when
the user changed nothing.

The stored-vs-computed line (`lib/ui/meal_entry.dart:70-77`) only *discloses* the
difference in `bodySmall`/`tertiary` text; it does not gate the save. Worse, the line is
only rendered when `reference.round() != computed.round()` (`lib/ui/meal_entry.dart:44`),
so a sub-0.5 kcal difference is rewritten with no disclosure at all, and the macro
rounding is never disclosed. Worst case is a coach-logged meal
(`lib/coach/tools.dart:315-330`): calories 600, macros 0/0/0. Opening edit shows
"0 kcal calculated" and "stored 600 kcal · 4/4/9 gives 0 kcal"; one tap on "Save changes"
stores 0 kcal. The commit message claims the estimate is "shown before it is replaced
rather than silently rewritten" — shown, yes; prevented, no.

Proven with a reviewer probe (`test/review_noop_edit_test.dart`, run in the worktree):
a coach meal with 600 kcal and 0/0/0 macros, opened in `ReviewScreen.edit` and saved
without touching a field, ends with `store.meals.single.calories == 0`. The probe passed,
i.e. the rewrite happened.

Fix direction: only recompute when a macro field actually changed, or require an explicit
confirm when `referenceCalories.round() != computed.round()`. Do not round the pre-filled
controllers (use the stored double, e.g. `trimZero`).

### MAJOR-1 — `tool/prove_nutrition_guards.sh` case 8 is vacuous at HEAD

`tool/prove_nutrition_guards.sh:130-133` reverts `lib/ui/macros.dart` and
`lib/data/store.dart` with `git show HEAD:$f`. The script was committed *in* `c4b4912`,
so at HEAD those files are already the post-feature versions: the "reverted to HEAD
(pre-feature)" case patches nothing. Measured: the case prints
`00:00 +3: All tests passed!` — it proves nothing. It was meaningful only when run
against the dirty tree before the commit. Fix: pin the pre-feature commits
(`git show 81af0e2:lib/ui/macros.dart`, `git show 12dd17c:lib/data/store.dart`).

### MINOR-1 — Macros tab does not roll over at midnight

`lib/ui/macros.dart:33` caches `_day = localMidnight(DateTime.now())` in State and never
refreshes it (no `initState`, no `Timer`, no `didChangeDependencies`). `_today` is
recomputed per build, so after midnight the tab shows *yesterday* as the selected day
(`_isToday` false, next-day enabled) until the user taps forward. The pre-feature tab
recomputed `now` every build.

### MINOR-2 — `MealDetailScreen` still renders the 240px placeholder for photo-less meals

`lib/ui/macros.dart:1020-1024` always builds `MealPhoto(meal.imagePath, height: 240)`.
`ReviewScreen` hides the block when `imagePath` is empty (`lib/ui/macros.dart:748`), but
the detail screen does not, so every manual/coach meal opens with a large empty grey
block. Inconsistent with the stated rationale ("the 240px placeholder would just be a
large empty block").

### MINOR-3 — Chart bars have no per-bar semantics

`lib/ui/macros.dart:302-375`: the chart is wrapped in one `Semantics` label
("Weekly Calories chart, 7 days, goal 2000 kcal per day") and `ExcludeSemantics`, so the
bars themselves are not exposed. Per-day values are available only via the chips
(`_dayChip`, lines 392-429), which are correctly labelled. Over/under is not colour-only
(chips carry ▲/▼/= and signed numbers), so this is acceptable, but the task's "semantic
labels on the chart bars" is only met indirectly.

### MINOR-4 — NaN goals can break the new chart

`lib/ui/settings.dart:210-214` uses `double.tryParse(...) ?? default`; `tryParse('NaN')`
returns NaN, not null, so a pasted "NaN" persists as the goal. `_goalRow`
(`lib/ui/macros.dart:229`) then computes `(value / NaN).clamp(0,1)` → NaN →
`LinearProgressIndicator` assertion, and `_weeklyCard` (`lib/ui/macros.dart:264-265`)
`math.max(NaN, …)` → `maxY` NaN. Pre-existing root cause, newly amplified by the chart.
Fix: validate in Settings (`isFinite && > 0`) or clamp in `NutritionGoals`.

### MINOR-5 — `_detail` caching is not covered by a test

`lib/ui/summary.dart:21-32` caches the detail future so a rebuild never re-queries. The
"expansion survives a rebuild" test (`test/summary_expand_test.dart:172-201`) calls
`store.notifyListeners()` and `pumpAndSettle()`, which would also pass if the future were
recreated per build (it settles back to data). The "never drops to loading" claim is
therefore unproven. Add an assertion that no `CircularProgressIndicator` appears after a
notification, or that `workoutDetail` is called once.

### MINOR-6 — Domain layer now imports data models

`lib/domain/domain.dart:5` adds `import '../data/models.dart';` so the pure domain layer
depends on persistence models (`Meal`). No cycle (`models.dart` imports nothing), but it
inverts the layering the codebase otherwise keeps (`store.dart` → domain). Consider a
`MealNutrition` record or moving the aggregate into a service.

### NIT-1 — Sync file I/O in build for every gallery tile

`lib/ui/macros.dart:857` `File(path).existsSync()` runs in `build` for every tile in the
gallery grid. Pre-existing, but the new manual meals add photo-less tiles that all take
this path. Cheap stat calls; note only.

### NIT-2 — `_setRow` trailing Row can squeeze the title

`lib/ui/summary.dart:162-184`: the `ListTile.trailing` is a `Row` with an unbounded
volume `Text` plus a 48px `IconButton`. Large volumes on narrow screens can squeeze the
title/subtitle. Consider `ConstrainedBox`/`Flexible` on the text.

### NIT-3 — `_save` in `ManualMealScreen` allows an all-zero meal

`lib/ui/meal_entry.dart:139-155` saves even when dish and all macros are empty (dish
becomes "Meal", calories 0). Harmless, but a 0 kcal "Meal" row is easy to create by
accident. Consider disabling Save until at least one macro is non-zero.

## Answers to the specific questions

1. **Calorie derivation.** The 4/4/9 math is correct (`lib/domain/domain.dart:113-140`;
   `caloriesFromMacros(40,50,20) == 540`). On a NEW meal the stored calories cannot
   disagree with the macros: both `ManualMealScreen._save` (`lib/ui/meal_entry.dart:147`)
   and `ReviewScreen._save` (`lib/ui/macros.dart:723`) derive calories from the same
   fields they store. Edit mode's stored-vs-computed display does **not** prevent a
   rewrite — it discloses one; see BLOCKER-1.
2. **Manual logging with AI unconfigured.** The manual branch returns before the
   `!ai.configured` early return (`lib/ui/macros.dart:461-474`), and `ManualMealScreen`
   imports no LLM code; `store.addMeal` is DB-only. Proven by
   `test/manual_meal_test.dart:42-64` (AI unconfigured, manual screen opens). Empty
   `imagePath` path: `MealPhoto` placeholder (`lib/ui/macros.dart:857`,
   `test/meal_photo_test.dart`), gallery tile placeholder, `MealDetailScreen` placeholder
   (but see MINOR-2), backup export/import round-trips `image_path ''` as a TEXT column
   (`lib/services/backup.dart:41,117`; `test/backup_roundtrip_test.dart:84-95,182`).
3. **Day/week windows.** Half-open local-day windows (`mealsOnDay`,
   `lib/domain/domain.dart:381-386`), no `Duration(days: 1)` stepping in the new code
   (grep: only comments mention it). `weeklyNutrition` yields exactly 7 calendar days
   (`lib/domain/domain.dart:470-480`). A future-dated meal cannot leak into today
   (`test/nutrition_aggregate_test.dart:52-65`). The DST test fails loudly under TZ=UTC
   (measured above), so it is non-vacuous.
4. **Goals.** The tracker reads `store.goals` (`lib/ui/macros.dart:91`), the same getter
   Settings writes through `store.saveGoals` (`lib/ui/settings.dart:210-214`,
   `lib/data/store.dart:387-400`), which calls `notifyListeners`; the tab uses
   `context.watch`, so a goal change propagates without a restart. Proven with a
   reviewer probe (`test/review_goal_prop_test.dart`): after `saveGoals(calories: 3000)`
   the tracker shows "0 / 3000 kcal" and the chart label "goal 3000 kcal per day".
5. **Expand/collapse.** Expansion state is a `Set<int>` in State keyed by
   `workoutExerciseId` (`lib/ui/summary.dart:26,147`), stable across rebuilds and
   per-exercise (`test/summary_expand_test.dart:172-201`). The detail future is cached
   (`lib/ui/summary.dart:21-32`), so a FutureBuilder re-emit does not drop data (but see
   MINOR-5). Zero-rep placeholder sets are listed, labelled "Not completed", dimmed, and
   excluded from volume (`lib/domain/domain.dart:99-101`); no crash
   (`test/summary_expand_test.dart:155-159`).
6. **Accessibility.** Expand control has `Semantics(button, toggled, label)` and an
   `onTap` (`lib/ui/summary.dart:167-183`); set rows have labels
   (`lib/ui/summary.dart:213-216`). Over/under is not colour-only: chips carry ▲/▼/= and
   signed numbers plus semantic labels (`lib/ui/macros.dart:392-429`). Chart bars
   themselves are excluded (MINOR-3).
7. **Regression risk.** `store.todayTotals()` was removed (`lib/data/store.dart`), no
   callers remain (analyze clean). The Macros tab still shows totals, the meal list,
   gallery, edit and delete flows; the summary's aggregate row, totals and delete flow
   are unchanged (`test/summary_expand_test.dart:131-137`). Coach-logged meals
   (`imagePath ''`, `isAuto true`) render via `MealPhoto`'s placeholder and edit without
   duplicating (`test/manual_meal_test.dart:149-196`).

## Guard non-vacuity (measured)

Feature 2: `tool/prove_nutrition_guards.sh` cases 1-7 all fail as expected (quoted
failures in the run log: e.g. case 1 "Expected: <200>", case 2 "Expected: <23>",
case 5 "Expected: <2>", cases 6-7 "Actual: <Closure: () => void>"). Case 8 is vacuous —
see MAJOR-1 (`git diff HEAD --stat -- lib/ui/macros.dart lib/data/store.dart` is empty).

Feature 1 and 3: 11 targeted reverts, each failed the guard as expected:

| Revert | Guard failure quoted |
|---|---|
| fat factor 9→4 | `Expected: <540>` (40P/50C/20F), `Expected: <9>` (4/4/9) |
| negative/non-finite clamp removed | `Expected: <380>` (negative and non-finite tests) |
| `parseMacroGrams` → `double.parse` | `Expected: <0>` (abc/NaN/Infinity tests) |
| manual save stores `P+C+F` | `Actual: <130.0>` (expected 620) |
| manual save `imagePath: 'photo.jpg'` | `Actual: 'photo.jpg'` (expected '') |
| edit-mode reference line removed | `Found 0 widgets with text "stored 620 kcal · 4/4/9 gives 598 kcal"` |
| photo block always shown | `Found 1 widget with type "MealPhoto"` (expected none) |
| sets expanded by default | `Found 1 widget with text "100 kg × 5 reps"` (expected none) |
| placeholder shown as completed | `Found 3 widgets with text "Completed"` (expected 2) |
| incomplete sets filtered out | `Found 0 widgets with text "Not completed"` |
| expand label removed | `Found 0 widgets with semantics label "Expand sets…"` |

## Verification commands (reviewer-run, clean worktree)

```
flutter analyze                         -> No issues found! (ran in 1.7s)
TZ=America/New_York flutter test        -> 00:11 +239: All tests passed!
TZ=UTC flutter test <non-DST files>     -> 00:07 +179: All tests passed!
TZ=UTC flutter test test/nutrition_dst_test.dart
                                        -> 00:00 +0 -1: Some tests failed.
                                           (setUpAll: "ambient zone has no 2026-03-08
                                           DST transition; run with TZ=America/New_York")
bash tool/prove_nutrition_guards.sh     -> cases 1-7 fail as expected; case 8 passes
                                           vacuously (MAJOR-1)
```

Reviewer probes (temporary, not committed): `test/review_noop_edit_test.dart` (BLOCKER-1,
passed = rewrite happened) and `test/review_goal_prop_test.dart` (question 4, passed).

## Commit scope

- `81af0e2`: `lib/domain/domain.dart`, `lib/ui/macros.dart`, `lib/ui/meal_entry.dart`,
  `test/macro_calories_test.dart`, `test/manual_meal_test.dart` — matches its claim.
- `c4b4912`: `.github/workflows/ci.yml`, `lib/data/store.dart`, `lib/domain/domain.dart`,
  `lib/ui/macros.dart`, `lib/ui/meal_entry.dart`, 3 tests, `tool/prove_nutrition_guards.sh`
  — the CI edit is in scope (it excludes the new DST test from the UTC pass).
- `f778962`: `lib/ui/summary.dart`, `test/summary_expand_test.dart` — matches.
- Note: `b77c6b6` (coach arg parsing / zero-rep clamp) is also on main since `12dd17c`
  but is outside this gate's three-feature scope; it was reviewed separately.

## Residual risk / not verified

- No device run (Pixel 10) — this gate is static + test only; the queued device-verify
  task covers rendering, keyboard behaviour and the date picker on hardware.
- The midnight rollover (MINOR-1) is code-read, not test-proven (no injectable clock).
- The backup round-trip of a photo-less meal is structurally guaranteed (TEXT column,
  `''` default) and covered by the existing round-trip test, but that test does not
  assert `image_path == ''` explicitly.
