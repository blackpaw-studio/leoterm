#!/usr/bin/env bash
# Plain-sh tests for version.sh, using a scratch git repo. Run directly:
#   ./test_version.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
script="$(cd .. && pwd)/version.sh"

pass=0
fail=0

repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test

commit() { git -C "$repo" commit -q --allow-empty -m "$1"; }

commit "main 1"
git -C "$repo" tag leo-v0.9.0
commit "main 2"
git -C "$repo" tag leo-v1.10.0 # higher than 1.9.0 under semver, not lexical sort
commit "main 3"
git -C "$repo" tag leo-v1.9.0
release_commit="$(git -C "$repo" rev-parse HEAD)"

# origin/main: actions/checkout leaves a real remote-tracking ref, so
# simulate that instead of relying on a local "main" branch.
git -C "$repo" update-ref refs/remotes/origin/main "$release_commit"

run() {
  # $1: RELEASE_TAG, extra env in $2 (space-separated NAME=value)
  # Exit status is the script's, not "cat"/"rm"'s -- callers rely on it.
  local ghout rc
  ghout="$(mktemp)"
  ( cd "$repo" && env RELEASE_TAG="$1" GITHUB_OUTPUT="$ghout" ${2:-} "$script" )
  rc=$?
  cat "$ghout"
  rm -f "$ghout"
  return "$rc"
}

check_dev_build() {
  local out short
  out="$(run "" 2>&1)" || { echo "FAIL: dev build should succeed (got: $out)"; fail=$((fail + 1)); return; }
  short="$(grep '^short_version=' <<<"$out" | cut -d= -f2)"
  # leo-v1.10.0 is the highest semver tag among 0.9.0/1.10.0/1.9.0; a lexical
  # sort would wrongly pick 1.9.0 (or describe would pick the nearest, 1.9.0).
  if [[ "$short" == "1.10.0" ]]; then
    echo "PASS: dev build's short_version is the highest semver tag (1.10.0), not describe's nearest or a lexical sort"
    pass=$((pass + 1))
  else
    echo "FAIL: dev build short_version='$short', expected 1.10.0"
    fail=$((fail + 1))
  fi
  if grep -q '^version=1\.10\.0-dev\.' <<<"$out"; then
    echo "PASS: dev build's version is a -dev. suffix off the last release, not baked into short_version"
    pass=$((pass + 1))
  else
    echo "FAIL: dev build version line unexpected: $(grep '^version=' <<<"$out")"
    fail=$((fail + 1))
  fi
}
check_dev_build

check_valid_release() {
  local out
  out="$(run "leo-v1.9.0" 2>&1)" || { echo "FAIL: release on an ancestor of origin/main should succeed (got: $out)"; fail=$((fail + 1)); return; }
  if grep -q '^short_version=1\.9\.0$' <<<"$out" && grep -q '^version=1\.9\.0$' <<<"$out"; then
    echo "PASS: release tag produces a strictly numeric version/short_version"
    pass=$((pass + 1))
  else
    echo "FAIL: release output unexpected: $out"
    fail=$((fail + 1))
  fi
}
check_valid_release

check_wrong_commit() {
  git -C "$repo" checkout -q main~1
  if run "leo-v1.9.0" >/dev/null 2>&1; then
    echo "FAIL: tag not pointing at HEAD should fail"
    fail=$((fail + 1))
  else
    echo "PASS: tag not pointing at the checked-out commit fails"
    pass=$((pass + 1))
  fi
  git -C "$repo" checkout -q main
}
check_wrong_commit

check_not_ancestor_of_main() {
  git -C "$repo" checkout -q -b side main~1
  commit "side 1"
  git -C "$repo" tag leo-v2.0.0
  if run "leo-v2.0.0" >/dev/null 2>&1; then
    echo "FAIL: tag not an ancestor of origin/main should fail"
    fail=$((fail + 1))
  else
    echo "PASS: tag whose commit isn't an ancestor of origin/main fails"
    pass=$((pass + 1))
  fi
  git -C "$repo" checkout -q main
}
check_not_ancestor_of_main

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
