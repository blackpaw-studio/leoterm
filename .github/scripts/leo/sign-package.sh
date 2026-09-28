#!/usr/bin/env bash
# Sign, package, notarize and staple Leo.app.
# Env: APP (path to Leo.app), SIGN_IDENTITY, OUT_DIR, ENTITLEMENTS (path),
#      DEVELOPER_DIR, LEO_KEYCHAIN (set by keychain.sh create),
#      APPLE_NOTARIZATION_KEY, APPLE_NOTARIZATION_KEY_ID, APPLE_NOTARIZATION_ISSUER.
# Produces $OUT_DIR/Leo.dmg and $OUT_DIR/Leo-macos-universal.zip.
set -euo pipefail

: "${APP:?}" "${SIGN_IDENTITY:?}" "${OUT_DIR:?}" "${ENTITLEMENTS:?}" "${LEO_KEYCHAIN:?}" \
  "${APPLE_NOTARIZATION_KEY:?}" "${APPLE_NOTARIZATION_KEY_ID:?}" "${APPLE_NOTARIZATION_ISSUER:?}"
mkdir -p "$OUT_DIR"
dmg="$OUT_DIR/Leo.dmg"
zip="$OUT_DIR/Leo-macos-universal.zip"

# --keychain: the identity only exists in the per-job keychain, and codesign
# needs to be told where to find it explicitly.
sign() { /usr/bin/codesign --force --timestamp --options runtime --keychain "$LEO_KEYCHAIN" --sign "$SIGN_IDENTITY" "$@"; }

echo "::group::codesign"
# Sparkle's helpers must be signed inside-out before the framework itself.
# The XPC services are unused (Leo is not sandboxed) but still shipped.
sparkle="$APP/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$APP/Contents/PlugIns/DockTilePlugin.plugin"
sign --entitlements "$ENTITLEMENTS" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
echo "::endgroup::"

# notarytool submit/staple share a key file and a status check; --keychain
# would be no help here since neither talks to a keychain.
notary_key="${RUNNER_TEMP:?}/leo-notary-key.p8"
printf '%s' "$APPLE_NOTARIZATION_KEY" > "$notary_key"
notary=(--key "$notary_key" --key-id "$APPLE_NOTARIZATION_KEY_ID" --issuer "$APPLE_NOTARIZATION_ISSUER")
notarize() {
  # $1: path to submit. $2: path to staple (defaults to $1; a .zip can be
  # submitted but not stapled, so the app case staples $APP instead).
  local submit="$1" staple="${2:-$1}" result status id
  result="$(xcrun notarytool submit "$submit" "${notary[@]}" --wait --timeout 45m --output-format json)"
  echo "$result"
  status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || true)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${notary[@]}" || true
    rm -f "$notary_key"
    echo "::error::Notarization status for $submit: ${status:-unknown}"
    exit 1
  fi
  xcrun stapler staple "$staple"
}

# The app must be stapled BEFORE it goes into the DMG, or the copy shipped
# inside the DMG is never stapled even though the standalone $APP is.
echo "::group::notarize app"
app_zip="$(mktemp -d "${RUNNER_TEMP:-/tmp}/leo-appzip.XXXXXX")/Leo.zip"
ditto -c -k --keepParent "$APP" "$app_zip"
notarize "$app_zip" "$APP"
rm -rf "$(dirname "$app_zip")"
echo "::endgroup::"

echo "::group::create DMG"
staging="$(mktemp -d "${RUNNER_TEMP:-/tmp}/leo-dmg.XXXXXX")"
# create-dmg cannot be pointed at a keychain, so sign the DMG here instead.
npx --yes create-dmg@8.1.0 --overwrite --no-version-in-filename --no-code-sign \
  "$APP" "$staging"
mv "$staging"/*.dmg "$dmg"
rm -rf "$staging"
/usr/bin/codesign --force --timestamp --keychain "$LEO_KEYCHAIN" --sign "$SIGN_IDENTITY" "$dmg"
/usr/bin/codesign --verify --verbose=2 "$dmg"
echo "::endgroup::"

echo "::group::notarize DMG"
notarize "$dmg"
rm -f "$notary_key"
echo "::endgroup::"

echo "::group::verify"
xcrun stapler validate "$dmg"
xcrun stapler validate "$APP"
spctl --assess --type open --context context:primary-signature -vv "$dmg"
spctl --assess --type execute -vv "$APP"
echo "::endgroup::"

# ditto keeps symlinks, xattrs and the stapled ticket intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$zip"
ls -l "$dmg" "$zip"
