#!/usr/bin/env bash
# Plain-sh tests for run-unit-tests.sh's retry policy: tests that failed are
# resolved to real identifiers and rerun once, a retry passes only if every
# one of them ran, a crashed host's suite is rerun once, and none of it is
# retried when it looks like breakage. The real script runs against fakes: a
# stand-in test host, xcodebuild (test enumeration from enum.json; outputs and
# exit statuses each test scripts as xb.N for the Nth test run) and xcrun's
# xcresulttool (results from xb.N.tests / xb.N.summary, else every -only-testing
# id as passed), and a `timeout` that just runs the command. Run directly:
#   ./test_run-unit-tests-retry.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script="$PWD/../run-unit-tests.sh"
pass=0
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- Fakes -----------------------------------------------------------------

bin="$work/bin"
mkdir -p "$bin"
printf '#!/bin/bash\nshift\nexec "$@"\n' >"$bin/timeout"
cat >"$bin/xcodebuild" <<'EOF'
#!/bin/bash
# build-for-testing succeeds; each test-without-building is the next xb.N.
[[ "$1" == build-for-testing ]] && exit 0
bundle="" enum_out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == -resultBundlePath ]] && bundle="${args[i + 1]}"
  [[ "${args[i]}" == -test-enumeration-output-path ]] && enum_out="${args[i + 1]}"
done
if [[ -n "$enum_out" ]]; then
  echo x >>"$FAKE_DIR/enumerations"
  cp "$FAKE_DIR/enum.json" "$enum_out"
  exit "$(cat "$FAKE_DIR/enum.rc" 2>/dev/null || echo 0)"
