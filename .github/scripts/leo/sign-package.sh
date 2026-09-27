#!/usr/bin/env bash
# Sign, package, notarize and staple Leo.app.
# Env: APP (path to Leo.app), SIGN_IDENTITY, NOTARY_PROFILE, OUT_DIR,
#      ENTITLEMENTS (path), DEVELOPER_DIR.
# Produces $OUT_DIR/Leo.dmg and $OUT_DIR/Leo-macos-universal.zip.
set -euo pipefail

: "${APP:?}" "${SIGN_IDENTITY:?}" "${NOTARY_PROFILE:?}" "${OUT_DIR:?}" "${ENTITLEMENTS:?}"
mkdir -p "$OUT_DIR"
dmg="$OUT_DIR/Leo.dmg"
zip="$OUT_DIR/Leo-macos-universal.zip"

sign() { /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }

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

echo "::group::create DMG"
staging="$(mktemp -d "${RUNNER_TEMP:-/tmp}/leo-dmg.XXXXXX")"
npx --yes create-dmg@8.1.0 --overwrite --no-version-in-filename \
  --identity="$SIGN_IDENTITY" "$APP" "$staging"
mv "$staging"/*.dmg "$dmg"
rm -rf "$staging"
/usr/bin/codesign --verify --verbose=2 "$dmg"
echo "::endgroup::"

echo "::group::notarize"
result="$(xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" \
  --wait --timeout 45m --output-format json)"
echo "$result"
status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
  id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || true)"
  [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
  echo "::error::Notarization status: ${status:-unknown}"
  exit 1
fi
xcrun stapler staple "$dmg"
xcrun stapler staple "$APP"
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
