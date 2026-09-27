#!/usr/bin/env bash
# Build Leo.app (Release, unsigned) and stamp its Info.plist.
# Env: VERSION, BUILD, COMMIT, SPARKLE_PUBLIC_KEY, DERIVED_DATA, DEVELOPER_DIR.
# Prints nothing on stdout except the path of the built app on the last line.
set -euo pipefail

: "${VERSION:?}" "${BUILD:?}" "${COMMIT:?}" "${SPARKLE_PUBLIC_KEY:?}" "${DERIVED_DATA:?}"
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
pb "Set :CFBundleShortVersionString $VERSION"
pb "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY"
# Let Sparkle use its default (ask the user) instead of the dev-time "off".
pb "Delete :SUEnableAutomaticChecks" || true

echo "$app"
