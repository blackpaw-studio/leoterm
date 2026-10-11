Status: running
Started: 2026-10-11T00:41:25Z
Budget: 3 items, until 2026-10-11T12:41:25Z
Digested-through: 0
Filed: 0/3 bugs, 0/5 ideas
Untracked-left: default.profraw scratchpad/

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

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

Lane: B-287
  Branch: autopilot-lane/B-287
  Base: fdfa10d09c651135354ed96fc4633794e7af1ec8
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: db524cb881ed7c1b26ee95d40cfe7b81db5867f3
  Dispatched: 2026-10-11T00:45:00Z
  Call: Sidebar Return is matched by key code (36/76, no modifiers) in a new AppKit view, not in Ghostty's SurfaceView — P1
  Call: Test harness activates the app and waits up to 5 s for key status — P1
  Call: First-attach sizing tests set sidebarVisible explicitly instead of reading the real debug-bundle defaults — hermetic tests, no user-visible change

Lane: B-288
  Branch: autopilot-lane/B-288
  Base: 91bb68eb2a6b6ddea558a081ffc985b1cd1599a8
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-11T03:37:00Z

Finished 1: B-287 landed 2cacc795d · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-287-1.png

## Progress
- Preflight: main fast-forwarded into autopilot (fdc2619ad); applied 2 inbox entries (B-287, B-288 bugs added); B-284, B-285 promoted to ready.
- Evan (20:42 EDT): budget raised to 3 items.
- B-287 runner dispatched: d-655c97ca88ac (tier full).
- leoterm-ios (22:28 EDT): its LeoKit run shared the debug defaults domain and ran `defaults delete` ~21:30–22:25 EDT; B-287 window-size/sidebar test failures in that window may be interference — re-run before treating as signal.
- B-287 runner reported ready (1 fix round: pre-existing LeoFirstAttachWindowSizeTests flake from real debug defaults, fixed hermetically). Runner's first implement.hard d-5d1830a7959d lost its turn; retried once with d-12c0844d948c, which finished — treated as recovered, not a failed dispatch. Agent-pane ⌃C covered by tests only.
- B-287 landed 2cacc795d (full, hard; suite 2599/2599).
- B-288 picked, tier light (Evan: small bugs shouldn't take full-tier time).
