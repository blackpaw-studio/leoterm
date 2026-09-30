# Verify
Parallel builds: no — two concurrent `runtests.sh` test hosts (both are GUI copies of the debug app) break `GhosttyAttachTabHostFocusTests/focusReportsArriveViewingFirstAndTheSidebarOnlyClearsFocus` on one side (likely key-window/app-activation contention between the two apps). Builds, sockets, prefs and /tmp state don't collide as long as each lane passes its own `<label>` (the default `run` shares the log paths).
Evidence (2026-09-28, two temp worktrees at a8d9e29a5, labels par-a*/par-b*, host load avg 25-78 from other projects): solo 1566/1566 green, 179 s fresh (86 s tests); 5 concurrent pairs, all builds OK: fresh+incremental and fresh+fresh pairs both green (176/253 s); 3 of 3 incremental pairs (tests fully overlapping) had exactly one side fail that focus test (21 s timeout); it passed in 3 of 3 solo runs, including one at load 78 (a solo run did flake `nonAttachSurfaceKeepsGhosttysTitle` once). Peak combined test-host RSS ~1.4 GB; nothing leaked to /tmp, the cache dir, `~/.leo/state/leoterm` or Preferences.

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
- **Post-B-072 xcframework:** B-072 changed `src/global.zig`; the main checkout's xcframework (2026-09-20) predates it. Symlink the autopilot-built copy instead: `ln -s ~/.leo/agents/leoterm/.git/autopilot/shared/GhosttyKit.xcframework macos/GhosttyKit.xcframework` and `ln -s ~/.leo/agents/leoterm/.git/autopilot/shared/zig-out zig-out` (built from autopilot at B-072), or build one in the lane. Before building, `unlink zig-out macos/GhosttyKit.xcframework`: never build through a zig-out symlink into the main checkout. After any `src/` commit, rebuild before claiming green: `ghostty-internal.a` must be newer than the last `src/` commit.
- Always use Xcode 26.3 (`DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`). The Xcode 26.5 SDK breaks Zig linking.
- Zig is 0.16.0 (`~/.local/bin/zig`).
- A stale xcframework causes Swift errors like `ghostty_clipboard_content_s has no member len`. To fix it, delete `macos/GhosttyKit.xcframework zig-out .zig-cache` and rebuild.

## Build + test (one script)
```
bash scratchpad/runtests.sh <label>     # scratchpad/ is untracked; copy from ~/.leo/agents/leoterm/scratchpad/runtests.sh
```
- **Test-host environ crash fixed (B-072, 2026-09-30):** plain `bash scratchpad/runtests.sh <label>` runs green with no env-var wrapper. libghostty's `syncEnviron()` now copies the environment instead of pointing into libc's `environ`, which a test's `setenv` could free under the next new surface. `LeoEnvironSnapshotTests` guards it. With a pre-B-072 xcframework the plain runner still crashes the host (the old `LANG=… __CF_USER_TEXT_ENCODING=… __LLVM_PROFILE_RT_INIT_ONCE=…` prefix is only a stopgap).
- Copy `scratchpad/runtests.sh` from the autopilot worktree (`~/.leo/agents/leoterm/.git/autopilot/worktree/scratchpad/runtests.sh`), not Evan's checkout: only that copy has D-057's "RUN INCOMPLETE"/LEO_TEST_TIMEOUT check.
- GUI tip (B-057, corrected by B-067/B-077): the sidebar search filter hides the Terminals section by design. AX set-value on the search field changes its text but NOT the filter; to filter or clear it, use Agents ▸ Find Agent… (menu click), then `peekaboo type` / `peekaboo press delete` (debug app frontmost). Menu clicks (File ▸ New Terminal, File ▸ Close) need no key presses.
- Runs `build-for-testing` (Debug, unsigned, `-derivedDataPath macos/build/DD`), then runs the XCTest bundle inside the app. This also works when the console is locked.
- Then it runs `swiftlint lint --strict --quiet`.
- Logs go to `/tmp/leo-build-<label>.log` and `/tmp/leo-tests-<label>.log`.
- Baseline (2026-09-22, after B-001): 726 tests. `ConfigTests/errorsEmptyForValidConfig` passed in every run on 2026-09-30; treat a failure as real.
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
- Evan approved type/press/click on the debug bundle for verification (D-052). Check the frontmost app first.
- "menu click dispatched but not verified" is normal. Confirm with a screenshot.
- The Agents menu has: New Agent… (⌘⇧A), Show Agents Sidebar (⌘⇧L), Find Agent… (⌥⌘F).
- The agent palette is Choose Agent… (⌘O; menu click on it). File ▸ New Terminal (⌘T) makes a plain shell row; ⌘D / File ▸ Split Right also open the palette (click Plain Shell for a shell split; never press Return there). It's its own panel window: find its id with `peekaboo window list --app $APPID --json` and capture with `see --window-id <id>`. Type into it with `peekaboo type <text> --foreground --app $APPID --window-id <id>` (the debug app must already be frontmost). Never press Return there with real agents listed.
- `LEO_FORCE_DISCONNECTED=1` (DEBUG, `open -n --env`) forces the disconnected state after the first list.
- Quitting via AppleScript can hang; `pkill -f` the debug binary path instead.

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

## Editor close/save alerts (B-035, 2026-09-24)
- `open -n --env LEO_OPEN_FILE=<scratch file> --env LEO_SLOW_SAVE_SECONDS=30 Leo.app` opens the file in the editor pane with every save held 30 s.
- Type with `peekaboo type <text> --foreground --app $APPID --window-id <main window id>`.
- File ▸ Close (menu click) shows the "Do you want to save…" alert as its own pixels-only window (no AX element): capture it with `see --window-id <alert id>` (ignore the AX error; the PNG is written).
- To answer it: check the debug app is frontmost, then `peekaboo press return --foreground --bridge-socket "$PB_SOCK"` (global, no `--app`; `--app`/`--window-id` fail with axElementNotFound). Return = Save.
- Capture within the hold to see the `Closing “…”…` banner. File ▸ Save via menu click does save (held, so "Edited" stays until it lands).


## Sidebar row clicks (B-048, 2026-09-28)
- **Filter first.** Rows re-sort live by Last Activity, so a real agent can slide under the cursor between a capture and a click. Before any row click, run Agents ▸ Find Agent… (menu click) and type `autopilot-scratch` so it's the only row.
- Plain and double clicks: `peekaboo click --at <x,y> [--double] --foreground --app $APPID --window-id <id>` (window-relative coordinates).
- Modifier clicks need a snapshot and GLOBAL coordinates: `peekaboo see --mode window ... --json` → `snapshot_id`, then `peekaboo click --snapshot <id> --at <globalX,globalY> --modifiers cmd --foreground`. Delivery is unreliable (a "cursor restoration" warning, and sometimes the click never lands), so treat a ⌘-click result as inconclusive and rely on `LeoSidebarCommandClickTests`.
- CGEvents posted from this shell don't reach the app (no Accessibility permission).
- Count attaches with `tmux -L leo list-clients | grep scratch`. Before quitting, detach the scratch clients.
