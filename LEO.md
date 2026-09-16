# Leo

Leo is a [Ghostty](https://github.com/ghostty-org/ghostty) fork for macOS with a native Agents sidebar for managing agents from the `leo` daemon. Agent attachments run as ordinary terminal tabs; Ghostty's terminal behavior remains intact.

The v2 design is in [`docs/superpowers/specs/2026-09-15-leo-v2-agent-manager.md`](docs/superpowers/specs/2026-09-15-leo-v2-agent-manager.md). Upstream Ghostty documentation is in [`README.md`](README.md).

## Build

Requires Zig **0.16.0** (the version pinned in `build.zig.zon`) and
Xcode 26.3. Check the compiler version before building:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer zig version
```

Build the required XCFramework, then build the app from `macos/`:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  zig build -Demit-xcframework=true -Demit-macos-app=false \
  -Demit-lib-vt=false
cd macos
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild build -project Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS,arch=arm64' \
  -packageAuthorizationProvider netrc -skipMacroValidation \
  -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ENABLE_HARDENED_RUNTIME=NO
```

## Running the Swift tests

From `macos/`, run the prebuilt unit-test target against the pinned Mac
destination:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  /opt/homebrew/bin/timeout 600 xcodebuild test-without-building \
  -project Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS,arch=arm64,id=00006040-001A10663400801C' \
  -derivedDataPath build/DD -skipUnavailableActions \
  -parallel-testing-enabled NO -only-testing:GhosttyTests
```

### Running tests when the Mac is locked

When Xcode reports the Mac is passcode protected, run the built test bundle
directly from `macos/` instead:

```bash
D=/Applications/Xcode-26.3.0.app/Contents/Developer
APP=$PWD/build/DD/Build/Products/Debug/Ghostty.app
/opt/homebrew/bin/timeout 300 env DEVELOPER_DIR=$D \
  DYLD_FRAMEWORK_PATH="$D/Platforms/MacOSX.platform/Developer/Library/Frameworks:$D/Library/Frameworks" \
  DYLD_LIBRARY_PATH="$D/Platforms/MacOSX.platform/Developer/usr/lib" \
  DYLD_INSERT_LIBRARIES="$D/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib" \
  XCInjectBundleInto="$APP/Contents/MacOS/ghostty" \
  "$APP/Contents/MacOS/ghostty" -XCTest All \
  "$APP/Contents/PlugIns/GhosttyTests.xctest" > /tmp/leo-tests.log 2>&1
```

This runner always makes `ConfigTests/errorsEmptyForValidConfig` fail because
its `-XCTest` arguments are interpreted as app CLI configuration; ignore that
one known artifact. An exit code of 124 means a test hung. Compare `◇ … started`
lines with passed or failed lines in `/tmp/leo-tests.log` to identify it.
