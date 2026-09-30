#!/usr/bin/env bash
# Build Leo.app (Release, unsigned) and stamp its Info.plist.
# Env: VERSION, SHORT_VERSION, BUILD, COMMIT, DERIVED_DATA, DEVELOPER_DIR.
# VERSION feeds zig's -Dversion-string (may carry a "-dev.<sha>" suffix).
# SHORT_VERSION is the strictly numeric X.Y.Z that Apple requires for
# CFBundleShortVersionString; the dev/sha identity instead goes into the
# GhosttyCommit plist key below (an existing upstream Info.plist key).
# SUPublicEDKey is NOT set here: macos/Ghostty-Info.plist is its one source
# of truth, and Xcode already bakes that value into the built Info.plist.
# Re-stamping it from a separate workflow constant risked the two drifting;
# sparkle-key-check.sh (leo-release.yml) derives the expected *private* key
# check from the same plist, so there's a single source end to end.
# Prints nothing on stdout except the path of the built app on the last line.
set -euo pipefail

: "${VERSION:?}" "${SHORT_VERSION:?}" "${BUILD:?}" "${COMMIT:?}" "${DERIVED_DATA:?}"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# A stale xcframework from another Zig/branch breaks the Swift build.
rm -rf macos/GhosttyKit.xcframework zig-out

echo "::group::zig build (ReleaseFast)" >&2
zig build \
  -Doptimize=ReleaseFast \
  -Demit-macos-app=false \
  -Dversion-string="$VERSION" >&2
echo "::endgroup::" >&2

echo "::group::xcodebuild Release" >&2
(
  cd macos
  xcodebuild build \
    -project Ghostty.xcodeproj \
    -scheme Ghostty \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -packageAuthorizationProvider netrc \
    -skipMacroValidation \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO
) >&2
echo "::endgroup::" >&2

app="$DERIVED_DATA/Build/Products/Release/Leo.app"
plist="$app/Contents/Info.plist"
[[ -d "$app" ]] || { echo "::error::Leo.app not found at $app" >&2; exit 1; }

pb() { /usr/libexec/PlistBuddy -c "$1" "$plist" >&2; }
pb "Set :GhosttyCommit $COMMIT"
pb "Set :CFBundleVersion $BUILD"
pb "Set :CFBundleShortVersionString $SHORT_VERSION"
# Auto-update is on: Ghostty-Info.plist no longer sets SUEnableAutomaticChecks,
# and this script leaves Sparkle's keys alone (the feed URL and SUPublicEDKey
# stay as built). AppDelegate.ghosttyConfigDidChange applies the `auto-update`
# config (off/check/download) through UpdatePolicy; unset lets Sparkle ask the
# user once. See docs/leo/ci.md "Auto-update (on)".

echo "$app"
