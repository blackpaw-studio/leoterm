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

summary="$(grep -E 'Test run with [0-9]+ tests' "$log" | tail -1 || true)"
echo "${summary:-no test summary found}"
if [[ $rc -eq 124 ]]; then
  echo "::error::Test run timed out after ${TEST_TIMEOUT_SECONDS}s"
  grep -E '◇ Test .* started' "$log" | tail -5 || true
  exit 1
fi
if [[ -z "$summary" ]]; then
  tail -40 "$log"
  echo "::error::Test runner exited ($rc) without a summary"
  exit 1
fi
if [[ $rc -ne 0 ]]; then
  grep -E '^✘' "$log" | head -60
  echo "::error::Test runner exited with status $rc"
  exit 1
fi

failed="$(grep -E '^✘ Test ' "$log" || true)"
if [[ -n "$failed" ]]; then
  echo "$failed" | head -60
  echo "::error::Test failures reported despite a zero exit status"
  exit 1
fi
echo "All tests passed"
