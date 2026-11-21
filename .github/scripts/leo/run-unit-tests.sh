#!/usr/bin/env bash
# Build and run the GhosttyTests unit bundle (no UI tests).
#
# `xcodebuild test` hangs when the runner Mac's console is locked (Xcode
# treats the Mac as a passcode-protected device), so the bundle is injected
# into the host app directly instead. That injection makes the process see
# `-XCTest All <bundle>` on its own argv; Ghostty.Config.loadConfig skips CLI
# arg parsing whenever isRunningXCTest() is true specifically so that argv
# never reaches config parsing, so no test failures need to be tolerated here.
# Env: LEO_TEST_FILTER (optional, comma-separated Suite or Suite/test(); runs
# only those through `xcodebuild test-without-building -only-testing`, not the
# injected host), DERIVED_DATA, DEVELOPER_DIR, optional LEO_HOST_TESTS=1 (host tier). Optional LEO_TEST_INJECT_LIB (the dylib injected into the host; empty = none; script tests only). Optional LOG (default $RUNNER_TEMP/leo-tests.log).
#
# Retry policy (full, unfiltered runs only; one round, never more):
#   - tests failed (a summary, at most MAX_RETRIED_FAILURES of them): resolve
#     each to its real identifier (xcodebuild -enumerate-tests, so nested and
#     extension suites and parameterized tests resolve exactly) and rerun
#     exactly those through the filtered path. The retry passes only if every
#     one of them ran and passed (an identifier that matches nothing, or a
#     skipped suite, fails it), and the focus-gate and skip checks hold on its
#     log too. Then the step passes with a ::warning:: per flaky test and a
#     "Flaky tests" step-summary list.
#   - the host crashed or exited without a summary: rerun the whole suite.
#     Clean: the step passes with a ::warning::. The first attempt's crash
#     evidence is collected before the rerun.
#   - a timeout or a stall kill (even after a summary), more than
#     MAX_RETRIED_FAILURES failures (real breakage, not flake), or a failure
#     that can't be placed in any failing suite: no retry. A name two failing
#     suites share retries both (a superset; each must run and pass).
# The first attempt's log stays at $log; the rerun's goes to ${log%.log}-retry.log.
set -euo pipefail

: "${DERIVED_DATA:?}" "${DEVELOPER_DIR:?}"
# Overall cap; a real hang is caught sooner by watch-stall.sh (no log growth for 240 s).
readonly TEST_TIMEOUT_SECONDS=1200
export TEST_TIMEOUT_SECONDS
# More failures than this is breakage, not flake: no retry.
readonly MAX_RETRIED_FAILURES=10
log="${LOG:-${RUNNER_TEMP:-/tmp}/leo-tests.log}"
# Resolved before the cd below; BASH_SOURCE is relative when CI runs the script by path.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(git rev-parse --show-toplevel)/macos"

echo "::group::build-for-testing"
xcodebuild build-for-testing \
  -project Ghostty.xcodeproj \
  -scheme Ghostty \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -packageAuthorizationProvider netrc \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO
echo "::endgroup::"
# Tells the workflow the DerivedData cache is worth saving even if tests fail.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "built=true" >> "$GITHUB_OUTPUT"; fi

# Host tier (real key focus, surfaces, WebKit): only an explicit LEO_HOST_TESTS=1
# turns it on. Passed explicitly so the test host sees exactly what is logged.
host_tests="${LEO_HOST_TESTS:-}"
if [[ "$host_tests" == "1" ]]; then echo "host tier: on"; else echo "host tier: off"; fi

D="$DEVELOPER_DIR"
result_bundle="${log%.log}.xcresult"

