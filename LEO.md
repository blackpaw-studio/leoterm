# Leo

A macOS terminal optimized for running multiple coding agents at once — an auto-arranging grid of agent cells — forked from [Ghostty](https://github.com/ghostty-org/ghostty).

- Design spec: [`docs/superpowers/specs/2026-06-08-leo-terminal-design.md`](docs/superpowers/specs/2026-06-08-leo-terminal-design.md)
- Phase 1 plan: [`docs/superpowers/plans/2026-06-08-leo-phase1-fork-baseline.md`](docs/superpowers/plans/2026-06-08-leo-phase1-fork-baseline.md)

Upstream README (full Ghostty docs): [`README.md`](README.md).

## Status

**Phase 1 (fork & baseline) complete.** Builds and runs as a Ghostty fork with the macOS app display name set to **Leo**; behavior is otherwise unmodified. The grid layout engine, tmux control-mode client, and Leo-daemon integration are subsequent phases (see the design spec).

## Requirements

- **Xcode 26.3** — *not* 26.5. Xcode 26.5's macOS SDK omits `arm64-macos` from ~494 of its `.tbd` files, which breaks Zig's bundled linker (codeberg ziglang issue [#31658](https://codeberg.org/ziglang/zig/issues/31658)). Xcode 26.3's SDK (26.2) is correct. Apple's own linker (used by `xcodebuild`) is unaffected, so only the `zig build` step needs 26.3 — but for a consistent toolchain, use it for everything.
- **Zig 0.15.2** (pinned by `build.zig.zon`). Install the exact version:
  ```bash
  curl -fsSL https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz -o /tmp/zig.tar.xz
  mkdir -p ~/.local/zig && tar -xf /tmp/zig.tar.xz -C ~/.local/zig --strip-components=1
  ln -sf ~/.local/zig/zig ~/.local/bin/zig   # ensure ~/.local/bin is on PATH
  ```
- macOS 26.x, tmux 3.x (for later phases).

## Build

Set the toolchain for every command:

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
```

**1. Build the Zig core (`GhosttyKit.xcframework`):**

```bash
zig build -Demit-xcframework=true
# Produces macos/GhosttyKit.xcframework (this can take several minutes).
```

**2. Build the macOS app:**

```bash
cd macos
xcodebuild -target Ghostty -configuration Debug -packageAuthorizationProvider netrc build
# Produces macos/build/Debug/Ghostty.app
```

> `-packageAuthorizationProvider netrc` avoids an indefinite hang when xcodebuild's Swift Package Manager tries to unlock the Keychain for the Sparkle artifact in a non-GUI/headless session. On a normal interactive login it is not required.

> `zig build` alone does **not** build the app bundle (`emit_macos_app` defaults to off). Use the two steps above, or `zig build -Demit-macos-app=true -Demit-xcframework=true`.

**3. Run:**

```bash
open macos/build/Debug/Ghostty.app   # menu bar / app switcher show "Leo[DEBUG]"
```

## Syncing with upstream Ghostty

Forked from upstream commit `69095e298ab88bb0eb5ba541f4c505f2c22d07f5`.

```bash
git fetch upstream
git merge upstream/main
```

Leo's new functionality lives in **new files**; edits to upstream files are kept surgical (Phase 1's only upstream edit is the app display name in `macos/Ghostty.xcodeproj/project.pbxproj`) to minimize merge conflicts.
