#!/usr/bin/env bash
# Proves every guard in test/dst_day_windows_test.dart is non-vacuous: reverts
# one production site at a time to the pre-fix Duration form, runs the test
# file, and records the failure. Restores the file afterwards.
set -u
cd "$(dirname "$0")/.." || exit 1

run_case() {
  local name="$1" file="$2" from="$3" to="$4"
  cp "$file" "/tmp/guard_$(basename "$file").bak"
  python3 - "$file" "$from" "$to" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
assert src.count(old) == 1, f'{path}: expected 1 match, got {src.count(old)}'
open(path, 'w').write(src.replace(old, new))
PY
  echo "=================== CASE: $name"
  echo "--- patched $file"
  TZ=America/New_York flutter test test/dst_day_windows_test.dart 2>&1 \
    | grep -E "^(  Expected|  Actual|  [a-z].*must|Failing tests:|  /home.*dst_day_windows)" \
    | head -40
  TZ=America/New_York flutter test test/dst_day_windows_test.dart 2>&1 | tail -2
  cp "/tmp/guard_$(basename "$file").bak" "$file"
}

run_case "tools.dart dateRange to -> Duration" lib/coach/tools.dart \
  'to: DateTime(hi.year, hi.month, hi.day + 1).millisecondsSinceEpoch,' \
  'to: DateTime(hi.year, hi.month, hi.day).add(const Duration(days: 1)).millisecondsSinceEpoch,'

run_case "health_tools.dart healthRange from -> Duration" lib/coach/health_tools.dart \
  'DateTime(anchor.year, anchor.month, anchor.day - (defaultDays - 1));' \
  'DateTime(anchor.year, anchor.month, anchor.day).subtract(Duration(days: defaultDays - 1));'

run_case "health_tools.dart healthRange to -> Duration" lib/coach/health_tools.dart \
  'to: DateTime(hi.year, hi.month, hi.day + 1).millisecondsSinceEpoch,' \
  'to: DateTime(hi.year, hi.month, hi.day).add(const Duration(days: 1)).millisecondsSinceEpoch,'

run_case "notify.dart digestWindowStart -> Duration" lib/services/notify.dart \
  'DateTime(now.year, now.month, now.day - 6);' \
  'DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));'

run_case "health/service.dart todaySummaryWindow -> Duration" lib/health/service.dart \
  'from: DateTime(now.year, now.month, now.day - 2),
      to: DateTime(now.year, now.month, now.day + 1),' \
  'from: DateTime(now.year, now.month, now.day).subtract(const Duration(days: 2)),
      to: DateTime(now.year, now.month, now.day).add(const Duration(days: 1)),'

run_case "notify.dart nextDigestAt roll -> Duration" lib/services/notify.dart \
  'return DateTime(now.year, now.month, now.day + 1, hour, minute);' \
  'return DateTime(now.year, now.month, now.day, hour, minute).add(const Duration(days: 1));'

run_case "health/service.dart retentionCutoff -> Duration" lib/health/service.dart \
  'DateTime retentionCutoff(DateTime now, int retentionDays) => DateTime(
    now.year,
    now.month,
    now.day - retentionDays,
    now.hour,
    now.minute,
    now.second,
    now.millisecond,
    now.microsecond);' \
  'DateTime retentionCutoff(DateTime now, int retentionDays) =>
    now.subtract(Duration(days: retentionDays));'

run_case "notify.dart calendarDaysSince -> elapsed inDays" lib/services/notify.dart \
  'DateTime.utc(now.year, now.month, now.day)
        .difference(DateTime.utc(then.year, then.month, then.day))
        .inDays;' \
  'now.difference(then).inDays;'

echo "=================== restored tree"
git diff --stat