# Maps a filter token (Suite or Suite/test()) to an -only-testing identifier.
# A suite declared inside a top-level `extension Parent {` (as the Leo suites
# nested under LeoAppEventQueueTests are) is identified as
# GhosttyTests/Parent/Suite; a bare GhosttyTests/Suite matches nothing there.
only_testing_id() {
  local token="$1" suite="${1%%/*}" rest="" parent
  [[ "$token" == */* ]] && rest="/${token#*/}"
  if [[ "$token" == GhosttyTests/* ]]; then echo "$token"; return; fi
  parent="$(find Tests -name '*.swift' -print0 | xargs -0 awk -v n="$suite" '
    FNR == 1 { parent = "" }
    /^extension [A-Za-z0-9_.]+ \{/ { parent = $2 }
    /^\}/ { parent = "" }
    $0 ~ "^[A-Za-z@ ]*(struct|class|enum|actor) " n "([^A-Za-z0-9_]|$)" { print parent; exit }')"
  parent="${parent//.//}"
  echo "GhosttyTests/${parent:+$parent/}$suite$rest"
}

# Prints every failing test's issues (Swift Testing expectation text with
# file:line and values) from the result bundle, plus ::error annotations.
dump_failures() {
  local bundle="${1:-$result_bundle}"
  [[ -d "$bundle" ]] || { echo "no result bundle at $bundle"; return 0; }
  echo "::group::Failures from the result bundle"
  xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>&1 \
    | python3 -I -c '
import json, sys
raw = sys.stdin.read()
try:
    failures = json.loads(raw).get("testFailures", [])
except ValueError:
    print(raw); sys.exit(0)
if not failures:
    print("no failures recorded in the result bundle")
for f in failures:
    text = f.get("failureText", "")
    name = f.get("testName", "?")
    print(f"{name}: {text}")
    print("::error title=" + name.replace(",", " ") + "::" + text.replace("%", "%25").replace("\r", "").replace("\n", "%0A"))
' || true
  echo "::endgroup::"
}
app="$DERIVED_DATA/Build/Products/Debug/Leo.app"

# Runs `cmd` as the test host: output to `out`, its status in `rc`. A hung
# test ends the run only at the timeout and leaves no trace of where, so the
# log is watched instead: once it stops growing for STALL_SECONDS, the host's
# stacks are recorded to `out.hang` and it is killed, so the run fails fast
# with the evidence.
supervise() {
  local out="$1"
  shift
  local hang="$out.hang" host watcher
  rm -f "$hang"
  set +e
  timeout "$TEST_TIMEOUT_SECONDS" "$@" >"$out" 2>&1 &
  host=$!
  "$script_dir/watch-stall.sh" "$out" "$host" "$hang" &
  watcher=$!
  wait "$host"
  rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  set -e
  [[ -s "$hang" ]] && { echo "::group::Stall diagnostics"; head -c 200000 "$hang"; echo "::endgroup::"; }
  return 0
}

# The full suite, injected into the host app: the log is `$1`.
run_full() {
  supervise "$1" env \
    LEO_HOST_TESTS="$host_tests" \
    DYLD_FRAMEWORK_PATH="$D/Platforms/MacOSX.platform/Developer/Library/Frameworks:$D/Library/Frameworks" \
    DYLD_LIBRARY_PATH="$D/Platforms/MacOSX.platform/Developer/usr/lib" \
    DYLD_INSERT_LIBRARIES="${LEO_TEST_INJECT_LIB-$D/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib}" \
    XCInjectBundleInto="$app/Contents/MacOS/Leo" \
    "$app/Contents/MacOS/Leo" -XCTest All "$app/Contents/PlugIns/GhosttyTests.xctest"
}

# Only the tests whose -only-testing identifiers follow `log bundle`.
run_filtered() {
  local out="$1" bundle="$2"
  shift 2
  rm -rf "$bundle"
  # xcodebuild forwards only TEST_RUNNER_-prefixed variables to the test host.
  supervise "$out" env LEO_HOST_TESTS="$host_tests" TEST_RUNNER_LEO_HOST_TESTS="$host_tests" \
    xcodebuild test-without-building \
    -project Ghostty.xcodeproj -scheme Ghostty \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipMacroValidation \
    -resultBundlePath "$bundle" \
    "$@" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO
}

if [[ -n "${LEO_TEST_FILTER:-}" ]]; then
  echo "test filter: $LEO_TEST_FILTER"
  only=()
  IFS=',' read -r -a filters <<<"$LEO_TEST_FILTER"
  for f in "${filters[@]}"; do
    f="${f// /}"
    [[ -n "$f" ]] || continue
    id="$(only_testing_id "$f")"
    echo "  $f -> $id"
    only+=("-only-testing:$id")
  done
  run_filtered "$log" "$result_bundle" "${only[@]}"
  if [[ $rc -ne 0 ]]; then dump_failures; fi
  # The filtered xcodebuild path prints no Swift Testing summary line, so a
  # clean exit is judged from the result bundle's counts instead.
  if [[ $rc -eq 0 ]]; then
    "$script_dir/check-filtered-run.sh" "$result_bundle" "$log"
    echo "All tests passed"
    exit 0
  fi
  exec "$script_dir/check-test-log.sh" "$log" "$rc"
fi

# ---- Full run, with one retry round (see the header) ----
retry_log="${log%.log}-retry.log"
retry_bundle="${log%.log}-retry.xcresult"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Tells the workflow the retry's evidence is worth uploading even though the
# step passed.
mark_retried() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "retried=true" >> "$GITHUB_OUTPUT"; fi
}

# The first attempt's verdict, held back: its ::error:: annotations only
# show if the step ends up failing (as ::warning:: with a prefix otherwise).
first_verdict="$(mktemp)"
trap 'rm -f "$first_verdict"' EXIT
fail_first() { cat "$first_verdict"; exit 1; }
soften_first() { sed 's/^::error::/::warning::first attempt: /' "$first_verdict"; }

run_full "$log"
first_rc=$rc
first_hang=0
[[ -s "$log.hang" ]] && first_hang=1
if "$script_dir/check-test-log.sh" "$log" "$first_rc" >"$first_verdict" 2>&1; then
  cat "$first_verdict"
  exit 0
fi

has_summary=0
grep -qE 'Test run with [0-9]+ tests' "$log" && has_summary=1

# No summary and no timeout or stall: the host crashed or exited early.
if [[ $has_summary -eq 0 && $first_rc -ne 124 && $first_hang -eq 0 ]]; then
  echo "::group::Test host crash: first attempt"
  cat "$first_verdict"
  echo "::endgroup::"
  # Before the rerun, in case it clobbers the evidence the first left.
  "$script_dir/collect-crash-evidence.sh" "${RUNNER_TEMP:-/tmp}/leo-crash-evidence" || true
  mark_retried
  echo "Rerunning the whole suite once (retry log: $retry_log)"
  run_full "$retry_log"
  if "$script_dir/check-test-log.sh" "$retry_log" "$rc"; then
    msg="The test host exited (status $first_rc) without a summary; the full rerun passed"
    echo "::warning title=Test host crash::$msg"
    printf '### Test host crash\n\n%s.\n' "$msg" >>"$summary_file"
    exit 0
  fi
  fail_first
fi

# A stall or a timeout, even after a summary, is not a flaky test: the host
# was killed, so nothing it reported can be trusted.
if [[ $first_rc -eq 124 || $first_hang -eq 1 ]]; then fail_first; fi

# Every identifier xcodebuild knows, to place the failed tests exactly.
enumerate_tests() {
  local out="$1"
  timeout "$TEST_TIMEOUT_SECONDS" xcodebuild test-without-building \
    -project Ghostty.xcodeproj -scheme Ghostty \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -skipMacroValidation \
    -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
    -test-enumeration-output-path "$out" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO \
    >"${out%.json}.log" 2>&1
}

# A summary with failed tests: rerun exactly those, if there are few enough.
[[ $has_summary -eq 1 ]] || fail_first
failed_count="$(grep -E '^✘ Test .* failed after ' "$log" | grep -vc '^✘ Test run with ' || true)"
if [[ "${failed_count:-0}" -eq 0 ]]; then fail_first; fi
if [[ $failed_count -gt $MAX_RETRIED_FAILURES ]]; then
  echo "::notice::$failed_count tests failed (more than $MAX_RETRIED_FAILURES): not retrying"
  fail_first
fi

enumeration="${log%.log}-enumeration.json"
if ! enumerate_tests "$enumeration"; then
  echo "::notice::could not enumerate the tests (see ${enumeration%.json}.log): not retrying"
  fail_first
fi
# list-failed-tests.sh's status is checked here, not inside a process substitution that would drop it.
failed_list="$("$script_dir/list-failed-tests.sh" "$log" "$enumeration")" || {
  echo "::notice::could not resolve the failed tests: not retrying"
  fail_first
}
failed_ids=()
while IFS= read -r id; do
  [[ -n "$id" ]] && failed_ids+=("$id")
done <<<"$failed_list"

if [[ ${#failed_ids[@]} -eq 0 ]]; then fail_first; fi
if [[ ${#failed_ids[@]} -gt $MAX_RETRIED_FAILURES ]]; then
  echo "::notice::${#failed_ids[@]} tests failed (more than $MAX_RETRIED_FAILURES): not retrying"
  fail_first
fi
for id in "${failed_ids[@]}"; do
  if [[ "$id" == '?/'* ]]; then
    echo "::notice::could not tell which suite ${id#\?/} belongs to: not retrying"
    fail_first
  fi
done

only=()
for id in "${failed_ids[@]}"; do only+=("-only-testing:$id"); done
mark_retried
echo "Retrying ${#failed_ids[@]} failed test(s) once: ${failed_ids[*]#GhosttyTests/}"
run_filtered "$retry_log" "$retry_bundle" "${only[@]}"
# Passed means: exit 0, every retried test ran and passed, and the focus-gate
# and skip notes on the retry's log hold.
if [[ $rc -eq 0 ]] \
  && "$script_dir/check-filtered-run.sh" "$retry_bundle" "$retry_log" "${failed_ids[@]}" \
  && "$script_dir/check-test-log.sh" "$retry_log" 0 --notes-only; then
  soften_first
  {
    printf '### Flaky tests\n\nFailed, then passed on retry:\n\n'
    for id in "${failed_ids[@]}"; do printf -- '- `%s`\n' "${id#GhosttyTests/}"; done
  } >>"$summary_file"
  for id in "${failed_ids[@]}"; do
    echo "::warning title=Flaky test::${id#GhosttyTests/} failed then passed on retry"
  done
  echo "All tests passed (after retrying ${#failed_ids[@]} flaky test(s))"
  exit 0
fi
dump_failures "$retry_bundle"
echo "::error::${#failed_ids[@]} test(s) failed again on retry"
fail_first