fi
[[ -n "$bundle" ]] && mkdir -p "$bundle"
n=$(($(cat "$FAKE_DIR/xb.count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/xb.count"
printf '%s\n' "$@" >"$FAKE_DIR/xb.$n.args"
env | grep '^TEST_RUNNER_' >"$FAKE_DIR/xb.$n.env" || true
cat "$FAKE_DIR/xb.$n" 2>/dev/null
exit "$(cat "$FAKE_DIR/xb.$n.rc" 2>/dev/null || echo 0)"
EOF
cat >"$bin/xcrun" <<'EOF'
#!/bin/bash
# xcrun xcresulttool get test-results (summary|tests) --path BUNDLE --compact
n=$(cat "$FAKE_DIR/xb.count")
f="$FAKE_DIR/xb.$n.$4"
if [[ -e "$f" ]]; then cat "$f"; exit 0; fi
python3 -I - "$4" "$FAKE_DIR/xb.$n.args" <<'PY'
import json, sys
cases = [
    {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": a.split(":", 1)[1].removeprefix("GhosttyTests/")}
    for a in open(sys.argv[2]).read().split("\n")
    if a.startswith("-only-testing:")
]
print(json.dumps({"testNodes": cases} if sys.argv[1] == "tests" else {"passedTests": len(cases), "failedTests": 0}))
PY
EOF
chmod +x "$bin/timeout" "$bin/xcodebuild" "$bin/xcrun"

derived="$work/derived"
host="$derived/Build/Products/Debug/Leo.app/Contents/MacOS/Leo"
mkdir -p "$(dirname "$host")"
# The host's interpreter is a copy of bash, not /bin/bash: dyld strips DYLD_*
# variables from SIP-protected binaries only, so a copy sees the script's
# DYLD_INSERT_LIBRARIES exactly as the real app would (the Ghast VM runs
# without SIP, so /bin/bash does too), and the test fails if the injection is
# not neutered. Not re-signed: an ad-hoc signature on the arm64e bash is killed
# on the VM. A copy some macOS refuses to run falls back to /bin/bash.
host_bash="$work/host-bash"
cp /bin/bash "$host_bash"
if ! { "$host_bash" -c : >/dev/null 2>&1; } 2>/dev/null; then host_bash=/bin/bash; fi
{ echo "#!$host_bash"; cat <<'EOF'
n=$(($(cat "$FAKE_DIR/host.count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/host.count"
cat "$FAKE_DIR/host.$n" 2>/dev/null
exit "$(cat "$FAKE_DIR/host.$n.rc" 2>/dev/null || echo 0)"
EOF
} >"$host"
chmod +x "$host"

repo="$work/repo"
mkdir -p "$repo/macos/Tests/Leo"
git -C "$repo" init -q
cat >"$repo/macos/Tests/Leo/Sample.swift" <<'EOF'
struct AlphaTests {
    @Test func flaky() {}
    @Test func steady() {}
    @Test func twin() {}
}
struct BetaTests {
    @Test func other() {}
    @Test func twin() {}
}
EOF

# ---- Scenario helpers --------------------------------------------------------

# fail_log TEST_NAME... : a full run's failures (suites AlphaTests, BetaTests).
fail_log() {
  local t
  for t in "$@"; do
    echo "✘ Test $t recorded an issue at Sample.swift:1:1: Expectation failed"
    echo "✘ Test $t failed after 0.1 seconds with 1 issue."
  done
  echo "✘ Suite AlphaTests failed after 0.1 seconds with 1 issue."
  echo "✘ Suite BetaTests failed after 0.1 seconds with 1 issue."
  echo "✘ Test run with 5 tests in 2 suites failed after 1.0 seconds with $# issues."
}
pass_log() { echo "✔ Test run with 5 tests in 2 suites passed after 1.0 seconds."; }

# enum_json ID...: the tests xcodebuild's enumeration knows.
enum_json() {
  python3 -I -c '
import json, sys
print(json.dumps({"errors": [], "values": [{"disabledTests": [], "enabledTests": [{"identifier": i} for i in sys.argv[1:]]}]}))' "$@"
}

# tests_json RESULT ID...: a result bundle holding each ID as a test case with RESULT.
tests_json() {
  python3 -I -c '
import json, sys
print(json.dumps({"testNodes": [{"nodeType": "Test Case", "result": sys.argv[1], "nodeIdentifier": i} for i in sys.argv[2:]]}))' "$@"
}

# The script never reads DEVELOPER_DIR here (the host is a fake), but on macOS
# /usr/bin/git and /usr/bin/python3 are xcrun shims that fail on a DEVELOPER_DIR
# that doesn't exist, so it must name a real developer directory.
developer_dir="$(xcode-select -p 2>/dev/null || true)"
: "${developer_dir:=/Library/Developer/CommandLineTools}"

# new_case: a fresh scenario dir, with the sample suites enumerated.
new_case() {
  export FAKE_DIR="$work/case-$RANDOM$RANDOM"
  mkdir -p "$FAKE_DIR"
  enum_json 'GhosttyTests/AlphaTests/flaky()' 'GhosttyTests/AlphaTests/steady()' 'GhosttyTests/AlphaTests/twin()' \
    'GhosttyTests/BetaTests/other()' 'GhosttyTests/BetaTests/twin()' >"$FAKE_DIR/enum.json"
}

# run_case [ENV=VALUE...]: runs the script; sets out, rc, and the files below.
run_case() {
  : >"$FAKE_DIR/step-summary"
  : >"$FAKE_DIR/github-output"
  rc=0
  out="$(cd "$repo" && env PATH="$bin:$PATH" DERIVED_DATA="$derived" DEVELOPER_DIR="$developer_dir" LEO_TEST_INJECT_LIB= \
    LOG="$FAKE_DIR/leo-tests.log" RUNNER_TEMP="$FAKE_DIR/tmp" HOME="$FAKE_DIR/home" \
    GITHUB_STEP_SUMMARY="$FAKE_DIR/step-summary" GITHUB_OUTPUT="$FAKE_DIR/github-output" \
    "$@" bash "$script" 2>&1)" || rc=$?
}

check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc"
    echo "$out" | tail -30 | sed 's/^/    | /'
    # The test host's own output (its stderr included) and the xcodebuild fake's args.
    local f
    for f in "$FAKE_DIR"/*.log "$FAKE_DIR"/xb.*.args; do
      [[ -e "$f" ]] || continue
      echo "    ## ${f#"$FAKE_DIR"/}"
      tail -15 "$f" | sed 's/^/    | /'
    done
    fail=$((fail + 1))
  fi
}

has() { grep -qF -- "$1" <<<"$out"; }
lacks() { ! grep -qF -- "$1" <<<"$out"; }
calls() { [[ "$(cat "$FAKE_DIR/$1.count" 2>/dev/null || echo 0)" == "$2" ]]; }

# ---- Cases -------------------------------------------------------------------

# Every retried test passes: the step passes, one warning per flaky test.
new_case
{ fail_log 'flaky()' 'other()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
{ echo "Test case 'AlphaTests/flaky()' passed"; echo "Test case 'BetaTests/other()' passed"; } >"$FAKE_DIR/xb.1"
run_case
check "all retried tests pass: the step passes" test "$rc" -eq 0
check "  one warning per flaky test (Alpha)" has '::warning title=Flaky test::AlphaTests/flaky() failed then passed on retry'
check "  one warning per flaky test (Beta)" has '::warning title=Flaky test::BetaTests/other() failed then passed on retry'
check "  the retry named exactly the failed tests" bash -c "grep -qxF -- '-only-testing:GhosttyTests/AlphaTests/flaky()' '$FAKE_DIR/xb.1.args' && grep -qxF -- '-only-testing:GhosttyTests/BetaTests/other()' '$FAKE_DIR/xb.1.args' && ! grep -q steady '$FAKE_DIR/xb.1.args'"
check "  the step summary lists the flaky tests" bash -c "grep -q 'Flaky tests' '$FAKE_DIR/step-summary' && grep -qF 'AlphaTests/flaky()' '$FAKE_DIR/step-summary'"
check "  the workflow is told to upload the evidence" grep -qx 'retried=true' "$FAKE_DIR/github-output"
check "  the first attempt's errors are softened to warnings" lacks '::error'
check "  one retry only" calls xb 1
check "  and one enumeration" bash -c "[[ \$(wc -l <'$FAKE_DIR/enumerations' | tr -d ' ') == 1 ]]"

# A retried test fails again: the step fails with the errors.
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
echo "Test case 'AlphaTests/flaky()' failed" >"$FAKE_DIR/xb.1"
echo 65 >"$FAKE_DIR/xb.1.rc"
run_case
check "a retried test failing again fails the step" test "$rc" -ne 0
check "  with ::error annotations" has '::error'
check "  no second round" calls xb 1

# More than the cap: breakage, not flake.
new_case
names=()
for i in $(seq 1 11); do names+=("t$i()"); done
{ fail_log "${names[@]}"; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
run_case
check "more than 10 failures fails without retrying" test "$rc" -ne 0
check "  no retry ran" calls xb 0
check "  and says why" has 'not retrying'

# Exactly at the cap is still retried.
new_case
names=()
for i in $(seq 1 10); do names+=("t$i()"); done
{ fail_log "${names[@]}"; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
run_case
check "10 failures are retried (an unnameable one stops it here, not the cap)" has "could not tell which suite"

# A test no failing suite declares can't be rerun by name.
new_case
{ fail_log 'ghost()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
run_case
check "an unplaceable failing test fails without retrying" test "$rc" -ne 0
check "  no retry ran" calls xb 0

# A name two failing suites declare could be either: not guessed, not retried.
new_case
{ fail_log 'twin()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
run_case
check "an ambiguous failing test fails without retrying" bash -c "[[ $rc -ne 0 ]]"
check "  no retry ran" calls xb 0

# A parameterized test in a nested suite: the log's " with N test cases"
# suffix is not part of the test's name, and the nested path is kept.
new_case
enum_json 'GhosttyTests/AlphaTests/Nested/param(_:step:)' 'GhosttyTests/BetaTests/param(_:step:)' >"$FAKE_DIR/enum.json"
{
  echo '✘ Test param(_:step:) with 4 test cases failed after 0.1 seconds with 2 issues.'
  echo '✘ Suite Nested failed after 0.1 seconds with 2 issues.'
  echo '✘ Test run with 5 tests in 2 suites failed after 1.0 seconds with 2 issues.'
} >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
run_case
check "a parameterized nested test is retried and passes" test "$rc" -eq 0
check "  by its qualified identifier, without the case-count suffix" grep -qxF -- '-only-testing:GhosttyTests/AlphaTests/Nested/param(_:step:)' "$FAKE_DIR/xb.1.args"
check "  and reported without the bundle prefix" has '::warning title=Flaky test::AlphaTests/Nested/param(_:step:) failed then passed on retry'

# An identifier xcodebuild matches to nothing exits 0 and "passes" the other
# tests: the retry must not count that as the failed test passing.
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
echo "Test case 'AlphaTests/steady()' passed" >"$FAKE_DIR/xb.1"
tests_json Passed 'AlphaTests/steady()' >"$FAKE_DIR/xb.1.tests"
echo '{"passedTests":1,"failedTests":0}' >"$FAKE_DIR/xb.1.summary"
run_case
check "a retry that never ran the failed test fails" test "$rc" -ne 0
check "  and says the identifier matched nothing" has 'AlphaTests/flaky(): no result in the bundle'
check "  with no flaky warning" lacks 'title=Flaky test'

# A skipped retried test (a gated suite) is not a pass either.
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
tests_json Skipped 'AlphaTests/flaky()' >"$FAKE_DIR/xb.1.tests"
echo '{"passedTests":2,"failedTests":0}' >"$FAKE_DIR/xb.1.summary"
run_case
check "a skipped retry fails" test "$rc" -ne 0
check "  and says it did not pass" has 'AlphaTests/flaky(): Skipped'

# One passing and one never run: the step still fails.
new_case
{ fail_log 'flaky()' 'other()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
tests_json Passed 'AlphaTests/flaky()' >"$FAKE_DIR/xb.1.tests"
echo '{"passedTests":1,"failedTests":0}' >"$FAKE_DIR/xb.1.summary"
run_case
check "every retried test must have run, not just one" test "$rc" -ne 0
check "  naming the one that did not" has 'BetaTests/other(): no result in the bundle'

# The host tier reaches the retry's test host (xcodebuild forwards only TEST_RUNNER_ variables).
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
run_case LEO_HOST_TESTS=1
check "the retry's host gets TEST_RUNNER_LEO_HOST_TESTS" grep -qx 'TEST_RUNNER_LEO_HOST_TESTS=1' "$FAKE_DIR/xb.1.env"

# A retry whose log shows the host tier silently skipped fails.
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
echo '➜ Suite AlphaTests skipped: host tier: set LEO_HOST_TESTS=1' >"$FAKE_DIR/xb.1"
run_case LEO_HOST_TESTS=1
check "a retry that skipped host-only tests fails the step" test "$rc" -ne 0
check "  with the host-tier error" has 'host tier skipped host-only tests'

# A focus-gate skip on the retry is surfaced like it is on a first run.
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
echo 'focus-gate-skip: no key window' >"$FAKE_DIR/xb.1"
run_case
check "a focus-gate skip on the retry is a warning" has 'focus-gate check(s) skipped'
check "  and the flaky test still passes the step" test "$rc" -eq 0

# A timeout after the summary was printed means the host was killed: no retry.
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 124 >"$FAKE_DIR/host.1.rc"
run_case
check "a timeout after a summary fails without a retry" test "$rc" -ne 0
check "  no enumeration or retry ran" bash -c "[[ ! -e '$FAKE_DIR/enumerations' && ! -e '$FAKE_DIR/xb.count' ]]"

# The enumeration fails: the failure can't be named, so no retry.
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
echo 1 >"$FAKE_DIR/enum.rc"
run_case
check "a failed enumeration fails without a retry" test "$rc" -ne 0
check "  no retry ran" calls xb 0

# The enumeration is unreadable: the resolver's failure aborts, never a retry of nothing.
new_case
{ fail_log 'flaky()'; } >"$FAKE_DIR/host.1"
echo 1 >"$FAKE_DIR/host.1.rc"
echo 'not json' >"$FAKE_DIR/enum.json"
run_case
check "an unreadable enumeration fails without a retry" test "$rc" -ne 0
check "  no retry ran" calls xb 0
check "  and says the failures could not be resolved" has 'could not resolve the failed tests'

# The host crashes, the rerun is clean: pass with a warning.
new_case
echo "boom" >"$FAKE_DIR/host.1"
echo 134 >"$FAKE_DIR/host.1.rc"
pass_log >"$FAKE_DIR/host.2"
run_case
check "a crash then a clean rerun passes" test "$rc" -eq 0
check "  with a crash warning" has '::warning title=Test host crash::'
check "  the whole suite reran, not a filtered one" bash -c "[[ \$(cat '$FAKE_DIR/host.count') == 2 ]] && [[ ! -e '$FAKE_DIR/xb.count' ]]"
check "  the first attempt's crash evidence was collected" test -d "$FAKE_DIR/tmp/leo-crash-evidence"
check "  the first attempt's log is kept apart from the rerun's" bash -c "grep -q boom '$FAKE_DIR/leo-tests.log' && grep -q 'Test run with' '$FAKE_DIR/leo-tests-retry.log'"
check "  the workflow is told to upload the evidence" grep -qx 'retried=true' "$FAKE_DIR/github-output"

# The host crashes twice: fail.
new_case
echo "boom" >"$FAKE_DIR/host.1"
echo 134 >"$FAKE_DIR/host.1.rc"
echo "boom again" >"$FAKE_DIR/host.2"
echo 134 >"$FAKE_DIR/host.2.rc"
run_case
check "a crash then another crash fails" test "$rc" -ne 0
check "  after one rerun only" bash -c "[[ \$(cat '$FAKE_DIR/host.count') == 2 ]]"

# A timeout is not retried.
new_case
echo "stuck" >"$FAKE_DIR/host.1"
echo 124 >"$FAKE_DIR/host.1.rc"
run_case
check "a timeout fails without a rerun" bash -c "[[ $rc -ne 0 && \$(cat '$FAKE_DIR/host.count') == 1 ]]"

# A clean first run needs no retry.
new_case
pass_log >"$FAKE_DIR/host.1"
run_case
check "a clean run passes with no retry" bash -c "[[ $rc -eq 0 && \$(cat '$FAKE_DIR/host.count') == 1 ]]"
check "  and no upload is requested" bash -c "! grep -q retried '$FAKE_DIR/github-output'"

# Filtered runs never retry.
new_case
echo "Test case 'AlphaTests/flaky()' failed" >"$FAKE_DIR/xb.1"
echo 65 >"$FAKE_DIR/xb.1.rc"
run_case LEO_TEST_FILTER=AlphaTests
check "a failing filtered run fails" test "$rc" -ne 0
check "  without a second xcodebuild run" calls xb 1
check "  or a full-suite host run" calls host 0

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
