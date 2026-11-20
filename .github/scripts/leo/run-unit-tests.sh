#!/usr/bin/env bash
# Build and run the GhosttyTests unit bundle (no UI tests).
#
# `xcodebuild test` hangs when the runner Mac's console is locked (Xcode
# treats the Mac as a passcode-protected device), so the bundle is injected
# into the host app directly instead. That injection makes the process see
# `-XCTest All <bundle>` on its own argv; Ghostty.Config.loadConfig skips CLI
# arg parsing whenever isRunningXCTest() is true specifically so that argv
# never reaches config parsing, so no test failures need to be tolerated here.
# Env: LEO_TEST_FILTER (optional, comma-separated Suite or Suite/test(); runs
# only those through `xcodebuild test-without-building -only-testing`, not the
# injected host), DERIVED_DATA, DEVELOPER_DIR, optional LEO_HOST_TESTS=1 (host tier). Optional LOG (default $RUNNER_TEMP/leo-tests.log).
set -euo pipefail

: "${DERIVED_DATA:?}" "${DEVELOPER_DIR:?}"
# Overall cap; a real hang is caught sooner by watch-stall.sh (no log growth for 240 s).
readonly TEST_TIMEOUT_SECONDS=1200
export TEST_TIMEOUT_SECONDS
log="${LOG:-${RUNNER_TEMP:-/tmp}/leo-tests.log}"
# Resolved before the cd below; BASH_SOURCE is relative when CI runs the script by path.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# Tells the workflow the DerivedData cache is worth saving even if tests fail.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "built=true" >> "$GITHUB_OUTPUT"; fi

# Host tier (real key focus, surfaces, WebKit): only an explicit LEO_HOST_TESTS=1
# turns it on. Passed explicitly so the test host sees exactly what is logged.
host_tests="${LEO_HOST_TESTS:-}"
if [[ "$host_tests" == "1" ]]; then echo "host tier: on"; else echo "host tier: off"; fi

D="$DEVELOPER_DIR"
app="$DERIVED_DATA/Build/Products/Debug/Leo.app"
hang="$log.hang"
rm -f "$hang"
set +e
if [[ -n "${LEO_TEST_FILTER:-}" ]]; then
  echo "test filter: $LEO_TEST_FILTER"
  only=()
  IFS=',' read -r -a filters <<<"$LEO_TEST_FILTER"
  for f in "${filters[@]}"; do
    f="${f// /}"
    [[ -n "$f" ]] || continue
    [[ "$f" == GhosttyTests/* ]] || f="GhosttyTests/$f"
    only+=("-only-testing:$f")
  done
  cmd=(env LEO_HOST_TESTS="$host_tests"
    xcodebuild test-without-building
    -project Ghostty.xcodeproj -scheme Ghostty
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$DERIVED_DATA"
    -skipMacroValidation
    "${only[@]}"
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO)
else
  cmd=(env
    LEO_HOST_TESTS="$host_tests"
    DYLD_FRAMEWORK_PATH="$D/Platforms/MacOSX.platform/Developer/Library/Frameworks:$D/Library/Frameworks"
    DYLD_LIBRARY_PATH="$D/Platforms/MacOSX.platform/Developer/usr/lib"
    DYLD_INSERT_LIBRARIES="$D/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib"
    XCInjectBundleInto="$app/Contents/MacOS/Leo"
    "$app/Contents/MacOS/Leo" -XCTest All "$app/Contents/PlugIns/GhosttyTests.xctest")
fi
timeout "$TEST_TIMEOUT_SECONDS" "${cmd[@]}" >"$log" 2>&1 &
host=$!
# A hung test ends the run only at the timeout and leaves no trace of where.
# Watch the log instead: once it stops growing for STALL_SECONDS, record the
# host's stacks and kill it, so the run fails fast with the evidence.
"$script_dir/watch-stall.sh" "$log" "$host" "$hang" &
watcher=$!
wait "$host"
rc=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
set -e
[[ -s "$hang" ]] && { echo "::group::Stall diagnostics"; head -c 200000 "$hang"; echo "::endgroup::"; }

"$script_dir/check-test-log.sh" "$log" "$rc"
