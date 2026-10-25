#!/usr/bin/env bash
# Post-run checks on the unit-test log: usage check-test-log.sh LOG RC
# (RC is the test host's exit status). Prints the run summary, a ::warning::
# for every focus-gate skip (a runner that never gets key status must not
# quietly drop those guards), and exits 1 on a timeout, a missing summary, a
# non-zero status, or any failed test.
set -euo pipefail

log="${1:?usage: check-test-log.sh LOG RC}"
rc="${2:?usage: check-test-log.sh LOG RC}"
readonly TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-900}"
# Printed by LeoFocusProbe.runLoggingSkip (macos/Tests/Leo/LeoTestHostActivation.swift).
readonly FOCUS_SKIP_MARKER='focus-gate-skip:'

summary="$(grep -E 'Test run with [0-9]+ tests' "$log" | tail -1 || true)"
echo "${summary:-no test summary found}"

skips="$(grep -cF "$FOCUS_SKIP_MARKER" "$log" || true)"
if [[ "${skips:-0}" -gt 0 ]]; then
  reason="$(grep -F "$FOCUS_SKIP_MARKER" "$log" | head -1 | sed "s/^.*$FOCUS_SKIP_MARKER //")"
  echo "::warning::$skips focus-gate check(s) skipped: $reason"
fi

if [[ $rc -eq 124 ]]; then
  echo "::error::Test run timed out after ${TEST_TIMEOUT_SECONDS}s"
  grep -E '◇ Test .* started' "$log" | tail -5 || true
  exit 1
fi
if [[ -z "$summary" ]]; then
  tail -40 "$log"
  echo "::error::Test runner exited ($rc) without a summary"
  exit 1
fi
if [[ $rc -ne 0 ]]; then
  grep -E '^✘' "$log" | head -60 || true
  echo "::error::Test runner exited with status $rc"
  exit 1
fi

failed="$(grep -E '^✘ Test ' "$log" || true)"
if [[ -n "$failed" ]]; then
  echo "$failed" | head -60
  echo "::error::Test failures reported despite a zero exit status"
  exit 1
fi
echo "All tests passed"
