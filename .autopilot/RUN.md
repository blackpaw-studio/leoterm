Status: running
Started: 2026-11-17T18:31:40Z
Budget: 20 items, until 2026-11-18T06:31:40Z
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

Lane: B-422
  Branch: autopilot-lane/B-422
  Dispatched: 2026-11-17T18:34:24Z
  Base: 8c72a4a605b90d57a55a36021ed847686a692b78
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-426
  Branch: autopilot-lane/B-426
  Dispatched: 2026-11-17T18:34:24Z
  Base: 8c72a4a605b90d57a55a36021ed847686a692b78
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Progress:
- Preflight: no open bump/leo-* PR. main already merged. Inbox empty. Promoted B-422, B-426, B-427. Lanes B-233, B-332 unlanded with no block (left in place); B-368 landed lane (stale).
- Pick: B-422 light bug (iOS test-host flake; the crash is in the test harness, not the product) and B-426 light bug (Mac address bar) in parallel — independent footprints. B-427 overlaps B-426 (Return commit in the pane); waits.
- Dispatched runners via leo_dispatch implement: B-422 d-757db1906f31, B-426 d-60cb459aa32c.
