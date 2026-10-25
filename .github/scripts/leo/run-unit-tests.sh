#!/usr/bin/env bash
# Build and run the GhosttyTests unit bundle (no UI tests).
#
# `xcodebuild test` hangs when the runner Mac's console is locked (Xcode
# treats the Mac as a passcode-protected device), so the bundle is injected
# into the host app directly instead. That injection makes the process see
# `-XCTest All <bundle>` on its own argv; Ghostty.Config.loadConfig skips CLI
# arg parsing whenever isRunningXCTest() is true specifically so that argv
# never reaches config parsing, so no test failures need to be tolerated here.
# Env: DERIVED_DATA, DEVELOPER_DIR. Optional LOG (default $RUNNER_TEMP/leo-tests.log).
set -euo pipefail

: "${DERIVED_DATA:?}" "${DEVELOPER_DIR:?}"
readonly TEST_TIMEOUT_SECONDS=900
export TEST_TIMEOUT_SECONDS
log="${LOG:-${RUNNER_TEMP:-/tmp}/leo-tests.log}"
cd "$(git rev-parse --show-toplevel)/macos"

echo "::group::build-for-testing"
xcodebuild build-for-testing \
  -project Ghostty.xcodeproj \
  -scheme Ghostty \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -packageAuthorizationProvider netrc \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO
echo "::endgroup::"

D="$DEVELOPER_DIR"
app="$DERIVED_DATA/Build/Products/Debug/Leo.app"
set +e
timeout "$TEST_TIMEOUT_SECONDS" env \
  DYLD_FRAMEWORK_PATH="$D/Platforms/MacOSX.platform/Developer/Library/Frameworks:$D/Library/Frameworks" \
  DYLD_LIBRARY_PATH="$D/Platforms/MacOSX.platform/Developer/usr/lib" \
  DYLD_INSERT_LIBRARIES="$D/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib" \
  XCInjectBundleInto="$app/Contents/MacOS/Leo" \
  "$app/Contents/MacOS/Leo" -XCTest All "$app/Contents/PlugIns/GhosttyTests.xctest" \
  >"$log" 2>&1
rc=$?
set -e

"$(dirname "${BASH_SOURCE[0]}")/check-test-log.sh" "$log" "$rc"
