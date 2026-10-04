#!/usr/bin/env bash
# macos/Ghostty-Info.plist is read raw, not through Xcode, by CI:
# sparkle-key-check.sh (leo-release.yml) PlistBuddy-reads its SUPublicEDKey
# to verify the signing key. So the SOURCE plist must stay a valid plist on
# its own: no C-preprocessor directives (#ifdef etc.), which Xcode's
# INFOPLIST_PREPROCESS tolerates but plutil/PlistBuddy reject. Per-config
# values belong in build settings, referenced as $(SETTING). Run directly:
#   ./test_info-plist-valid.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

plist=../../../../macos/Ghostty-Info.plist
pass=0
fail=0

result() {
  local ok="$1" desc="$2" detail="$3"
  if [[ "$ok" == yes ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc ($detail)"
    fail=$((fail + 1))
  fi
}

lint_out="$(plutil -lint "$plist" 2>&1)" && lint_ok=yes || lint_ok=no
result "$lint_ok" "plutil -lint accepts Ghostty-Info.plist" "$lint_out"

directives="$(grep -nE '^[[:space:]]*#[[:space:]]*(if|ifdef|ifndef|else|elif|endif|define|include)' "$plist" || true)"
[[ -z "$directives" ]] && no_cpp=yes || no_cpp=no
result "$no_cpp" "Ghostty-Info.plist has no preprocessor directives" "$directives"

# The key as written in the XML, read without a plist parser, so the check
# below compares PlistBuddy against the file rather than a second copy.
raw_key="$(grep -A1 '<key>SUPublicEDKey</key>' "$plist" | sed -nE 's#.*<string>([^<]*)</string>.*#\1#p')"
pb_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>&1)" || true
[[ -n "$raw_key" && "$pb_key" == "$raw_key" ]] && key_ok=yes || key_ok=no
result "$key_ok" "PlistBuddy reads SUPublicEDKey as written" "got '$pb_key', want '$raw_key'"

[[ "$pb_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] && shape_ok=yes || shape_ok=no
result "$shape_ok" "SUPublicEDKey is a base64 Ed25519 public key" "got '$pb_key'"

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
