Status: running
Started: 2026-10-01T16:01:52Z
Budget: 20 items, until 2026-10-02T04:01:52Z
Digested-through: 0
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-10-01: previous run finished cleanly; main already merged. Inbox: B-109 closed (not reproducible, D-256). 35 next-run items promoted. Landed lanes B-054..B-115 still on disk: finish skips them as dirty (untracked build output).

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

Lane: B-100
  Branch: autopilot-lane/B-100
  Base: 32a88bbf472d150a1c20171a5879150840a9eca7
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 54f46f35ccad5080d575882e87e9b79f0c2fb2d7
  Dispatched: 2026-10-01T16:03:21Z
  Call: The shared hidden-style inset stays at 10 pt, not enlarged for the "tight" corner, because D-169 fixes it — AUTONOMY: layout/polish
  Call: Side-pane headers centre on the sidebar header's line rather than aligning control-frame tops — P1 Mac-native, toolbar-style alignment
  Call: New LeoSidebarChromeMetrics.headerRowHeight = 16 applied to LeoSidebarHeader as .frame(minHeight:), so the sidebar doesn't move — AUTONOMY: implementation
Finished 1: B-100 landed 3b5b1b95c · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-100-1.png

Lane: B-101
  Branch: autopilot-lane/B-101
  Base: 25caa8be6e2dd727036a58742a6ffdbba451ad25
  Tier: light
  State: verifying
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: aaa5e28b75f78d04b827d1c3e1b948f5ed59f703
  Dispatched: 2026-10-01T16:49:45Z
  Call: Relied on B-087's LeoContentFocusTests.aRowSwitchFocusesTheShownTerminal for the row-shown → first-responder criterion instead of a duplicate test — AUTONOMY: test infrastructure
  Call: Parameterized the Tab test over presentation timing (.nextTurn real order, .immediately worst case) — AUTONOMY: test infrastructure
