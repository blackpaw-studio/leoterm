# Leo macOS tests

## What runs in CI

Everything runs on a hosted macOS runner except tests that cannot. A test is host-only
only if it:

- needs Leo to be the active app with a key window, or real posted key/mouse events
  (`.requiresActiveHost`)
- needs a real SSH host (`LeoSSHEndToEnd.trait`)
- was observed to fail on hosted macos-26 because AppKit draws or measures differently
  and can't be made portable (gate that one test, with a one-line comment saying what differs)

Real Ghostty surfaces, child shells, and WKWebView are fine in CI. Prefer injection
(clock, screen frame, sheet presenter, defaults suite) over gating a test.

## `.hostOnly`

Tag a test or suite `.hostOnly` (`macos/Tests/Leo/LeoTestHostActivation.swift`) only under
the rule above. It runs only with `LEO_HOST_TESTS=1`. Use `.requiresActiveHost` when the
test also needs working key focus.

## Running

Host tier, local:

    LEO_HOST_TESTS=1 DERIVED_DATA=/tmp/dd DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer .github/scripts/leo/run-unit-tests.sh

Targeted (xcodebuild forwards `TEST_RUNNER_` variables to the test process):

    TEST_RUNNER_LEO_HOST_TESTS=1 xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/dd -skipMacroValidation CODE_SIGNING_ALLOWED=NO -only-testing:GhosttyTests/<Suite>

Without the variable, only the portable tier runs. CI logs skipped host tests by name.
The self-hosted `test-macos` job sets `LEO_HOST_TESTS=1`, so it runs the host tier.
