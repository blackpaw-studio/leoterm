#!/usr/bin/env bash
# Verdict for a filtered run (`xcodebuild test-without-building -only-testing`)
# that exited 0. That path prints no Swift Testing "Test run with N tests"
# summary, so counts come from the result bundle, falling back to the log's
# "Test case ... passed/failed" lines. Prints "N passed, M failed" and exits 1
# when anything failed or nothing ran (a filter that matched no test).
#
# With test identifiers after LOG (`GhosttyTests/Suite/test()`, as passed to
# -only-testing), each must also have run: xcodebuild exits 0 and counts other
# tests as passed when an identifier matches nothing or its suite is skipped,
# so a retry would otherwise "pass" without running the test it was for. An
# identifier needs a Test Case in the bundle that passed (every case of a
# parameterized test); no result, a skip, or a failure fails the run.
# Usage: check-filtered-run.sh RESULT_BUNDLE LOG [TEST_ID...]
set -euo pipefail

bundle="${1:?usage: check-filtered-run.sh RESULT_BUNDLE LOG}"
log="${2:?usage: check-filtered-run.sh RESULT_BUNDLE LOG [TEST_ID...]}"
shift 2

passed="" failed=""
if [[ -d "$bundle" ]] && summary="$(xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>/dev/null)"; then
  counts="$(python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d["passedTests"], d["failedTests"])' <<<"$summary" 2>/dev/null || true)"
  read -r passed failed <<<"$counts"
fi
if [[ -z "$passed" ]]; then
  passed="$(grep -cE "^Test case '.*' passed" "$log" || true)"
  failed="$(grep -cE "^Test case '.*' failed" "$log" || true)"
fi

echo "$passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  echo "::error::$failed test case(s) failed despite a zero exit status"
  exit 1
fi
if [[ "$passed" -eq 0 ]]; then
  echo "::error::the test filter matched no tests"
  exit 1
fi

(($# == 0)) && exit 0

# The per-test results: a Test Case node's identifier is its path under the
# test bundle (`Suite/Nested/test()`), its result Passed/Failed/Skipped, and a
# parameterized test lists one `Arguments` child per case.
tests_json="$(xcrun xcresulttool get test-results tests --path "$bundle" --compact 2>/dev/null)" || {
  echo "::error::could not read the per-test results from $bundle"
  exit 1
}
python3 -I -c '
import json, sys

wanted = [w.removeprefix("GhosttyTests/") for w in sys.argv[1:]]
cases = {}

def walk(node):
    if node.get("nodeType") == "Test Case":
        cases[node.get("nodeIdentifier", "")] = node
    for child in node.get("children", []):
        walk(child)

for root in json.loads(sys.stdin.read()).get("testNodes", []):
    walk(root)

def verdict(node):
    if node is None:
        return "no result in the bundle (the identifier matched nothing)"
    bad = [c.get("result") for c in node.get("children", []) if c.get("nodeType") == "Arguments" and c.get("result") != "Passed"]
    if node.get("result") != "Passed":
        return node.get("result", "no result") + " (did not pass)"
    if bad:
        return "a parameterized case did not pass: " + bad[0]
    return None

problems = [(w, verdict(cases.get(w))) for w in wanted]
problems = [(w, v) for w, v in problems if v]
for w, v in problems:
    print(f"::error::retried test {w}: {v}")
sys.exit(1 if problems else 0)
' "$@" <<<"$tests_json"
