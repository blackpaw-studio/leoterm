# Verify

All commands run from the worktree `~/.leo/autopilot/leoterm`. Tested 2026-09-22.

## Prereqs (once per worktree)
The worktree needs the Zig-built xcframework. Symlink it from the main checkout,
or rebuild it if `src/` changed:
```
ln -s ~/.leo/agents/leoterm/macos/GhosttyKit.xcframework macos/GhosttyKit.xcframework
ln -s ~/.leo/agents/leoterm/zig-out zig-out
# If you edited src/ (Zig), replace the symlink with a real build:
#   rm macos/GhosttyKit.xcframework
#   DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
#     zig build -Demit-xcframework=true -Demit-macos-app=false
```
- Always use Xcode 26.3 (`DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`). The Xcode 26.5 SDK breaks Zig linking.
- Zig is 0.16.0 (`~/.local/bin/zig`).
- A stale xcframework causes Swift errors like `ghostty_clipboard_content_s has no member len`. To fix it, delete `macos/GhosttyKit.xcframework zig-out .zig-cache` and rebuild.

## Build + test (one script)
```
bash scratchpad/runtests.sh <label>     # scratchpad/ is untracked; copy from ~/.leo/agents/leoterm/scratchpad/runtests.sh
```
- Runs `build-for-testing` (Debug, unsigned, `-derivedDataPath macos/build/DD`), then runs the XCTest bundle inside the app. This also works when the console is locked.
- Then it runs `swiftlint lint --strict --quiet`.
- Logs go to `/tmp/leo-build-<label>.log` and `/tmp/leo-tests-<label>.log`.
- Baseline (2026-09-22, after B-001): 726 tests. The only failure is `ConfigTests/errorsEmptyForValidConfig`, which always fails under this runner; ignore it.
- Swiftlint is clean as of B-008 (2026-09-22). Any lint error is new.
- The `editingAnUnrelatedHostDoesNotReselect` and Observe small-frame flakes were fixed in B-008. Treat a recurrence as real.
- Don't run two suites' builds at once: `LeoObserveTests/activityClientDeliversSmallCompleteFrameImmediately` flakes.
- Zig tests, only if `src/` changed: `zig build test -Dtest-filter=<name>`.

## Isolated launch
- The app is `macos/build/DD/Build/Products/Debug/Leo.app`, bundle ID `studio.blackpaw.leo.macos.debug`.
  - Its UserDefaults are separate from release's (`studio.blackpaw.leo.macos`).
  - Evan's Leo runs on his laptop, not Dionysus.
```
open -n macos/build/DD/Build/Products/Debug/Leo.app
osascript -e 'tell application id "studio.blackpaw.leo.macos.debug" to quit'   # when done
```
- **Shared state warning:** the debug app talks to the REAL local daemon (`~/.leo/state/leo.sock`) and sees Evan's real agents.
  - Reading is fine. Never stop, restart, spawn, delete, or type into real agents.
  - Use only `autopilot-scratch` (create it with `leo`, delete it after).
  - Tunnel sockets under `~/.leo/state/leoterm/` are shared too.
- For attention/state UI, prefer fixture-driven tests over live daemon state.
- DEBUG attention fixture: `open -n --env LEO_ATTENTION_FIXTURE=<json file> Leo.app`. The file maps agent name → `{"state","revision"}`.
  - **Never trigger Jump (⌃⌥⌘J) or click rows while the fixture names real agents.** Jump attaches a tmux client to that agent and resizes its window (happened 2026-09-22 with `brand`). For Jump/click flows, name only `autopilot-scratch` in the fixture.
  - Quitting via AppleScript can hang on a confirm dialog while a tab is attached. Detach with `tmux -L leo detach-client -t <tty>`, then `kill` the debug pid.

## Drive key flows (Peekaboo bridge; ALWAYS pass --app)
```
PB_SOCK="$HOME/Library/Application Support/Peekaboo/bridge.sock"
APPID=studio.blackpaw.leo.macos.debug
peekaboo menu list  --app $APPID --bridge-socket "$PB_SOCK"
peekaboo menu click --app $APPID --path "Agents > Show Agents Sidebar" --bridge-socket "$PB_SOCK"   # ⌘⇧L
peekaboo click|type|press ... --app $APPID --bridge-socket "$PB_SOCK"
```
- "menu click dispatched but not verified" is normal. Confirm with a screenshot.
- The Agents menu has: New Agent… (⌘⇧A), Show Agents Sidebar (⌘⇧L).

## Screenshots
```
peekaboo see --no-elements --mode window --app $APPID \
  --bridge-socket "$PB_SOCK" --capture-engine cg --path .autopilot/shots/<name>.png
```
- Tested: an empty window and the sidebar listing real localhost agents.
- The window must be on screen and not minimized.
- Check the console is unlocked: `ioreg -n Root -d1 -a | grep -A1 IOConsoleLocked`.
- The window title reads "Ghostty". The menu bar name is "Leo[DEBUG]". Always target by bundle ID.

## Remote (SSH) flows
- No autopilot-owned remote host is configured.
- Verify SFTP/remote behaviour with tests against a local sshd or fake.
- Live remote verification needs a host Evan names. Until then, it's not visually verifiable.
