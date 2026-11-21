#!/usr/bin/env bash
# Plain-sh tests for collect-crash-evidence.sh. Run directly:
#   ./test_collect-crash-evidence.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script=../collect-crash-evidence.sh
pass=0
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc"
    fail=$((fail + 1))
  fi
}

# A host that crashed: an .ips report, an XDG-style sentry db, a Caches one.
home="$work/home"
mkdir -p "$home/Library/Logs/DiagnosticReports" \
  "$home/.cache/ghostty/sentry/a.run" \
  "$home/Library/Caches/com.mitchellh.ghostty.debug/sentry/b.run"
echo ips >"$home/Library/Logs/DiagnosticReports/Leo-1.ips"
echo dump >"$home/.cache/ghostty/sentry/a.run/e1.envelope"
echo dump >"$home/Library/Caches/com.mitchellh.ghostty.debug/sentry/b.run/e2.envelope"

HOME="$home" env -u XDG_CACHE_HOME bash "$script" "$work/out"
check "copies diagnostic reports" test -f "$work/out/DiagnosticReports/Leo-1.ips"
check "copies the ~/.cache sentry database" \
  test -n "$(find "$work/out/sentry" -name e1.envelope)"
check "copies the ~/Library/Caches sentry database" \
  test -n "$(find "$work/out/sentry" -name e2.envelope)"

# A clean host: nothing to copy is still success, with an existing out dir.
HOME="$work/empty" env -u XDG_CACHE_HOME bash "$script" "$work/out2"
check "empty host succeeds and creates the out dir" test -d "$work/out2"

# Unwritable destination must not fail the job.
check "never fails the caller" env HOME="$home" bash "$script" /dev/null/nope 2>/dev/null

echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
