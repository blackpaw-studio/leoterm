Status: running
Started: 2026-11-24T00:56:31Z
Budget: 20 items, until 2026-11-24T12:56:31Z
Digested-through: 0
Filed: 1/3 bugs, 0/5 ideas
Self-filed: B-324 → B-442 bug — Mac composer on a moved agent still offers Start and shows Idle
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
  Base: 785cf8d787f0446d2fa3200b902d16160ec883d9
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7880c2ee4501a72c279836a7cb6589d2b0385c7a
  Dispatched: 2026-11-24T00:59:01Z
  Call: A moved row opened in a new window (⌘-click, ⌥-double-click) shows its chat, like a plain click, not a Start sheet — VISION 2, 6
  Call: The chat bar on a moved row reads "<name> moved to <host>." with no Start button — VISION 2
  Call: The moved-row guard in go(to:) comes before the status check, so it covers every status — VISION 2
  Tokens: 21.2M in (20.7M cache read), ≥74.5k out, 189 requests

Lane: B-437
  Branch: autopilot-lane/B-437
  Base: 785cf8d787f0446d2fa3200b902d16160ec883d9
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 6b1e9792a69e1a2edc7af425f3bc49dc5a753427
  Dispatched: 2026-11-24T00:59:01Z
  Tokens: 4.27M in (4.04M cache read), ≥19.4k out, 53 requests

  Call: iOS only (the Mac app has no notch or side safe area) — Mac/iOS parity rule; consistent with D-989

Lane: B-441
  Branch: autopilot-lane/B-441
  Base: 06b47fbd7a14f3063ed1aa7d8ff97499b0e56904
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-24T01:16:36Z

Finished 1: B-437 landed edf4408a04be9f93246dcc6a9d797b1b03e1f0a1 · not visually verified
Finished 2: B-324 landed b127fba37f1e77389dbefb41208c828647e377e5 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-324-2.png
