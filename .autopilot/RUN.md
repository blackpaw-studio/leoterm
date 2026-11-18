Status: running
Started: 2026-11-18T02:17:23Z
Budget: 20 items, until 2026-11-18T14:17:23Z
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

Lane: B-324
  Branch: autopilot-lane/B-324
  Dispatched: 2026-11-18T02:20:50Z
  Base: 0d5f7905144bee64282629117d65a23a915c7063
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-431
  Branch: autopilot-lane/B-431
  Dispatched: 2026-11-18T02:20:50Z
  Base: 0d5f7905144bee64282629117d65a23a915c7063
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Progress:
- Preflight: no open bump/leo-* PR. main merged (2 LeoKit files). Inbox: 5 entries applied — B-431, B-432 bugs; 13 ideas promoted; 10 blocked items closed not reproducible (B-317 B-321 B-338 B-344 B-367 B-373 B-374 B-375 B-393 B-427); B-324 ready for a live move check; B-311 re-blocked (answer needs a hosted-CI run = push). No ready (next run) items. Stale B-426 block (landed 2e7220332, block said building) dropped.
- Pick: B-324 full (Mac UI shipped in leo-v0.28.0; needs live move verify + iOS check) and B-431 light bug (macOS CI hang in browser downloads tests) in parallel — independent footprints.
- Dispatched runners via leo_dispatch implement: B-324 d-50c4c1aa6949, B-431 d-6a406081d874.
