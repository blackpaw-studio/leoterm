#!/usr/bin/env bash
# Plain-sh tests for run-unit-tests.sh's retry policy: tests that failed are
# rerun once by name, a crashed host's suite is rerun once, and neither is
# retried when it looks like breakage. The real script runs against fakes: a
# stand-in test host and xcodebuild whose outputs and exit statuses each test
# scripts (host.N / xb.N for the Nth call), and a `timeout` that just runs the
# command. Run directly:
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
n=$(($(cat "$FAKE_DIR/xb.count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/xb.count"
printf '%s\n' "$@" >"$FAKE_DIR/xb.$n.args"
cat "$FAKE_DIR/xb.$n" 2>/dev/null
exit "$(cat "$FAKE_DIR/xb.$n.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$bin/timeout" "$bin/xcodebuild"

derived="$work/derived"
host="$derived/Build/Products/Debug/Leo.app/Contents/MacOS/Leo"
mkdir -p "$(dirname "$host")"
cat >"$host" <<'EOF'
#!/bin/bash
n=$(($(cat "$FAKE_DIR/host.count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/host.count"
cat "$FAKE_DIR/host.$n" 2>/dev/null
exit "$(cat "$FAKE_DIR/host.$n.rc" 2>/dev/null || echo 0)"
EOF
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

# new_case: a fresh scenario dir.
new_case() {
  export FAKE_DIR="$work/case-$RANDOM$RANDOM"
  mkdir -p "$FAKE_DIR"
}

# run_case [ENV=VALUE...]: runs the script; sets out, rc, and the files below.
run_case() {
  : >"$FAKE_DIR/step-summary"
  : >"$FAKE_DIR/github-output"
  rc=0
  out="$(cd "$repo" && env PATH="$bin:$PATH" DERIVED_DATA="$derived" DEVELOPER_DIR=/nonexistent \
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
