#!/usr/bin/env bash
# Uses Sparkle's generate_keys (downloaded once, cached under $HOME/.cache)
# to mint a throwaway keypair and confirm sparkle-key-check.sh accepts a
# matching plist and rejects a mismatched one. Run directly:
#   ./test_sparkle-key-check.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

sparkle_version=2.9.6
cache="${HOME}/.cache/leo-sparkle-tools-${sparkle_version}"
if [[ ! -x "$cache/bin/generate_keys" ]]; then
  mkdir -p "$cache"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/sparkle.zip" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-for-Swift-Package-Manager.zip"
  unzip -q "$tmp/sparkle.zip" -d "$cache"
  rm -rf "$tmp"
fi
generate_keys="$cache/bin/generate_keys"

work="$(mktemp -d)"
account="leo-sparkle-check-test-$$-$RANDOM"
cleanup() { security delete-generic-password -a "$account" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

genkeys_out="$("$generate_keys" --account "$account" 2>&1)"
pub="$(grep -oE '[A-Za-z0-9+/]{40,}=*' <<<"$genkeys_out")"
"$generate_keys" --account "$account" -x "$work/seed.txt" >/dev/null
seed="$(cat "$work/seed.txt")"
security delete-generic-password -a "$account" >/dev/null 2>&1 || true

good_plist="$work/good.plist"
bad_plist="$work/bad.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $pub" "$good_plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string not-the-right-key=" "$bad_plist" >/dev/null

pass=0
fail=0
check() {
  local desc="$1" expected="$2" plist="$3"
  local status
  SPARKLE_PRIVATE_KEY="$seed" PLIST="$plist" RUNNER_TEMP="$work" ../sparkle-key-check.sh >/dev/null 2>&1 && status=0 || status=$?
  if [[ "$status" -eq "$expected" ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (status $status, expected $expected)"
    fail=$((fail + 1))
  fi
}

check "matching plist passes" 0 "$good_plist"
check "mismatched plist fails" 1 "$bad_plist"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
