Status: running
Started: 2026-11-15T17:40:19Z
Budget: 20 items, until 2026-11-16T05:40:19Z
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

Lane: B-401
  Branch: autopilot-lane/B-401
  Base: 6e36bc17a570c92535f5873bb4416bc82a605f0d
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-15T17:42:58Z
  Call: No client-side cache or restore of `finished`; the agent JSON has no per-instance id that survives a daemon restart — P2
  Call: Restore only at-rest states; `working` comes back as `unknown` — P2
  Call: Key the persisted attention record by name and attention token, so a recreated agent inherits nothing — P2
  Call: The fix lives in the daemon, so Mac and iOS get it with no app code. The app side adds pin tests only, in LeoKit, the Mac feed and the iOS model — P3, repo Mac/iOS rule, D-789

Lane: B-402
  Branch: autopilot-lane/B-402
  Base: 6e36bc17a570c92535f5873bb4416bc82a605f0d
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-15T17:42:58Z

Progress:
- Preflight: main merged (ff to 23b935963: leo 0.83.0 bump, Markdown test fix); no open bump/leo-* PR to queue; inbox applied: B-401 bug, B-402 add. Lanes B-233, B-332 unlanded with no RUN.md block (left in place); B-368 landed lane awaits finish.
- Picks: B-401 full (bug; report is about restoring sidebar state across relaunch = persistence), B-402 light (status tab header copy-level change). Independent footprints, parallel.
- Runners: B-401 d-ef048aaa88f1, B-402 d-43c07bf975ed (leo implement role).
