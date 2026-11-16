Status: running
Started: 2026-11-16T01:25:55Z
Budget: 20 items, until 2026-11-16T13:25:55Z
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

Lane: B-403
  Branch: autopilot-lane/B-403
  Base: 047e03a3a248b9b961d97b8caf17a538a1782f84
  Tier: light
  Tokens: 4.73M in (4.49M cache read), ≥17k out, 59 requests
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: ff33b26984d18b0fea0506ee2fdb628f03604f85
  Dispatched: 2026-11-16T01:26:24Z
  Call: Rebuilt the stale shared xcframework inside the lane per verify.md (gitignored); moved macos/build aside to scratchpad instead of deleting it — verify.md

Finished 1: B-403 landed eb013d44f · not visually verified

Progress:
- Preflight: main already merged; queued open bump PR #376 (leo 0.84.0) → B-403. Lanes B-233, B-332 unlanded with no block (left in place); B-368 landed lane, dirty worktree (finish skips it).
- Pick: B-403 light (version bump, merge PR head unchanged; same as B-399).
- B-403 landed eb013d44f (b28f6ea2e, PR #376 head unchanged). D-821. ≈$1.77 est.
