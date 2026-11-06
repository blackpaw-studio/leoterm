#!/usr/bin/env bash
# Plain-sh tests for semver-gt.sh. Run directly:
#   ./test_semver-gt.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly script="$PWD/../semver-gt.sh"
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

# expect RC A B: semver-gt.sh A B must exit RC (0 = A > B, 1 = not, 2 = bad input).
expect() {
  local want="$1" a="$2" b="$3" rc
  bash "$script" "$a" "$b" > /dev/null 2>&1 && rc=0 || rc=$?
  [[ "$rc" -eq "$want" ]] && ok=yes || ok=no
  result "$ok" "semver-gt '$a' '$b' exits $want" "rc=$rc"
}

expect 0 0.56.2 0.56.1
expect 1 0.56.1 0.56.1
expect 1 0.56.0 0.56.1
expect 0 0.10.0 0.9.0
expect 1 0.9.0 0.10.0
expect 0 1.0.0 0.99.99
expect 0 0.56.08 0.56.7
expect 0 99999999999999999999.0.0 1.0.0
expect 1 1.0.0 99999999999999999999.0.0

for bad in "" v1.0.0 1.0 1.0.0.0 "1.0.0;rm -rf" 1.0.0-rc1 " 1.0.0" -1.0.0 1.0.x; do
  expect 2 "$bad" 0.0.1
  expect 2 0.0.1 "$bad"
done

bash "$script" 1.0.0 > /dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 2 ]] && ok=yes || ok=no
result "$ok" "wrong argument count exits 2" "rc=$rc"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
