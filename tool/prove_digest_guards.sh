#!/usr/bin/env bash
# Proves the digest end-to-end guards are non-vacuous: reverts notify.dart to
# the pre-fix Duration/inDays implementation, runs the digest test, records the
# failure, then restores.
#
# `set -euo pipefail` matters here: a stale hard-coded pattern must abort the
# run instead of silently testing the unpatched file (audit m3-dst NIT-2). The
# `|| true` on the test pipelines is deliberate — a failing test is the
# expected outcome — and the EXIT trap restores notify.dart even on abort.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

cp lib/services/notify.dart /tmp/notify_pre_fix.bak
trap 'cp /tmp/notify_pre_fix.bak lib/services/notify.dart' EXIT

python3 - <<'PY'
p = 'lib/services/notify.dart'
s = open(p).read()
old_start = '''DateTime digestWindowStart(DateTime now) =>
    DateTime(now.year, now.month, now.day - 6);'''
new_start = '''DateTime digestWindowStart(DateTime now) =>
    DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));'''
assert s.count(old_start) == 1
s = s.replace(old_start, new_start)

old_days = '''DateTime.utc(now.year, now.month, now.day)
        .difference(DateTime.utc(then.year, then.month, then.day))
        .inDays;'''
new_days = '''now.difference(then).inDays;'''
assert s.count(old_days) == 1
s = s.replace(old_days, new_days)
open(p, 'w').write(s)
PY

echo "=================== CASE: notify.dart digest pre-fix (Duration window + inDays)"
TZ=America/New_York flutter test test/digest_dst_test.dart 2>&1 \
  | grep -E "^(  Expected|  Actual|  Which|  [a-z].*(must|window)|Failing tests:)" | head -40 || true
TZ=America/New_York flutter test test/digest_dst_test.dart 2>&1 | tail -2 || true

cp /tmp/notify_pre_fix.bak lib/services/notify.dart
trap - EXIT
echo "=================== restored"
git diff --stat lib/services/notify.dart
