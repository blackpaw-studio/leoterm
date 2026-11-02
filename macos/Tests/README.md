# Leo macOS tests

## Portable rule

A test is portable if it runs on a hosted macOS runner with no display session. It must not need:

- a window server or a key window (focus, first responder, real `makeKeyAndOrderFront`)
- real event delivery (synthesized key or mouse events)
- a real Ghostty surface or child process
- real sockets, tmux, or ssh
- the keychain or `UserDefaults.standard`
- wall-clock waits that an injected clock could drive

Prefer injection (clock, screen frame, sheet presenter, defaults suite) over marking a test host-only.

## `.hostOnly`

When the behavior under test is the real host, tag the test or suite `.hostOnly`
(`macos/Tests/Leo/LeoTestHostActivation.swift`). It runs only with `LEO_HOST_TESTS=1`.
Use `.requiresActiveHost` when the test also needs working key focus.

## Running

Host tier, local:

    LEO_HOST_TESTS=1 DERIVED_DATA=/tmp/dd DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer .github/scripts/leo/run-unit-tests.sh

Targeted (xcodebuild forwards `TEST_RUNNER_` variables to the test process):

    TEST_RUNNER_LEO_HOST_TESTS=1 xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/dd -skipMacroValidation CODE_SIGNING_ALLOWED=NO -only-testing:GhosttyTests/<Suite>

Without the variable, only the portable tier runs. CI logs skipped host tests by name.
The self-hosted `test-macos` job sets `LEO_HOST_TESTS=1`, so it runs the host tier.
