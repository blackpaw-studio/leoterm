Status: running
Started: 2026-11-10T18:17:29Z
Budget: 20 items, until 2026-11-11T06:17:29Z
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

Lane: B-390
  Branch: autopilot-lane/B-390
  Base: a8da19c74da732d2a2a4034c49dfae1b653998f6
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-10T18:18:26Z

Lane: B-391
  Branch: autopilot-lane/B-391
  Base: a8da19c74da732d2a2a4034c49dfae1b653998f6
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-10T18:18:26Z

Progress:
- Preflight: main already merged; no new bump/leo-* PR (open #343/#337/#336 are older than 0.81.0); inbox applied: created B-390, B-391 (bugs).
- B-390 light (UX click-target move, D-766 supersedes D-745); B-391 full (async/queue concurrency). Independent: sidebar row vs browser bridge.
