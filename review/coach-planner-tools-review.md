# Gate review — coach planner tools (dc8594c)

- **Task**: Gate: coach planner tools (dc8594c)
- **HEAD reviewed**: `dc8594c` ("feat(coach): planner tools — read, add, move, check off and delete plan blocks")
- **Worktree**: `/tmp/wt-dc8594c` (pinned detached at `dc8594c`; not the shared checkout)
- **Date**: 2026-11-09
- **Verdict**: **APPROVE WITH FIXES** — no Blocker, no Major. One Minor robustness defect (non-finite numeric time crashes the approval card), one Minor test gap (no cross-day isolation assertion in the new coach tests), plus Nits. The tool schemas match the system prompt, every bad-input path returns JSON, and the store boundary holds.

## Scope reviewed

`lib/coach/tools.dart` (+285), `lib/coach/agent.dart` (+7/-1), `lib/data/store.dart` (`planBlockById`, +11), `lib/ui/coach.dart` (+4), `test/planner_coach_test.dart` (+359).

## Verification (commands + results)

1. **Analyze** — `flutter analyze` in the pinned worktree → `No issues found! (ran in 1.9s)`.
2. **New tests** — `TMPDIR=/home/barry/.cache/flutter-tmp flutter test test/planner_coach_test.dart` → `00:00 +17: All tests passed!` (17 tests, as claimed).
3. **Full suite** — `TMPDIR=/home/barry/.cache/flutter-tmp flutter test` → `00:16 +524: All tests passed!`.
4. **Schema/prompt drift** — read both sides: `agent.dart:98-101` documents `get_plan(date)`, `create_plan_block(date, title, start, end)`, `update_plan_block(id, title, start, end, done)`, `delete_plan_block(id)`; the four `ToolSpec`s in `tools.dart:1186-1398` declare exactly those names/args, with `title/start/end` required for create and `id` required for update/delete. `agent.dart:117-119` lists the three write tools in the approval RULES. No drift.
5. **Approval wiring** — `lib/ui/coach.dart:108-111` adds the four tools to the existing list; `GetPlanTool.isWrite` is false (runs inline), the other three are true (pause for approval). The 4-line diff touches nothing else, so the approval card and scroll behaviour are unchanged.
6. **Cross-day isolation (manual probe)** — created block A on 2026-11-09 and B on 2026-11-10: `get_plan 2026-11-09` → `[A]` only; updating A left B `title=B day=2026-11-10`; deleting A left B intact. `planBlockById` is id-only by design (global PK), and update/delete cannot touch another day's row.
7. **Guard proofs** — five mutations, each reverted and the failure quoted (below).

## Non-vacuous guard proofs (revert → quoted failure)

- **Store create validation** (`lib/data/store.dart:1430-1432`, drop the `planBlockError` throw): `create_plan_block rejects bad input with a JSON error and writes nothing` → `Expected: not null / Actual: <null>` (the blank title was written and the tool returned `ok`).
- **Store update validation** (`lib/data/store.dart:1468-1470`, drop the throw): full suite → `test/plan_test.dart: store CRUD invalid blocks are rejected with a StoreException` → `Expected: throws <Instance of 'StoreException'> / Actual: <Instance of 'Future<void>'>`.
- **Day scoping** (`lib/data/store.dart:1402-1406`, drop `where: 'day = ?'`): full suite → `test/plan_test.dart: store CRUD blocks are scoped to their day and ordered chronologically` → `Expected: ['Early', 'Late'] / Actual: ['Other day', 'Early', 'Late']`.
- **Tool title guard** (`tools.dart:1260`, drop `if (title.isEmpty)`): planner_coach_test still passes — the store boundary catches it. Redundant defense-in-depth, not a defect.
- **Tool merged-row guard** (`tools.dart:1362-1366`, drop the pre-write `planBlockError`): planner_coach_test still passes — `store.updatePlanBlock` re-validates and throws, caught as a JSON error. Redundant, not a defect.

## Findings (severity order)

### Minor 1 — non-finite numeric time throws instead of returning a JSON error

`lib/coach/tools.dart:1143-1148`:

```dart
if (raw is num) {
  final minutes = raw.toInt();
  if (minutes != raw) return null;
  ...
}
```

`double.infinity.toInt()` and `double.nan.toInt()` throw `UnsupportedError`, not return null. Dart's `jsonDecode('{"start": 1e999}')` yields `Infinity` (verified: `decoded type=double value=Infinity`), so a model that sends `"start": 1e999` hits this path. Measured:

```
summarize THREW: Unsupported operation: Infinity or NaN toInt
run THREW: Unsupported operation: Infinity or NaN toInt
```

`run` is wrapped by `CoachAgent._runTool` (`agent.dart:341-347`), so the model sees a JSON error — but `summarize` is called unguarded at `agent.dart:318`, so the **approval card throws** and the write never reaches the user. This is the same class of bug the codebase already fixed for `AddSetTool` (NIT-2 on b2b3b4m1). Fix: `if (!raw.isFinite) return null;` before `toInt()`, and add a test (`{'start': 1e999}` → JSON error, `summarize` does not throw).

### Minor 2 — no cross-day isolation test in the new coach suite

`test/planner_coach_test.dart` never creates blocks on two days, so the `get_plan` day filter is only proven by the pre-existing `test/plan_test.dart:290-294` store test (mutation C above). If someone later changes `GetPlanTool` to query all blocks (or `planBlocksForDay` loses its filter), the coach suite stays green. Add one test: blocks on day A and day B, `get_plan(A)` returns only A, and updating/deleting an A block leaves B untouched.

### Nit 1 — duplicate `id` key in the create response

`tools.dart:1275-1280` emits `'id': id` and then spreads `_planBlockJson(created)`, which also contains `'id'`. Same value, so harmless, but the spread alone is enough.

### Nit 2 — update/delete approval summaries omit the block title

`tools.dart:1325` and `1406` show only `#id`, while the habit tools resolve and show the name (`_habitById`). The approval card for "delete plan block #7" gives the user no title to confirm against. Resolving the title would need an async lookup, so showing the id is defensible — but the update summary could at least include the new title when one is passed (it does) and the delete summary could include the title from the pre-fetch (it does in the result, not the summary).

### Nit 3 — string ids report "id is required"

`_int` returns null for a JSON string, so `{'id': "7"}` → `id is required` rather than `id must be an integer`. Consistent with the habit tools; message quality only.

### Nit 4 — two writes without a transaction

`tools.dart:1368-1372` calls `updatePlanBlock` then `setPlanBlockDone` separately. If the second write fails at the DB level the move is already applied. `setPlanBlockDone` cannot throw `StoreException`, so the practical risk is a disk error only; acceptable for a single-user app.

## What is clean

- Every bad-input path in the four tools returns `_jsonError` (blank title, bad date, bad HH:MM, inverted/zero-length block, unknown id, non-bool `done`, missing field) — verified by the 17 tests and by direct probes.
- `_parsePlanTime` rejects out-of-day values (`25:00`, `24:30`) and accepts `24:00` as an end, matching `planBlockError` and `formatPlanTime`.
- `planBlockError` is the single validation boundary; the store re-runs it on both create and update, so the tool cannot persist a block the planner UI would reject.
- `get_plan` reports `current`/`next` only for today (`isToday` guard), so a past/future day never claims a "now" block.
- No secrets, no new dependencies, no dead code, no analyzer warnings.
