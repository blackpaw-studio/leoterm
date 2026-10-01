Status: running
Started: 2026-10-01T16:01:52Z
Budget: 20 items, until 2026-10-02T04:01:52Z
Digested-through: 5
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
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: aaa5e28b75f78d04b827d1c3e1b948f5ed59f703
  Dispatched: 2026-10-01T16:49:45Z
  Call: Relied on B-087's LeoContentFocusTests.aRowSwitchFocusesTheShownTerminal for the row-shown → first-responder criterion instead of a duplicate test — AUTONOMY: test infrastructure
  Call: Parameterized the Tab test over presentation timing (.nextTurn real order, .immediately worst case) — AUTONOMY: test infrastructure
Finished 2: B-101 landed c1ad0a447 · not visually verified

Lane: B-102
  Branch: autopilot-lane/B-102
  Base: 659165ab077b7fe5bb5c4f860db1499ddf1e3ea2
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: de8c83e5166a6e40078b111e3f3995d914071a46
  Dispatched: 2026-10-01T17:13:43Z
  Call: Refines D-177: New Terminal may hold only ⌘T (a bare T on New Terminal is now a violation); same rule for Choose Agent… and O — AUTONOMY: test infrastructure
  Call: Removed unused LeoMenuXib.claims(on:byAnyoneBut:); live checks count hidden items too (stricter reading) — AUTONOMY: test infrastructure
Finished 3: B-102 landed 5d8556fcf · not visually verified

Lane: B-103
  Branch: autopilot-lane/B-103
  Base: 456e3c1f4698743f677e662f2afed1a9c6420c24
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7562d130f8287bd3eaad6e70370a44dc4dd78568
  Dispatched: 2026-10-01T18:00:19Z
  Call: Pixel-width "new title drawn" signal for the retitle test, because SwiftUI AX text is unavailable in the test host — AUTONOMY: test infrastructure
  Call: New turns(limit:until:) helper counts run-loop turns until a condition holds (max 50) instead of a time wait — AUTONOMY: test infrastructure, D-178/D-254
  Call: Calm-scroll waits read the window's current list, so a rebuilt list fails an explicit same-list (===) check — AUTONOMY: test infrastructure
  Call: Calm-scroll doc comments drop project history and cite both halves of D-129 — AUTONOMY: test infrastructure
Finished 4: B-103 landed cf1ecdd0e · not visually verified

Lane: B-104
  Branch: autopilot-lane/B-104
  Base: 1ce88330c279a664c103d0eee358da9a1cc10e8a
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 5b60a45039e52cd530ee4e1e1f91e96ccb75a7ae
  Dispatched: 2026-10-01T18:58:27Z
  Call: The disconnected Choose Agent… tooltip reads Agents ▸ Reconnect's live shortcut instead of hardcoding ⇧⌘R (follows B-080's Choose Agent precedent) — AUTONOMY: UX details, copy
  Call: Start-screen hints spell F1–F35 ("⌘F1") when a menu item carries one; config F-key rebinds still reach no menu item because upstream keyToEquivalent drops F-keys — left as a follow-up — AUTONOMY: implementation approach
Finished 5: B-104 landed 0968f1e4a · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-104-1.png

Lane: B-105
  Branch: autopilot-lane/B-105
  Base: e07af107321cb313b7a0df7f2b3874bd29e51737
  Tier: light→full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 1b9d09aedc181a60037c44b95124a84d414703c2
  Dispatched: 2026-10-01T19:24:41Z
  Call: Refines D-187: with nothing selected, the list goes to the top only if the Terminals section was on screen when it closed; if it was scrolled off (selection or not) the list stays put — P2 calm
  Call: Refines D-185: the top landing reaches the list's launch offset (top margin included) by scrolling the NSScrollView itself, not scrollTo(first header) — P2 calm
  Call: "On screen" means any part of the Terminals header or rows inside the clip view minus its content insets; a row only touching the edge doesn't count — AUTONOMY: UX details
  Call: Terminals section is read from the table's last labels.count+1 rows rather than per-row probes (unreliable under cell reuse); LeoSidebarSectionAnchor and the section .id removed — AUTONOMY: implementation approach
  Call: Near-edge test parks one row above the section, not 1 pt (AppKit nudges 2 pt at 1 pt) — AUTONOMY: test infrastructure
Finished 6: B-105 landed 6a4442a11 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-105-1.png

Lane: B-147
  Branch: autopilot-lane/B-147
  Base: 708717ded19067c690e6be365cad0e3b3d14b265
  Tier: light
  State: shelved
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 096acffb0d1a2ea2a12fa2e544d4563eca751f20
  Dispatched: 2026-10-01T21:42:22Z
Finished 7: B-147 done (no code change)

Lane: B-106
  Branch: autopilot-lane/B-106
  Base: bdba773c3a52cbfc3b988bec54f0b5a165c335ed
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-01T21:56:26Z
