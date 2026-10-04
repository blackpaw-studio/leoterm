#!/bin/bash
# Build + run the Leo Swift test suite headlessly (works with a locked console).
# Usage: macos/scripts/leo-runtests.sh [label]   (from any checkout or lane root)
set -uo pipefail
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
cd "$(dirname "$0")/.." || exit 1
LABEL="${1:-run}"
LOG="/tmp/leo-tests-$LABEL.log"

echo "== build-for-testing =="
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc \
  -skipMacroValidation -derivedDataPath build/DD \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO \
  > "/tmp/leo-build-$LABEL.log" 2>&1
BUILD_RC=$?
if [ $BUILD_RC -ne 0 ]; then
  echo "BUILD FAILED (rc=$BUILD_RC). Errors:"
  grep -E "error:|warning: .*(deprecat)" "/tmp/leo-build-$LABEL.log" | head -40
  exit 1
fi
echo "build ok"

D="$DEVELOPER_DIR"; APP="$PWD/build/DD/Build/Products/Debug/Leo.app"
TEST_TIMEOUT="${LEO_TEST_TIMEOUT:-900}"  # a normal run takes ~95 s; loaded hosts (load 300+) need far longer (B-073)
timeout "$TEST_TIMEOUT" env DEVELOPER_DIR="$D" \
  DYLD_FRAMEWORK_PATH="$D/Platforms/MacOSX.platform/Developer/Library/Frameworks:$D/Library/Frameworks" \
  DYLD_LIBRARY_PATH="$D/Platforms/MacOSX.platform/Developer/usr/lib" \
  DYLD_INSERT_LIBRARIES="$D/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib" \
  XCInjectBundleInto="$APP/Contents/MacOS/Leo" \
  "$APP/Contents/MacOS/Leo" -XCTest All "$APP/Contents/PlugIns/GhosttyTests.xctest" > "$LOG" 2>&1
HOST_RC=$?
echo "== results =="
grep -E 'Test run with' "$LOG" | tail -3
# No Swift Testing summary means the host never finished the run: killed by
# the timeout (rc 124), crashed, or exited. Say so instead of looking green.
if ! grep -qE 'Test run with [0-9]+ tests' "$LOG"; then
  if [ $HOST_RC -eq 124 ]; then WHY="killed by the ${TEST_TIMEOUT}s timeout (LEO_TEST_TIMEOUT)"; else WHY="test host exited rc=$HOST_RC"; fi
  echo "!! RUN INCOMPLETE: no test summary in $LOG -- $WHY"
  echo "!! $(grep -cE 'Test .* (passed|failed) after' "$LOG") tests reported; last log lines:"
  tail -3 "$LOG" | cut -c1-200
  exit 2
fi
echo "-- failures (ConfigTests/errorsEmptyForValidConfig is an expected baseline failure) --"
grep -E '^✘ Test [^ ]+\(\) failed' "$LOG" | head -30
echo "== swiftlint =="
swiftlint lint --strict --quiet 2>&1 | head -30 || true
