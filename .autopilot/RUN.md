Status: finished
Started: 2026-10-06T19:42:48Z
Budget: 5 items, until 2026-10-07T07:42:48Z
Digested-through: 0
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-139
  Branch: autopilot-lane/B-139
  Base: de0da78fbb3a64e313ad9ebc92af87b37b2146b8
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 80777b07fcc0a4d302dfc74a65dc8d3b99f75836
  Dispatched: 2026-10-06T19:43:15Z

Lane: B-140
  Branch: autopilot-lane/B-140
  Base: c7f9dadd149c4c4074434be919621a4c2753f57c
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 8a96bd527eb8cbbd49393a605c6dd899e92b1544
  Dispatched: 2026-10-06T20:10:47Z
  Call: Reset Window Size also puts a sidebar the user dragged in this window back to the stored shared width — P1, AUTONOMY UX/layout
  Call: Passive window widening keeps the launch clamp (D-237 unchanged; D-361 exception only for explicit reset) — AUTONOMY bug fixes
  Call: A hidden or floor-collapsed sidebar is left alone on reset — AUTONOMY UX/layout
  Call: With a side pane open, the restore is capped so the terminal keeps its 300 pt floor (sidebar grows as far as room allows) rather than skipped — P1, D-361, D-036/D-058

Lane: B-141
  Branch: autopilot-lane/B-141
  Base: ae3ca762e4286c2c9d5b31d7084bef1861f89e21
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 44de87461ba44d65f1df0f363563a4e5bcc4a024
  Dispatched: 2026-10-06T21:16:10Z
  Call: Property injection (`var leoAppIsHidden: @MainActor () -> Bool = { NSApp.isHidden }`) instead of an init parameter, because many factories build controllers — AUTONOMY implementation approach
  Call: The name `leoAppIsHidden`, following the controller's leo* prefix — AUTONOMY naming
  Call: The tests go in the existing LeoLaunchPlaceholderIntegrationTests, on the real Ghostty.App — AUTONOMY test infrastructure

Lane: B-142
  Branch: autopilot-lane/B-142
  Base: 4c9407f6d67e563afbab8a6eca9f90139ef8dedc
  Tier: full
  State: landed
  Fixes: 2
  Wip: none
  Reverifies: 0
  Reviewed-tip: be6f60ff7d5c34ca89f927f91585f89c986bb979
  Dispatched: 2026-10-06T21:34:03Z
  Call: The untitled 500x500 window on folder-open is kept, not removed: it is macOS's own TUINSWindow (TextInputUIMacHelper caps-lock/input-source indicator) made once per process by -[NSTextInputContext activate]; removing it would break IME/dead keys or disable a macOS feature — P1, stop list (removing a user-facing feature)
  Call: The stray-window guard allows only that exact system class plus each window's own palette panel — AUTONOMY test infrastructure
  Call: Read-only paletteWindow accessors on LeoRuntime and LeoPickerPresentation so the test can tie each panel to its window — AUTONOMY test infrastructure
  Call: Folder-open window attribution: windows made synchronously during openFile are checked strictly; late windows from other suites' controllers/palettes or non-500x500 bare NSWindows count as foreign — AUTONOMY test infrastructure

Lane: B-143
  Branch: autopilot-lane/B-143
  Base: e23c0aa4232d0c0a670565289661884195ffae3e
  Tier: full
  State: held
  Fixes: 0
  Wip: a3fe1df0d
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-06T23:01:21Z

## Progress
- Board sync re-enabled at Evan's request (2026-10-06); full sync run.
- Lane B-233 is unlanded with no RUN.md block (left in place, not a pick).
- B-139 landed acf95b2b9: per-step clamp check + 1 pt tolerance; suite 2072/223 green, lint clean; no UI change. 3 polish items filed (B-240–B-242).
Finished 1: B-139 landed acf95b2b9cd3b48dc5aae28a19c6c7ff2471c036 · not visually verified
- B-140 landed 4bdcbc709: Reset/Return To Default Size restores the stored sidebar width (349→420 in GUI); 1 fix round (terminal floor with side pane); suite 2076 green. Polish B-243–B-245 filed.
Finished 2: B-140 landed 4bdcbc70940e9d9cfb22a97f702d02bdebae5f17 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-140-1.png
- B-141 landed d3bf3d087: isLeoWindowShown takes an injected leoAppIsHidden seam; 3 new tests; suite 2079 green; no UI change. Polish B-246 filed.
Finished 3: B-141 landed d3bf3d0873d63972cda0d199a35766fde7de28f4 · not visually verified
- B-142 landed cf35ba894: the 500x500 window is macOS's TUINSWindow (not Leo's, lldb-confirmed); kept, with a regression guard against any real stray window on folder-open; tests only, no production change; 2 fix rounds (hard implementer); suite 2084 green. Polish B-247–B-250 filed.
Finished 4: B-142 landed cf35ba894d21b6fee722ad240f68ed6d975b0391 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-142-1.png
- B-143 runner timed out after 3h (stopped 22:03 EDT, mid fix round 2 with the implementer). Verify lock released. Leftover edits committed as wip a3fe1df0d. Shelve refused (untracked macos/default.profraw + zig-out symlink in the lane; removing them was denied), so the lane is held on autopilot-lane/B-143. Its implementer may still be running in the lane.
Finished 5: B-143 blocked
