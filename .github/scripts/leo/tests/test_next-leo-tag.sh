#!/usr/bin/env bash
# Plain-sh tests for next-leo-tag.sh, using a scratch git repo. Run directly:
#   ./test_next-leo-tag.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
readonly script="$PWD/../next-leo-tag.sh"
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
repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
add_commit() { git -C "$repo" commit -q --allow-empty -m "$1"; }
head_sha() { git -C "$repo" rev-parse HEAD; }

# run [COMMIT]: stdout in $out, status in $rc.
run() {
  rc=0
  out="$(cd "$repo" && bash "$script" "$@" 2> "$work/err")" || rc=$?
}

add_commit "c0"
run "$(head_sha)"
[[ "$rc" -ne 0 && -z "$out" ]] && ok=yes || ok=no
result "$ok" "no leo-v tags at all is an error, not an invented first release" "rc=$rc out=$out"

git -C "$repo" tag leo-v0.9.0
add_commit "c1"
git -C "$repo" tag leo-v1.10.0 # above 1.9.0 under semver, not lexical sort
add_commit "c2"
git -C "$repo" tag leo-v1.9.0
git -C "$repo" tag leo-v999.0.0-rc1 # not a release tag
git -C "$repo" tag v50.0.0          # not a leo tag
git -C "$repo" tag leo-v7.0         # not X.Y.Z
add_commit "c3"
target="$(head_sha)"

run "$target"
[[ "$rc" -eq 0 && "$out" == leo-v1.10.1 ]] && ok=yes || ok=no
result "$ok" "bumps the patch of the highest semver leo-vX.Y.Z tag, ignoring look-alikes" "rc=$rc out=$out"

run
[[ "$rc" -eq 0 && "$out" == leo-v1.10.1 ]] && ok=yes || ok=no
result "$ok" "defaults the commit to HEAD" "rc=$rc out=$out"

git -C "$repo" tag leo-v1.9.5 "$target"
run "$target"
[[ "$rc" -eq 0 && -z "$out" ]] && ok=yes || ok=no
result "$ok" "prints nothing when a release tag already points at the commit" "rc=$rc out=$out"
git -C "$repo" tag -d leo-v1.9.5 > /dev/null

git -C "$repo" tag -a leo-v1.10.0-annotated -m x "$target" # suffixed: not a release tag
run "$target"
[[ "$rc" -eq 0 && "$out" == leo-v1.10.1 ]] && ok=yes || ok=no
result "$ok" "a suffixed tag on the commit does not count as already released" "rc=$rc out=$out"

git -C "$repo" tag -a leo-v1.10.1 -m "annotated" "$target"
run "$target"
[[ "$rc" -eq 0 && -z "$out" ]] && ok=yes || ok=no
result "$ok" "an annotated release tag on the commit counts too" "rc=$rc out=$out"

run "not-a-commit"
[[ "$rc" -ne 0 && -z "$out" ]] && ok=yes || ok=no
result "$ok" "an unknown commit is an error" "rc=$rc out=$out"

run "--exec=evil"
[[ "$rc" -ne 0 && -z "$out" ]] && ok=yes || ok=no
result "$ok" "an option-looking commit argument is refused" "rc=$rc out=$out"

# A failed tagging run for an older merge, retried after a newer release.
git -C "$repo" checkout -q --detach "$target"
add_commit "c4 (older merge, never tagged)"
older="$(head_sha)"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --ff-only "$older"
add_commit "c5"
git -C "$repo" tag leo-v1.11.0
newer="$(head_sha)"

run "$older"
[[ "$rc" -ne 0 && -z "$out" ]] && ok=yes || ok=no
result "$ok" "refuses an older commit once a newer release exists (a retry must not roll back)" "rc=$rc out=$out"

git -C "$repo" checkout -q --detach "$target"
add_commit "side branch"
side="$(head_sha)"
git -C "$repo" checkout -q main
run "$side"
[[ "$rc" -ne 0 && -z "$out" ]] && ok=yes || ok=no
result "$ok" "refuses a commit that is not a descendant of the latest release" "rc=$rc out=$out"

add_commit "c6"
run "$(head_sha)"
[[ "$rc" -eq 0 && "$out" == leo-v1.11.1 ]] && ok=yes || ok=no
result "$ok" "still tags a descendant of the latest release" "rc=$rc out=$out"

run "$newer"
[[ "$rc" -eq 0 && -z "$out" ]] && ok=yes || ok=no
result "$ok" "the latest release's own commit stays a silent no-op" "rc=$rc out=$out"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
