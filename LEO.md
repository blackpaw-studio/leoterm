# Leo

Leo is a [Ghostty](https://github.com/ghostty-org/ghostty) fork for macOS with a native Agents sidebar for managing agents from the `leo` daemon. Agent attachments run as ordinary terminal tabs; Ghostty's terminal behavior remains intact.

The v2 design is in [`docs/superpowers/specs/2026-09-15-leo-v2-agent-manager.md`](docs/superpowers/specs/2026-09-15-leo-v2-agent-manager.md). Upstream Ghostty documentation is in [`README.md`](README.md).

## Build

Use the Zig version pinned in `build.zig.zon` and Xcode 26.3:

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build -Demit-macos-app=true -Demit-xcframework=true
```

Alternatively, build the app from `macos/` after building the xcframework:

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
zig build -Demit-xcframework=true
cd macos
xcodebuild build -project Ghostty.xcodeproj -scheme Ghostty \
  -destination 'platform=macOS,arch=arm64' \
  -packageAuthorizationProvider netrc -skipMacroValidation \
  -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ENABLE_HARDENED_RUNTIME=NO
```
