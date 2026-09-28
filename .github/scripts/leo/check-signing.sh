#!/usr/bin/env bash
# Fail fast, before the long build, if this job's secrets cannot produce a
# usable signing identity and notarization credentials.
# Env: SIGN_IDENTITY, LEO_KEYCHAIN (set by keychain.sh create),
#      APPLE_NOTARIZATION_KEY, APPLE_NOTARIZATION_KEY_ID, APPLE_NOTARIZATION_ISSUER.
set -euo pipefail
umask 077

: "${SIGN_IDENTITY:?}" "${LEO_KEYCHAIN:?}" "${APPLE_NOTARIZATION_KEY:?}" \
  "${APPLE_NOTARIZATION_KEY_ID:?}" "${APPLE_NOTARIZATION_ISSUER:?}"
security show-keychain-info "$LEO_KEYCHAIN"

if ! security find-identity -v -p codesigning "$LEO_KEYCHAIN" | grep -qF "\"$SIGN_IDENTITY\""; then
  echo "::error::Signing identity not found in $LEO_KEYCHAIN. Check the MACOS_CERTIFICATE/MACOS_CERTIFICATE_PWD secrets."
  exit 1
fi

# Both the codesign probe app and the notary key file are throwaway secrets
# for this step only; one per-job temp dir, one trap.
workdir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/leo-checksign.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

cp /usr/bin/true "$workdir/probe"
if ! /usr/bin/codesign --force --options runtime --keychain "$LEO_KEYCHAIN" --sign "$SIGN_IDENTITY" "$workdir/probe"; then
  echo "::error::codesign cannot use the private key from $LEO_KEYCHAIN. See docs/leo/ci.md."
  exit 1
fi

key="$workdir/leo-notary-key.p8"
printf '%s' "$APPLE_NOTARIZATION_KEY" > "$key"
if ! xcrun notarytool history --key "$key" --key-id "$APPLE_NOTARIZATION_KEY_ID" --issuer "$APPLE_NOTARIZATION_ISSUER" >/dev/null; then
  echo "::error::notarytool cannot authenticate with APPLE_NOTARIZATION_KEY/APPLE_NOTARIZATION_KEY_ID/APPLE_NOTARIZATION_ISSUER. If this looks like a team or authorization mismatch between the Developer ID (52M9C6892K) and the notarization key's team, stop: this needs a matching App Store Connect API key, not a retry."
  exit 1
fi
echo "Signing material OK"
