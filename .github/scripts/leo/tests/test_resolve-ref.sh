#!/usr/bin/env bash
# Plain-sh tests for resolve-ref.sh. Run directly: ./test_resolve-ref.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

pass=0
fail=0

# A fake `gh` on PATH so tests don't touch the network. GH_FAKE_HEAD_REPO
# controls what `gh api .../pulls/<n>` reports as head.repo.full_name.
fakebin="$(mktemp -d)"
trap 'rm -rf "$fakebin"' EXIT
cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
  # Emulate `gh api ... --jq '.head.repo.full_name // ""'` output directly;
  # this test double isn't exercising gh's own --jq support.
  echo "${GH_FAKE_HEAD_REPO:-}"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
EOF
chmod +x "$fakebin/gh"
export PATH="$fakebin:$PATH"

# A scratch "origin" + clone so the sha-reachability check has something
# real to fetch/inspect without touching the actual leoterm repo or network.
origin="$(mktemp -d)"
repo="$(mktemp -d)"
trap 'rm -rf "$fakebin" "$origin" "$repo"' EXIT
git init -q --bare "$origin"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" remote add origin "$origin"
git -C "$repo" commit -q --allow-empty -m "on main"
git -C "$repo" push -q origin main
reachable_sha="$(git -C "$repo" rev-parse HEAD)"

# A commit that only exists in a second clone -- never pushed to origin --
# simulates a fork PR's head commit: valid hex, unreachable from any branch
# or tag of the base repo.
fork_repo="$(mktemp -d)"
trap 'rm -rf "$fakebin" "$origin" "$repo" "$fork_repo"' EXIT
git init -q -b main "$fork_repo"
git -C "$fork_repo" config user.email test@example.com
git -C "$fork_repo" config user.name test
git -C "$fork_repo" commit -q --allow-empty -m "fork-only commit"
unreachable_sha="$(git -C "$fork_repo" rev-parse HEAD)"

run() {
  # $1: REF_INPUT, $2: GH_FAKE_HEAD_REPO (optional), $3: RESOLVE_REF_GIT_DIR (optional)
  REF_INPUT="$1" GH_FAKE_HEAD_REPO="${2:-}" GITHUB_REPOSITORY="blackpaw-studio/leoterm" \
    DEFAULT_SHA="deadbeef" RESOLVE_REF_GIT_DIR="${3:-$repo}" ../resolve-ref.sh
}

check() {
  local desc="$1" expected_status="$2" input="$3" fake_repo="${4:-}" expected_output="${5:-}"
  local out status
  out="$(run "$input" "$fake_repo" 2>&1)" && status=0 || status=$?
  if [[ "$status" -ne "$expected_status" ]]; then
    echo "FAIL: $desc (status $status, expected $expected_status; output: $out)"
    fail=$((fail + 1))
    return
  fi
  if [[ -n "$expected_output" && "$out" != "$expected_output" ]]; then
    echo "FAIL: $desc (output '$out', expected '$expected_output')"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

check "same-repo PR number resolves" 0 "42" "blackpaw-studio/leoterm" "refs/pull/42/head"
check "fork PR number is rejected" 1 "42" "someone-else/leoterm"
check "PR lookup with no head repo is rejected" 1 "42" ""
check "raw refs/pull/* form is rejected" 1 "refs/pull/42/head"
check "raw refs/pull/*/merge form is rejected" 1 "refs/pull/42/merge"
check "sha reachable from a remote branch resolves" 0 "$reachable_sha" "" "$reachable_sha"
check "sha not reachable from any branch or tag is rejected" 1 "$unreachable_sha"
check "empty ref falls back to DEFAULT_SHA" 0 "" "" "deadbeef"
check "branch name still resolves" 0 "main" "" "refs/heads/main"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
