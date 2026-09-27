#!/usr/bin/env bash
# Fail fast, before the long build, if the runner cannot use its signing
# material: the Developer ID identity and the notarytool keychain profile.
# Env: SIGN_IDENTITY, NOTARY_PROFILE.
set -euo pipefail

: "${SIGN_IDENTITY:?}" "${NOTARY_PROFILE:?}"
security list-keychains
security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" 2>&1 || true

if ! security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
  echo "::error::Signing identity not found in the runner's keychains"
  exit 1
fi

probe="$(mktemp -d "${RUNNER_TEMP:-/tmp}/leo-signprobe.XXXXXX")"
trap 'rm -rf "$probe"' EXIT
cp /usr/bin/true "$probe/probe"
if ! /usr/bin/codesign --force --options runtime --sign "$SIGN_IDENTITY" "$probe/probe"; then
  echo "::error::codesign cannot use the private key (locked keychain or key ACL). See docs/leo/ci.md."
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null; then
  echo "::error::notarytool keychain profile '$NOTARY_PROFILE' is unusable"
  exit 1
fi
echo "Signing material OK"
