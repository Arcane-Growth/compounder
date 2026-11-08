#!/usr/bin/env bash
# Proves every guard in the Feature 2 nutrition tests is non-vacuous: reverts
# one production site at a time to its pre-fix form (or to HEAD for the UI),
# runs the guard, and records the failure. Restores the tree afterwards.
#
# `set -euo pipefail` matters: if a production site is edited so a hard-coded
# `from` string no longer matches, the Python assert must abort the run instead
# of silently testing the unpatched file. The `|| true` on the test pipelines is
# deliberate: a failing test is the expected outcome here.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# /tmp is a small tmpfs on this box; flutter test needs room for its dill files.
export TMPDIR="${TMPDIR:-/home/barry/.cache/flutter-tmp}"
mkdir -p "$TMPDIR"

_bakdir=""

restore_all() {
  if [ -n "$_bakdir" ] && [ -d "$_bakdir" ]; then
    local n=0 f
    while IFS= read -r f; do
      cp "$_bakdir/$n" "$f"
      n=$((n + 1))
    done <"$_bakdir/manifest"
    rm -rf "$_bakdir"
    _bakdir=""
  fi
}
trap restore_all EXIT

begin_case() {
  _bakdir=$(mktemp -d /tmp/nutrition_guard.XXXXXX)
  : >"$_bakdir/manifest"
}

backup_file() {
  local f="$1" n
  n=$(wc -l <"$_bakdir/manifest")
  cp "$f" "$_bakdir/$n"
  echo "$f" >>"$_bakdir/manifest"
}

report() {
  local testfile="$1"
  TZ=America/New_York flutter test "$testfile" >/tmp/nutrition_guard_out.txt 2>&1 || true
  grep -E "^(  Expected|  Actual|  Which|Failing tests:|  /home.*nutrition)" \
    /tmp/nutrition_guard_out.txt | head -14 || true
  tail -2 /tmp/nutrition_guard_out.txt
}

run_case() {
  local name="$1" file="$2" testfile="$3" from="$4" to="$5"
  begin_case
  backup_file "$file"
  python3 - "$file" "$from" "$to" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
assert src.count(old) == 1, f'{path}: expected 1 match, got {src.count(old)}'
open(path, 'w').write(src.replace(old, new))
PY
  echo "=================== CASE: $name"
  echo "--- patched $file"
  report "$testfile"
  restore_all
}

run_pinned_case() {
  local name="$1" testfile="$2"
  shift 2
  begin_case
  echo "=================== CASE: $name"
  for spec in "$@"; do
    local ref="${spec%%:*}" f="${spec#*:}"
    backup_file "$f"
    git show "$ref:$f" >"$f"
    echo "--- reverted $f to $ref"
  done
  report "$testfile"
  restore_all
}

# Reverts lib/ui/macros.dart to the pre-feature commit and re-adds the
# today-only store.todayTotals() the old tab calls. store.dart is patched
# rather than reverted wholesale because the habit tracker (schema v10) added
# getters that lib/ui/habits.dart needs; reverting it to 12dd17c does not
# compile.
run_pre_feature_case() {
  local name="$1" testfile="$2" ref="$3" file="$4" storefile="$5"
  begin_case
  echo "=================== CASE: $name"
  backup_file "$file"
  git show "$ref:$file" >"$file"
  echo "--- reverted $file to $ref"
  backup_file "$storefile"
  python3 - "$storefile" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
anchor = '  // ------------------------------------------------------------ reminders'
assert src.count(anchor) == 1, f'{path}: expected 1 anchor, got {src.count(anchor)}'
method = '''  ({double calories, double protein, double carbs, double fat}) todayTotals() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final todays = meals.where((m) => m.timestamp >= start);
    return (
      calories: todays.fold(0.0, (a, m) => a + m.calories),
      protein: todays.fold(0.0, (a, m) => a + m.protein),
      carbs: todays.fold(0.0, (a, m) => a + m.carbs),
      fat: todays.fold(0.0, (a, m) => a + m.fat),
    );
  }

'''
open(path, 'w').write(src.replace(anchor, method + anchor))
PY
  echo "--- re-added store.todayTotals()"
  report "$testfile"
  restore_all
}

# 1. The day window's exclusive upper bound is what keeps the next day's 00:00
#    and future-dated rows out. This is the old todayTotals() shape.
run_case "mealsOnDay upper bound removed (old todayTotals shape)" \
  lib/domain/domain.dart test/nutrition_aggregate_test.dart \
  'return meals.where((m) => m.timestamp >= start && m.timestamp < end).toList();' \
  'return meals.where((m) => m.timestamp >= start).toList();'

# 2. nextDayKey via Duration: the day window's end bound drifts off midnight.
run_case "nextDayKey -> Duration(days: 1)" \
  lib/domain/domain.dart test/nutrition_dst_test.dart \
  'DateTime nextDayKey(DateTime day) => DateTime(day.year, day.month, day.day + 1);' \
  'DateTime nextDayKey(DateTime day) =>
    DateTime(day.year, day.month, day.day).add(const Duration(days: 1));'

# 3. Week anchoring: a Sunday-start week instead of Mon-Sun.
#    (A Duration subtraction in weekStartFor happens to be safe in this zone
#    because US transitions fire at 02:00 Sunday, after that day's midnight;
#    the Monday anchor is the part a regression can actually break.)
run_case "weekStartFor anchored on Sunday instead of Monday" \
  lib/domain/domain.dart test/nutrition_aggregate_test.dart \
  'DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));' \
  'DateTime(day.year, day.month, day.day - (day.weekday % 7));'

# 4. weeklyNutrition not snapping the anchor to its Monday.
run_case "weeklyNutrition does not snap the anchor to Monday" \
  lib/domain/domain.dart test/nutrition_dst_test.dart \
  'final monday = weekStartFor(weekStart);' \
  'final monday = localMidnight(weekStart);'

# 5. Over/under classification: counting an exactly-on-goal day as over.
run_case "summarizeWeek counts on-target as over" \
  lib/domain/domain.dart test/nutrition_aggregate_test.dart \
  'if (delta > 0) {' \
  'if (delta >= 0) {'

# 6. Next-day control enabled on today (the user can wander into empty days).
run_case "next-day control enabled at today" \
  lib/ui/macros.dart test/nutrition_ui_test.dart \
  'onPressed: _isToday ? null : () => _stepDay(1),' \
  'onPressed: () => _stepDay(1),'

# 7. Next-week control enabled on the current week.
run_case "next-week control enabled on the current week" \
  lib/ui/macros.dart test/nutrition_ui_test.dart \
  'onPressed: isCurrentWeek ? null : () => _stepWeek(1),' \
  'onPressed: () => _stepWeek(1),'

# 8. The whole feature reverted to its pre-feature commit: no date controls and
#    no weekly tracker, with the old today-only totals (store.todayTotals) back
#    in place. Pinned to 81af0e2, not HEAD: the script itself was committed in
#    c4b4912, so `git show HEAD:` would patch nothing and the case would pass
#    vacuously (review MAJOR-1).
run_pre_feature_case "Macros tab reverted to 81af0e2 (pre-feature)" \
  test/nutrition_ui_test.dart 81af0e2 lib/ui/macros.dart lib/data/store.dart

echo "=================== restored tree"
git diff --stat
