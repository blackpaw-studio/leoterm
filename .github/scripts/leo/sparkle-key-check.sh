#!/usr/bin/env bash
# Derive the public key for SPARKLE_PRIVATE_KEY with pure Ed25519 math (no
# keychain, no Sparkle tooling) and confirm it matches SUPublicEDKey in
# Ghostty-Info.plist before anything signs with it.
# Env: SPARKLE_PRIVATE_KEY (base64 32-byte Ed25519 seed), PLIST (path to
#      Ghostty-Info.plist), RUNNER_TEMP (optional, for the scratch DER files).
set -euo pipefail

: "${SPARKLE_PRIVATE_KEY:?}" "${PLIST:?}"
[[ -f "$PLIST" ]] || { echo "::error::$PLIST not found" >&2; exit 1; }

expected="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
[[ -n "$expected" ]] || { echo "::error::SUPublicEDKey missing from $PLIST" >&2; exit 1; }

seed_hex="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | base64 -D 2>/dev/null | xxd -p | tr -d '\n')"
if [[ "${#seed_hex}" -ne 64 ]]; then
  echo "::error::SPARKLE_PRIVATE_KEY is not a 32-byte base64-encoded Ed25519 seed" >&2
  exit 1
fi

tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/leo-sparkle-check.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
umask 077
# A fixed 16-byte PKCS8 preamble precedes any raw Ed25519 seed (RFC 8410).
printf '302e020100300506032b657004220420%s' "$seed_hex" | xxd -r -p > "$tmp/priv.der"
openssl pkey -inform DER -in "$tmp/priv.der" -pubout -outform DER -out "$tmp/pub.der" 2>/dev/null
# A fixed 12-byte SubjectPublicKeyInfo preamble precedes the raw public key.
pub_hex="$(xxd -p "$tmp/pub.der" | tr -d '\n')"
derived="$(printf '%s' "${pub_hex:24}" | xxd -r -p | base64)"

if [[ "$derived" != "$expected" ]]; then
  echo "::error::SPARKLE_PRIVATE_KEY's derived public key does not match SUPublicEDKey in $PLIST. Rotate the key or fix the plist before signing." >&2
  exit 1
fi
echo "Sparkle key OK: matches SUPublicEDKey in $PLIST"
