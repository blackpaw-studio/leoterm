#!/usr/bin/env bash
# Confirms sparkle-key-check.sh accepts a plist whose SUPublicEDKey matches
# the private key and rejects a mismatched one. Uses the RFC 8032 section 7.1
# TEST 1 Ed25519 vector as an independent oracle, so it needs no keychain
# (the CI runner's own security session can't write the login keychain) and
# no network. Run directly:
#   ./test_sparkle-key-check.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# RFC 8032 TEST 1: secret key 9d61b19d…ae7f60, public key d75a9801…07511a.
seed="nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
pub="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

good_plist="$work/good.plist"
bad_plist="$work/bad.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $pub" "$good_plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string not-the-right-key=" "$bad_plist" >/dev/null

pass=0
fail=0
check() {
  local desc="$1" expected="$2" plist="$3"
  local status out
  out="$(SPARKLE_PRIVATE_KEY="$seed" PLIST="$plist" RUNNER_TEMP="$work" ../sparkle-key-check.sh 2>&1)" && status=0 || status=$?
  if [[ "$status" -eq "$expected" ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (status $status, expected $expected): $out"
    fail=$((fail + 1))
  fi
}

check "matching plist passes" 0 "$good_plist"
check "mismatched plist fails" 1 "$bad_plist"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
