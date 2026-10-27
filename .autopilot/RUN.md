Status: running
Started: 2026-10-27T01:43:03Z
Budget: 20 items, until 2026-10-27T13:43:03Z
Digested-through: 0
Filed: 0/3 bugs, 4/5 ideas
Self-filed: B-304 → B-312 idea — Add an iOS simulator + fixture-daemon recipe to verify.md
Self-filed: B-304 → B-313 idea — Update iOS Machines meters in place instead of rebuilding the row's meter line
Self-filed: B-307 → B-314 idea — Full Leo-browser explanation on browser_tabs and browser_snapshot too
Self-filed: B-307 → B-315 idea — Consider renaming Leo browser tools to leo_browser_*
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

Lane: B-304
  Branch: autopilot-lane/B-304
  Base: a7b1c1819c701c3da306e7a178a6b7959424e995
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: f95863101be4e1158c3b5966ada9caa34c596bbe
  Tokens: 29.8M in (29.2M cache read), ≥100k out, 234 requests
  Dispatched: 2026-10-27T01:44:55Z
  Call: iOS only (the Mac list is a different view; no LeoKit change) — Mac + iOS parity rule
  Call: leave the CPU gauge blue→red flip unchanged; it reflects real data (≥0.9 is `.critical`), and smoothing or hysteresis would be a product call — never invent a state the daemon didn't report
  Call: drop `Identifiable` from `MachineSettings.State` (keeps its `id` property) — agent decides bug fixes

Lane: B-306
  Branch: autopilot-lane/B-306
  Base: 890ee6df384a4931967c0926dbb891baa591ddba
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: d68b956464451e69e42fda9f97388be2402d57d1
  Tokens: 4.15M in (3.84M cache read), ≥20.6k out, 57 requests
  Dispatched: 2026-10-27T03:30:44Z
  Call: Mac only (iOS executor not built); fix is in shared LeoKit — Mac + iOS parity rule
  Call: Only browser_navigate auto-opens a tab; snapshot and other page tools with no tab still return no_such_tab — agent decides bug-fix scope
  Call: Tool names and wire shapes unchanged — shared client-tools contract

Lane: B-307
  Branch: autopilot-lane/B-307
  Base: e93b628b691a25c439a9b1dcd716bcc03b309c81
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 3555d87e77594f4f08a2beaa2beac667fa5e3e94
  Tokens: 3.33M in (3.12M cache read), ≥17.6k out, 45 requests
  Dispatched: 2026-10-27T03:45:17Z
  Call: Description-only fix; tool names, schemas and wire shapes unchanged — D-553, shared client-tools contract
  Call: Mac only, code in shared LeoKit — D-551
  Call: Regenerated leoterm-only golden Fixtures/agent-browser/browser-tools.json; shared client-tools wire fixtures untouched — agent decides test infrastructure

Lane: B-308
  Branch: autopilot-lane/B-308
  Base: 81bf8c3187859bb0b4099e4e9736fdee7fb15be5
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-27T03:58:20Z

Finished 1: B-304 landed 31af2cd81a240f9aee424078b60cdb2b89754b0c · not visually verified
Finished 2: B-306 landed 99a867a7ed078dfb6c4e172bd9c174c646a825e1 · not visually verified
Finished 3: B-307 landed 7897c4422dfb50e8fff1288d5a1de2b0ac80c328 · not visually verified
Note: B-304 lane had build churn in ios/LeoFeatures/Package.resolved (xcodebuild/swift test); restored before land.
Note: 2026-10-27T03:30:44Z preflight sync merged stale local main (c55687eca); origin/main (812e5a9c4, leo-v0.25.0 with the agent browser) merged into autopilot as 724583189 after the B-306 runner found no agent-browser code. B-306 redispatched (not a fix attempt).
