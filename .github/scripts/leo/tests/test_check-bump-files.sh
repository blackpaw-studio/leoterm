#!/usr/bin/env bash
# Plain-sh tests for check-bump-files.sh. The input is the merged PR's file
# list as `gh api .../pulls/N/files --paginate --jq '.[] | [.status, .filename] | @tsv'`
# prints it, so each case is a fixture of that output. Run directly:
#   ./test_check-bump-files.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script="$PWD/../check-bump-files.sh"
readonly pin=macos/Bundled/LEO_VERSION
pass=0
fail=0

result() {
  local ok="$1" desc="$2" detail="${3:-}"
  if [[ "$ok" == yes ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc${detail:+ ($detail)}"
    fail=$((fail + 1))
  fi
}

# expect RC DESC FIXTURE: the script must exit RC on FIXTURE (a string
# with \t and \n escapes).
expect() {
  local want="$1" desc="$2" fixture="$3" rc
  printf '%b' "$fixture" | bash "$script" > /dev/null 2>&1 && rc=0 || rc=$?
  [[ "$rc" -eq "$want" ]] && ok=yes || ok=no
  result "$ok" "$desc" "rc=$rc"
}

expect 0 "only LEO_VERSION modified is a bump" "modified\t$pin\n"
expect 0 "...with or without a trailing newline" "modified\t$pin"
expect 1 "an empty file list is not a bump" ""
expect 1 "an extra file alongside LEO_VERSION is not a bump" "modified\t$pin\nmodified\tmacos/Sources/App.swift\n"
expect 1 "an extra file on a later page is not a bump" "modified\t$pin\nadded\t.github/workflows/leo-ci.yml\n"
expect 1 "another file alone is not a bump" "modified\tREADME.md\n"
expect 1 "a look-alike path is not a bump" "modified\t$pin.bak\n"
expect 1 "a path that merely ends with the pin path is not a bump" "modified\tx/$pin\n"
expect 1 "LEO_VERSION added is not a bump" "added\t$pin\n"
expect 1 "LEO_VERSION removed is not a bump" "removed\t$pin\n"
expect 1 "LEO_VERSION renamed onto from elsewhere is not a bump" "renamed\t$pin\n"
expect 1 "the pin listed twice is not exactly one change" "modified\t$pin\nmodified\t$pin\n"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
