#!/bin/bash
# Build + run the Leo Swift test suite headlessly (works with a locked console).
# Usage: macos/scripts/leo-runtests.sh [label]   (from any checkout or lane root)
# Logs: /tmp/leo-build-<label>.log, /tmp/leo-tests-<label>.log.
# Sourcing this file only defines its functions (see test_leo-runtests.sh).
set -uo pipefail

readonly FAILURE_LIST_LIMIT=30

# Print the failed tests named in a Swift Testing log, one line each:
# plain `foo() failed after ...` and parameterized
# `foo(_:) with N test cases failed after ...` (B-114). Per-issue
# "recorded an issue" lines, suites, and the run summary are left out.
list_failures() {
  grep -E '^✘ Test [^ ]+\([^ ]*\)( with [0-9]+ test cases?)? failed after' "$1" \
    | head -"$FAILURE_LIST_LIMIT"
}

build_for_testing() {
  local build_log="$1"
  echo "== build-for-testing =="
  xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty \
    -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc \
    -skipMacroValidation -derivedDataPath build/DD \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO \
    > "$build_log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "BUILD FAILED (rc=$rc). Errors:"
    grep -E "error:|warning: .*(deprecat)" "$build_log" | head -40
    return 1
  fi
  echo "build ok"
}

main() {
  export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
  cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
  local label="${1:-run}"
  local log="/tmp/leo-tests-$label.log"

  build_for_testing "/tmp/leo-build-$label.log" || exit 1

  local D="$DEVELOPER_DIR" APP="$PWD/build/DD/Build/Products/Debug/Leo.app"
  local test_timeout="${LEO_TEST_TIMEOUT:-900}"  # a normal run takes ~95 s; loaded hosts (load 300+) need far longer (B-073)
  timeout "$test_timeout" env DEVELOPER_DIR="$D" \
    DYLD_FRAMEWORK_PATH="$D/Platforms/MacOSX.platform/Developer/Library/Frameworks:$D/Library/Frameworks" \
    DYLD_LIBRARY_PATH="$D/Platforms/MacOSX.platform/Developer/usr/lib" \
    DYLD_INSERT_LIBRARIES="$D/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib" \
    XCInjectBundleInto="$APP/Contents/MacOS/Leo" \
    "$APP/Contents/MacOS/Leo" -XCTest All "$APP/Contents/PlugIns/GhosttyTests.xctest" > "$log" 2>&1
  local host_rc=$?
  echo "== results =="
  grep -E 'Test run with' "$log" | tail -3
  # No Swift Testing summary means the host never finished the run: killed by
  # the timeout (rc 124), crashed, or exited. Say so instead of looking green.
  if ! grep -qE 'Test run with [0-9]+ tests' "$log"; then
    local why
    if [ $host_rc -eq 124 ]; then why="killed by the ${test_timeout}s timeout (LEO_TEST_TIMEOUT)"; else why="test host exited rc=$host_rc"; fi
    echo "!! RUN INCOMPLETE: no test summary in $log -- $why"
    echo "!! $(grep -cE 'Test .* (passed|failed) after' "$log") tests reported; last log lines:"
    tail -3 "$log" | cut -c1-200
    exit 2
  fi
  echo "-- failures --"
  list_failures "$log"
  echo "== swiftlint =="
  swiftlint lint --strict --quiet 2>&1 | head -30 || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
