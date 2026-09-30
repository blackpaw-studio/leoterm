Status: running
Started: 2026-09-30T18:19:05Z
Budget: 20 items, until 2026-10-01T06:19:05Z
Digested-through: 0
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-09-30: previous run finished cleanly. main == autopilot (46fbb909d). Inbox: B-058 answered "punt" → parked as idea (D-212), held lane kept as-is; /feature "In-app updates on" → B-115, placed at the top of the queue (above the promoted polish items, per the /feature intent). B-087..B-114 promoted. Stale landed lanes B-054..B-086 still on disk (finish could not remove them last run).

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-09-30T14:49:01Z
- Board sync: B-014: unknown status [deferred] (exit 1)

Lane: B-090
  Branch: autopilot-lane/B-090
  Base: 7c2f61a96d53b634458dc895c3c85941a68735db
  Tier: light
  State: verifying
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 988d3dca0db89b37c8662ed8625f7085831cc684
  Dispatched: 2026-09-30T18:21:35Z
  Call: Launch test asserts "terminal fills the split" rather than "sidebar frame is 0" (a collapsed item keeps a stale 200 pt frame; the terminal width is what the user sees) — AUTONOMY test-infra latitude
  Call: B-084's aHiddenSidebarShownAfterLaunchOpensAtTheStoredWidth now uses `try #require(sidebarItem.isCollapsed)` instead of forcing isCollapsed = true, which had masked this bug — AUTONOMY test-infra latitude
- B-090 runner: ready at 988d3dca0 (general full; implementer/opus; 0 fix rounds; 1850/1850 green). GUI: hidden sidebar stays collapsed through relaunch; re-show restores 330 pt.
