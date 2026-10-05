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
# The seed is base64 of the raw 32-byte secret, the same format Sparkle's
# `generate_keys -x` exports (and the SPARKLE_PRIVATE_KEY secret holds).
seed="nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
pub="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
# RFC 8032 TEST 2's public key: valid, but not TEST 1's.
other_pub="PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw="

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

good_plist="$work/good.plist"
bad_plist="$work/bad.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $pub" "$good_plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $other_pub" "$bad_plist" >/dev/null

pass=0
fail=0
check() {
  local desc="$1" expected="$2" plist="$3" want="${4:-}"
  local status out
  out="$(SPARKLE_PRIVATE_KEY="$seed" PLIST="$plist" RUNNER_TEMP="$work" ../sparkle-key-check.sh 2>&1)" && status=0 || status=$?
  if [[ "$status" -eq "$expected" && "$out" == *"$want"* ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (status $status, expected $expected): $out"
    fail=$((fail + 1))
  fi
}

check "matching plist passes" 0 "$good_plist"
check "mismatched plist fails as a mismatch" 1 "$bad_plist" "does not match SUPublicEDKey"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
