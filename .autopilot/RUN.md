Status: running
Started: 2026-11-17T14:04:05Z
Budget: 20 items, until 2026-11-18T02:04:05Z
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

Lane: B-305
  Branch: autopilot-lane/B-305
  Base: 25f86d23516a1cde24a21643f1cda05e20ba8bb1
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-419
  Branch: autopilot-lane/B-419
  Base: 25f86d23516a1cde24a21643f1cda05e20ba8bb1
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Progress:
- Preflight: no open bump/leo-* PR. main already merged. Inbox empty. Promoted B-419, B-420, B-421. Lanes B-233, B-332 unlanded with no block (left in place); B-368 landed lane (stale).
- Board sync: B-404: gh issue view: dial tcp 140.82.114.6:443: i/o timeout
- Pick: B-305 full (iOS executor, milestone 4; pick order lists it first); B-419 light bug (address field) in parallel — independent footprints (iOS app vs Mac browser pane). B-420 overlaps B-419 (address field); waits.
