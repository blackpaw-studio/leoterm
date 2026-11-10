#!/usr/bin/env bash
# Plain-sh tests for close-superseded-bumps.sh against fixture PR lists and a
# stubbed gh (no network, nothing is really closed). Run directly:
#   ./test_close-superseded-bumps.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
readonly script="$PWD/../close-superseded-bumps.sh"
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The stub gh answers `pr list` from $FIXTURE and logs every other call.
cat > "$work/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then
  cat "$FIXTURE"
else
  echo "$*" >> "$GH_LOG"
fi
STUB
chmod +x "$work/gh"

# run VERSION NEW_PR [PR_JSON...]: calls in $calls, status in $rc.
run() {
  local version="$1" new_pr="$2"
  shift 2
  printf '[%s]\n' "$(IFS=,; echo "$*")" > "$work/fixture.json"
  : > "$work/gh.log"
  rc=0
  FIXTURE="$work/fixture.json" GH_LOG="$work/gh.log" GH="$work/gh" \
    bash "$script" "$new_pr" "$version" > "$work/out" 2>&1 || rc=$?
  calls="$(cat "$work/gh.log")"
}

pr() { # NUMBER BRANCH [cross-repo]
  printf '{"number":%s,"headRefName":"%s","isCrossRepository":%s}' "$1" "$2" "${3:-false}"
}

run 0.10.0 50 "$(pr 50 bump/leo-0.10.0)"
[[ "$rc" -eq 0 && -z "$calls" ]] && ok=yes || ok=no
result "$ok" "no other PRs: closes nothing and succeeds" "rc=$rc calls=$calls"

run 0.10.0 50
[[ "$rc" -eq 0 && -z "$calls" ]] && ok=yes || ok=no
result "$ok" "empty PR list: closes nothing and succeeds" "rc=$rc calls=$calls"

run 0.10.0 50 "$(pr 50 bump/leo-0.10.0)" "$(pr 40 bump/leo-0.9.0)"
[[ "$rc" -eq 0 && "$calls" == "pr close 40 --comment Superseded by #50" ]] && ok=yes || ok=no
result "$ok" "0.9.0 is lower than 0.10.0 and is closed with a Superseded comment" "rc=$rc calls=$calls"

run 0.9.0 50 "$(pr 50 bump/leo-0.9.0)" "$(pr 60 bump/leo-0.10.0)"
[[ "$rc" -eq 0 && -z "$calls" ]] && ok=yes || ok=no
result "$ok" "0.10.0 is higher than 0.9.0 and is never touched" "rc=$rc calls=$calls"

run 0.5.0 50 "$(pr 50 bump/leo-0.5.0)" "$(pr 51 bump/leo-0.5.0)"
[[ "$rc" -eq 0 && -z "$calls" ]] && ok=yes || ok=no
result "$ok" "an equal version on another PR is not lower and is never touched" "rc=$rc calls=$calls"

run 0.10.0 50 "$(pr 50 bump/leo-0.10.0)" "$(pr 31 feat/thing)" "$(pr 32 bump/other-0.1.0)" \
  "$(pr 33 xbump/leo-0.1.0)"
[[ "$rc" -eq 0 && -z "$calls" ]] && ok=yes || ok=no
result "$ok" "non-bump PRs are never touched" "rc=$rc calls=$calls"

run 0.10.0 50 "$(pr 50 bump/leo-0.10.0)" "$(pr 41 bump/leo-0.1.0 true)"
[[ "$rc" -eq 0 && -z "$calls" ]] && ok=yes || ok=no
result "$ok" "a fork's bump/leo-* PR is never touched" "rc=$rc calls=$calls"

run 0.10.0 50 "$(pr 50 bump/leo-0.10.0)" "$(pr 41 bump/leo-0.1.0-rc1)" "$(pr 42 bump/leo-)" \
  "$(pr 43 'bump/leo-1.0.0;rm -rf')"
[[ "$rc" -eq 0 && -z "$calls" ]] && ok=yes || ok=no
result "$ok" "bump branches without a strict X.Y.Z version are skipped" "rc=$rc calls=$calls"

run 0.10.0 50 "$(pr 50 bump/leo-0.10.0)" "$(pr 40 bump/leo-0.9.0)" "$(pr 39 bump/leo-0.8.1)" \
  "$(pr 60 bump/leo-0.11.0)" "$(pr 31 feat/thing)"
want="$(printf 'pr close 40 --comment Superseded by #50\npr close 39 --comment Superseded by #50')"
[[ "$rc" -eq 0 && "$calls" == "$want" ]] && ok=yes || ok=no
result "$ok" "mixed list: closes exactly the lower bump PRs, nothing else" "rc=$rc calls=$calls"

run 0.10.0 50 "$(pr 40 bump/leo-0.9.0)"
[[ "$calls" != *"--delete-branch"* && "$calls" != *"delete"* ]] && ok=yes || ok=no
result "$ok" "closing never deletes a branch" "calls=$calls"

for bad in "" v0.10.0 0.10 "0.10.0;x"; do
  run "$bad" 50
  [[ "$rc" -eq 2 && -z "$calls" ]] && ok=yes || ok=no
  result "$ok" "bad version '$bad' exits 2 and closes nothing" "rc=$rc"
done
run 0.10.0 "5x"
[[ "$rc" -eq 2 && -z "$calls" ]] && ok=yes || ok=no
result "$ok" "non-numeric PR number exits 2" "rc=$rc"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
