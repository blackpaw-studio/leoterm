Status: running
Started: 2026-10-29T02:17:35Z
Budget: 20 items, until 2026-10-29T14:17:35Z
Digested-through: 5
Filed: 1/3 bugs, 3/5 ideas
Self-filed: B-325 → B-334 bug — Paste/Copy menu gets ⌘V/⌘C whenever the key is bound to anything
Self-filed: B-329 → B-335 idea — Set Environments and Switch menu parents stay enabled for a pending agent row
Self-filed: B-333 → B-336 idea — Make the focused split pane easier to spot
Self-filed: B-331 → B-337 idea — Clip the subagent chevron's click area to the name line
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

Lane: B-325
  Branch: autopilot-lane/B-325
  Base: 791b934ff3bf2fa421c405e771b29651301b3a77
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: d778bfce1f9ba3c167d40b82bea1eefd5b5d6063
  Dispatched: 2026-10-29T02:20:31Z
  Call: Mac only; iOS has no menu bar and uses UIKit's own paste — Keyboard-first/Mac-native
  Call: app-wide, like D-592 — Keyboard-first/Mac-native
  Tokens: 6.18M in (5.91M cache read), ≥25.3k out, 75 requests

Lane: B-328
  Branch: autopilot-lane/B-328
  Base: cf19af992d2a325020bac1d822a17cb0e1402082
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 8e11cce2a1c69039b2c040c8bd66bf153aebc553
  Dispatched: 2026-10-29T02:56:32Z
  Call: Close Leo sheets through their window (LeoSheetDismiss + .leoSheetClose(in: window)), falling back to \.dismiss under SwiftUI .sheet — Keyboard-first, Mac-native
  Call: B-328 sheet-close fix is Mac only (iOS doesn't use presentLeoSheet) — Mac+iOS parity rule
  Call: LeoSpawnSheetHostingController becomes NSHostingController<AnyView> so the close value can be injected — implementation approach
  Tokens: 13.2M in (12.8M cache read), ≥49.6k out, 140 requests

Lane: B-329
  Branch: autopilot-lane/B-329
  Base: defe83c4070d4c4f4de52c9960dbb8cd240b675c
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 0e990850f66679d6db4427621c9ba604852bc9d0
  Dispatched: 2026-10-29T04:53:48Z
  Call: Set Template menu parent gets an action the window validates (B-324 pattern, not in this tree); Mac only, AppKit menu-bar quirk — Keyboard-first, Mac-native; Mac+iOS parity rule
  Tokens: 7.7M in (7.41M cache read), ≥29.7k out, 90 requests

Lane: B-330
  Branch: autopilot-lane/B-330
  Base: 206c306fc83d0b647f556f8c7ec42c2249340a5d
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 26df7a3f08a8271c7b5faf50e4976d0d820c7d03
  Dispatched: 2026-10-29T05:24:12Z
  Call: Capsule stats spacing 3→10 pt (about a capsule width) — Agent decides UX/layout
  Call: B-330 is Mac only; iOS Capsules already use 24 pt spacing — Mac+iOS parity rule
  Tokens: 6.19M in (5.94M cache read), ≥23.8k out, 79 requests

Lane: B-333
  Branch: autopilot-lane/B-333
  Base: 3c1c7e1cd4f3cc286f838747698075f7f053171e
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 0a9120a7decb2e62caa76ac77b1a537dd8574aee
  Dispatched: 2026-10-29T05:48:59Z
  Call: One row owns its whole split layout; split panes are never rows (differs from parked B-058) — Ghostty parity, sidebar-is-navigation (D-098)
  Call: ⌘D/⇧⌘D, Window ▸ Split and row-menu Split on a row-only layout go straight to a shell in the focused pane's cwd; supersedes interim D-114/D-105 for rows (D-105 still holds for the agent pool) — keyboard-first, Mac-native; owner's B-333 Accept
  Call: Agent-row ⌘D, and a split beside an agent, keep the picker — D-212
  Call: A layout with any agent pane is closed on switch-away rather than kept — matches existing close-confirm counting
  Call: Row-menu Close closes the whole layout with one confirm naming every busy pane, shown or hidden; ⌘W stays per pane — no silent kills
  Call: A hidden pane that exits leaves the layout, and the row passes to a surviving shell — D-190/D-191
  Call: Reveal refocuses the pane that was focused at switch-away — Ghostty parity
  Call: B-333 is Mac only; iOS is Out — Mac+iOS parity rule
  Tokens: 40.3M in (39.5M cache read), ≥228k out, 251 requests

Lane: B-332
  Branch: autopilot-lane/B-332
  Base: 5b2d1fda40521f87d329cb9d1fdd47b998c48276
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 1609ee58bc31b639eece613d8bf571dc5598e8e8
  Tokens: 51.2M in (50.4M cache read), ≥208k out, 300 requests
  Dispatched: 2026-10-29T06:55:05Z
  Call: Restore through AppKit TerminalRestorable/window restoration, not a Leo-owned file — Mac-native
  Call: Only windows with at least one Terminals row are saved; agent and exited panes are dropped — Out: agent panes; Calm
  Call: Restored window shows the row selected at quit, else the first row — Keyboard-first
  Call: A nil pwd falls back to working-directory; a missing dir falls back to home — acceptance criteria
  Call: A restored window replaces the start window at launch — Ghostty parity
  Call: Restored window is built via TerminalController(leoIsPlaceholder: true) so AppKit's saved frame stands — Mac-native
  Call: Saving is disabled in the test host — keeps test windows out of debug-app restores
  Call: Mac only — iOS is Out

Lane: B-331
  Branch: autopilot-lane/B-331
  Base: b2cb0a8df1b749d73790f2f89cf54de4ff85c607
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: de466ff246f4c29a345c46cb0256416e35a87cdb
  Tokens: 25.3M in (24.6M cache read), ≥99k out, 229 requests
  Dispatched: 2026-10-29T08:04:00Z
  Call: Global hidesSubagents flag plus per-agent exceptions; Hide Subagents clears the exceptions — calm, agent decides persistence
  Call: View ▸ Hide/Show Subagents on ⌥⌘S, no Ghostty or xib clash — keyboard-first
  Call: Chevron at trailing end of the name line; count only when collapsed and above 0, .running only — Mac-native, never invents daemon state
  Call: Collapse moves a hidden dispatch selection to its agent — Mac-native
  Call: No ←/→ or ⌥-click handling (not in the acceptance criteria) — scope
  Call: Mac only — iOS is Out

Progress:
Runner B-325: leo dispatch d-b58f99910543; wake timer bf18g6lzs

Finished 1: B-325 landed e80b304df · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-325-0.png
B-325 landed e80b304df (≈$2.15 est.)
Runner B-328: leo dispatch d-021a185b277e
Finished 2: B-328 landed 7a99dacfa · shot screen capture, not attached
B-328 landed 7a99dacfa (≈$3.44 est.); note: committed test never seen failing (probe with \.dismiss did fail); Copy sheet could move to LeoSheetDismiss once B-324 lands
Runner B-329: leo dispatch d-857e3fc39586
Finished 3: B-329 landed 590edac57 · shot screen capture, not attached
B-329 landed 590edac57 (≈$2.42 est.)
Runner B-330: leo dispatch d-27abc57ef309
Finished 4: B-330 landed 75f360d2b · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-330-1.png
B-330 landed 75f360d2b (≈$2.09 est.)
Runner B-333: leo dispatch d-65b1d70d9ace
B-333 polish "log calls in DECISIONS" not filed: handled by Record
Finished 5: B-333 landed ad1846319 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-333-3.png
B-333 landed ad1846319 (≈$17.39 est.); D-631..D-638 logged; supersedes interim D-105/D-114 for rows
Runner B-332: leo dispatch d-48620c2d4582
Finished 6: B-332 landed 9b7fba969 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-332-10.png
Finished 7: B-331 landed 912484a6c · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-331-2.png
