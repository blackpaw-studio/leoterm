Status: running
Started: 2026-11-06T17:47:04Z
Budget: 20 items, until 2026-11-07T05:47:04Z
Digested-through: 0
Filed: 1/3 bugs, 2/5 ideas
Self-filed: B-349 → B-358 bug — Reset-zoom titlebar accessory likely sits low in the unified toolbar
Self-filed: B-349 → B-359 idea — Show the update pill in the toolbar's » overflow menu at narrow widths
Self-filed: B-349 → B-360 idea — Update popover shows a blank "Version:" line
Untracked-left: default.profraw scratchpad/

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 0df90da27212820f6a1534348953c7ae5a4260ba
  Call: Pill moves from a titlebar accessory to a native trailing toolbar item (.leoUpdate), left of "⋯"; corner overlay stays off for agent windows — P1
  Call: Narrow-width give-way order: subtitle, then pill, then title, then "⋯"; "Check for Updates…" stays in the app menu — P2
  Call: Mac only; iOS has no Sparkle pill
  Call: Pill width is measured (fittingSize + 10, 200 fallback) and re-measured on every state change
  Call: DEBUG-only LEO_UPDATE_FIXTURE env seam (compiled out of release) and LeoAgentToolbar.hidesItemsInPlace test seam

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
  State: verifying
  Fixes: 1
  Wip: none
  Dispatched: 2026-11-06T17:47:53Z
  Reverifies: 0
  Reviewed-tip: none

Progress:
- B-349, B-353, B-354 picked ahead of B-348 (owner asked to retry those three).
- Preflight: autopilot fast-forwarded to main ce80156fc (shipped leo-v0.30.0); inbox applied: answered B-348 (accept your recommendation (land it as is)), B-349 (retry), B-353 (retry), B-354 (retry); B-355 promoted.
