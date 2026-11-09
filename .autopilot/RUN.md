Status: finished
Started: 2026-11-09T14:10:19Z
Budget: 2 items, until 2026-11-10T02:10:19Z
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
  Tokens: 60.9M in (60.1M cache read), ≥192k out, 352 requests
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-373
  Branch: autopilot-lane/B-373
  Base: 62032c9376e2f9563385fb3928ba8fe20c17607d
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-09T14:12:00Z
  Tokens: 7.89M in (7.69M cache read), ≥30.7k out, 75 requests

Lane: B-374
  Branch: autopilot-lane/B-374
  Base: 62032c9376e2f9563385fb3928ba8fe20c17607d
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-09T14:12:00Z
  Tokens: 3.91M in (3.75M cache read), ≥21.2k out, 40 requests

Finished 1: B-374 blocked
Finished 2: B-373 blocked

Progress:
- B-373 and B-374 built before B-368 (owner's fresh reports this morning; 2-item cap).
- Preflight: local main is stale (ab72de1f0); merged origin/main 487d73a33 (leo-v0.32.0 release merge) into autopilot.
- Inbox applied: created B-373, B-374 (bugs); B-368 promoted.
- B-374 blocked: runner could not reproduce (no GUI repro; load >40); suspects a late focus report via receiveAttachLinks → selectFocusedRow. Shelved to autopilot-shelved/B-374 (no commits).
- B-373 blocked: reproducing test (toolbar.visibleItems contains .leoUpdate, 92 width/layout cases) never failed; harness lacks real capsule/reset-zoom/macOS 26 chrome. Lead: Chat-beside-terminal far-side reserve (56) too small. Shelved to autopilot-shelved/B-373 (no commits).
