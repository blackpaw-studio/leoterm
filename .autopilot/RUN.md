Status: running
Started: 2026-11-06T17:47:04Z
Budget: 20 items, until 2026-11-07T05:47:04Z
Digested-through: 0
Filed: 1/3 bugs, 4/5 ideas
Self-filed: B-349 → B-358 bug — Reset-zoom titlebar accessory likely sits low in the unified toolbar
Self-filed: B-349 → B-359 idea — Show the update pill in the toolbar's » overflow menu at narrow widths
Self-filed: B-349 → B-360 idea — Update popover shows a blank "Version:" line
Self-filed: B-353 → B-361 idea — Activity capsule title truncates at moderate window widths
Self-filed: B-354 → B-362 idea — Done task bar is thin and low-contrast in light mode
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

Lane: B-349
  Branch: autopilot-lane/B-349
  Base: b8bcdffc772a88b2ba44273bfcebf5e8dc35228e
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Dispatched: 2026-11-06T17:47:53Z
  Reverifies: 0
  Tokens: 19.5M in (18.8M cache read), ≥108k out, 185 requests
  Reviewed-tip: 0df90da27212820f6a1534348953c7ae5a4260ba
  Call: Pill moves from a titlebar accessory to a native trailing toolbar item (.leoUpdate), left of "⋯"; corner overlay stays off for agent windows — P1
  Call: Narrow-width give-way order: subtitle, then pill, then title, then "⋯"; "Check for Updates…" stays in the app menu — P2
  Call: Mac only; iOS has no Sparkle pill
  Call: Pill width is measured (fittingSize + 10, 200 fallback) and re-measured on every state change
  Call: DEBUG-only LEO_UPDATE_FIXTURE env seam (compiled out of release) and LeoAgentToolbar.hidesItemsInPlace test seam

Lane: B-353
  Branch: autopilot-lane/B-353
  Base: 6febf7a1a55c82d5cb525a1ae72198593b1151d4
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-06T18:57:33Z
  Reverifies: 0
  Tokens: 7.4M in (7.11M cache read), ≥41.5k out, 84 requests
  Reviewed-tip: 2906a408e98d185e8c6f75bfed3786d7cc1cbfba
  Call: Mac only: iOS drives its own clock in AgentsViewController; the tick policy lives in LeoKit if iOS wants it later — P1/P2
  Call: The Tasks popover and the sidebar row share the capsule's tick schedule (same durations, same staleness) — P2
  Call: New LeoTaskTick (LeoKit) ticks on a whole-second grid while any visible duration is under a minute, else a coarse 15 s grid — P2 calm/steady status

Lane: B-354
  Branch: autopilot-lane/B-354
  Base: 3dd100793c86bf6b3fea446c574e63ff827b3c2d
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Dispatched: 2026-11-06T19:22:57Z
  Reverifies: 0
  Tokens: 6.3M in (6.05M cache read), ≥27.6k out, 76 requests
  Reviewed-tip: 0adcfdc1bde7097d6b0f06d6db47e0932779d24a
  Call: Mac only (iOS has no task bar) — P1
  Call: Only the done bar's fill is softened; the checkmark glyph, popover and sidebar tints keep full green — P2
  Call: Done-bar opacity 0.55 — P2

Lane: B-348
  Branch: autopilot-lane/B-348
  Base: 9c2d50be1b7b96710a7d4929be78062d246f05c4
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Dispatched: 2026-11-06T19:57:43Z
  Reverifies: 0
  Tokens: 8.22M in (7.95M cache read), ≥31.5k out, 94 requests
  Reviewed-tip: d1852a4aa9501467f2ee1178892351c0e8919990
  Call: Mac only (AppKit test fixtures); flag-line idiom (isReleasedWhenClosed = false per fixture) rather than a makeTestWindow helper — test infrastructure is agent-decides
  Call: Reused the shelved fix by cherry-pick, per the owner's answer (D-692)

Finished 1: B-349 landed 62de526b86e2ffb4c3b2e2e52fde038c85a3c719 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-349-1.png
Finished 2: B-353 landed 40202622fb8c6678c510d00cf5dab3a683e94d3d · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-353-1.png
Finished 3: B-354 landed 0b8212e1f817f41d33a5d0e77537481b31662d43 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-354-1.png
Finished 4: B-348 landed 8871c5d660f9d5efffaa3e759e5120ee547b80cf · not visually verified

Progress:
- B-349, B-353, B-354 picked ahead of B-348 (owner asked to retry those three).
- Preflight: autopilot fast-forwarded to main ce80156fc (shipped leo-v0.30.0); inbox applied: answered B-348 (accept your recommendation (land it as is)), B-349 (retry), B-353 (retry), B-354 (retry); B-355 promoted.
