#!/usr/bin/env bash
# Plain-bash tests for leo-runtests.sh's failure listing. Run directly:
#   macos/scripts/test_leo-runtests.sh
# The fixture lines are copied from real /tmp/leo-tests-*.log Swift Testing output.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=leo-runtests.sh
source "$here/leo-runtests.sh"

pass=0
fail=0
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT

cat > "$fixture" <<'LOG'
◇ Suite LeoSidebarTerminalScrollTests started.
◇ Test aRowSelectedWhileFilteredIsRevealedWhenTheFilterClears(_:) started.
◇ Test case passing 1 argument query → "agent-1" to aRowSelectedWhileFilteredIsRevealedWhenTheFilterClears(_:) started.
✘ Test aRowSelectedWhileFilteredIsRevealedWhenTheFilterClears(_:) recorded an issue with 1 argument query → "no-such-agent" at LeoSidebarTerminalScrollTests.swift:88:9: Expectation failed: await eventually {
✘ Test aRowSelectedWhileFilteredIsRevealedWhenTheFilterClears(_:) with 2 test cases failed after 0.677 seconds with 1 issue.
✘ Test closingARowsShellLeavesTheShellSplitBesideIt() recorded an issue at LeoSplitLayoutIntegrationTests.swift:40:9: Expectation failed
✘ Test closingARowsShellLeavesTheShellSplitBesideIt() failed after 0.529 seconds with 2 issues.
✘ Test savedSizeUnderTheMinimumInEitherDimensionIsNotRestored(saved:) with 2 test cases failed after 0.001 seconds with 2 issues.
✘ Test theSelectedRowIsDistinctFromTheOthersOnScreen(_:_:_:) with 4 test cases failed after 0.001 seconds with 3 issues.
✔ Test macosTitlebarStyleValues(raw:expected:) with 4 test cases passed after 0.002 seconds.
✔ Test errorsEmptyForValidConfig() passed after 0.001 seconds.
✘ Suite LeoSidebarTerminalScrollTests failed after 2.712 seconds with 2 issues.
✘ Test run with 1827 tests in 201 suites failed after 152.395 seconds with 17 issues.
LOG

listed="$(list_failures "$fixture")"

expect_listed() {
  local name="$1" test="$2"
  if grep -qF "✘ Test $test" <<<"$listed"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name -- '$test' missing from the failure list"
  fi
}

expect_count() {
  local name="$1" want="$2" got
  got="$(grep -c . <<<"$listed")"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name -- want $want lines, got $got:"
    echo "$listed"
  fi
}

expect_listed "lists a plain failed test" "closingARowsShellLeavesTheShellSplitBesideIt() failed"
expect_listed "lists a parameterized (_:) failure" "aRowSelectedWhileFilteredIsRevealedWhenTheFilterClears(_:) with 2 test cases failed"
expect_listed "lists a labelled-argument failure" "savedSizeUnderTheMinimumInEitherDimensionIsNotRestored(saved:) with 2 test cases failed"
expect_listed "lists a multi-argument failure" "theSelectedRowIsDistinctFromTheOthersOnScreen(_:_:_:) with 4 test cases failed"
# One line per failed test: no issue lines, suites, run summary, or passes.
expect_count "lists each failed test exactly once" 4

echo "test_leo-runtests: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
