#!/usr/bin/env bash
# sparkle-key-check.sh must report WHY it could not read SUPublicEDKey: an
# invalid or unreadable Info.plist is a plist problem, not a key mismatch or a
# missing key (B-222; a hidden PlistBuddy parse error misled the leo-v0.7.0
# release diagnosis). Needs no network or Sparkle tooling: the seed is a fixed
# dummy, since a plist error must stop the check before any key math. Run:
#   ./test_sparkle-key-check-plist-errors.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# base64 of 32 zero bytes: a well-formed (if useless) Ed25519 seed.
seed="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

work="$(mktemp -d)"
cleanup() { chmod -R u+rw "$work" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

invalid_plist="$work/invalid.plist"
printf 'not a plist <<<\n' > "$invalid_plist"

unreadable_plist="$work/unreadable.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string not-the-right-key=" "$unreadable_plist" >/dev/null
chmod 000 "$unreadable_plist"

keyless_plist="$work/keyless.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Leo" "$keyless_plist" >/dev/null

mismatched_plist="$work/mismatched.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string not-the-right-key=" "$mismatched_plist" >/dev/null

pass=0
fail=0

# check DESC PLIST MUST_MATCH [MUST_NOT_MATCH]: the check must exit 1 with an
# ::error:: line matching MUST_MATCH (ERE) and no ::error:: line matching
# MUST_NOT_MATCH.
check() {
  local desc="$1" plist="$2" want="$3" unwanted="${4:-}"
  local out status errors
  out="$(SPARKLE_PRIVATE_KEY="$seed" PLIST="$plist" RUNNER_TEMP="$work" \
    ../sparkle-key-check.sh 2>&1)" && status=0 || status=$?
  errors="$(grep '^::error::' <<<"$out" || true)"
  if [[ "$status" -ne 1 ]]; then
    echo "FAIL: $desc (status $status, expected 1): $out"
    fail=$((fail + 1))
  elif ! grep -qE "$want" <<<"$errors"; then
    echo "FAIL: $desc (no ::error:: matching /$want/): $out"
    fail=$((fail + 1))
  elif [[ -n "$unwanted" ]] && grep -qE "$unwanted" <<<"$errors"; then
    echo "FAIL: $desc (::error:: matches /$unwanted/): $out"
    fail=$((fail + 1))
  else
    echo "PASS: $desc"
    pass=$((pass + 1))
  fi
}

misreport='does not match|SUPublicEDKey missing'

check "invalid plist surfaces the PlistBuddy parse error" \
  "$invalid_plist" 'Unexpected character' "$misreport"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: unreadable plist (root can read a mode-000 file)"
else
  check "unreadable plist is reported as unreadable" \
    "$unreadable_plist" 'not readable' "$misreport"
fi

check "plist without the key still reports it missing" \
  "$keyless_plist" 'SUPublicEDKey missing' 'does not match'

check "plist with the wrong key still reports a mismatch" \
  "$mismatched_plist" 'does not match' 'SUPublicEDKey missing'

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
