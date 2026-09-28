#!/usr/bin/env bash
# The Sparkle public key must have exactly one source of truth:
# macos/Ghostty-Info.plist's SUPublicEDKey. build-app.sh used to re-stamp it
# from a separate SPARKLE_PUBLIC_KEY workflow constant, which could drift
# from the plist; sparkle-key-check.sh (exercised by
# test_sparkle-key-check.sh) is what derives/verifies the *private* key
# against that same plist. This test guards against either kind of
# duplicate constant creeping back in. Run directly:
#   ./test_sparkle-key-single-source.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

pass=0
fail=0

check() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo "FAIL: $desc (found '$pattern' in $file)"
    fail=$((fail + 1))
  else
    echo "PASS: $desc"
    pass=$((pass + 1))
  fi
}

check "build-app.sh does not require a SPARKLE_PUBLIC_KEY env var" \
  'SPARKLE_PUBLIC_KEY' ../build-app.sh
check "build-app.sh does not stamp SUPublicEDKey (Xcode already bakes in Ghostty-Info.plist's)" \
  'Set :SUPublicEDKey' ../build-app.sh
check "leo-build.yml does not define a separate SPARKLE_PUBLIC_KEY constant" \
  'SPARKLE_PUBLIC_KEY' ../../../workflows/leo-build.yml

echo "-- $pass passed, $fail failed --"
[[ "$fail" -eq 0 ]]
