Status: running
Started: 2026-11-24T11:58:07Z
Budget: 20 items, until 2026-11-24T23:58:07Z
Digested-through: 0
Filed: 1/3 bugs, 4/5 ideas
Self-filed: B-438 → B-447 bug — Flaky focus-landing tests in LeoRowSplitIntoShellTests
Self-filed: B-438 → B-448 idea — A plugin section moved to the top reads as part of Agents
Self-filed: B-438 → dropped (dup of B-303) — leo-runtests.sh can leave Resources/terminfo/74 missing
Self-filed: B-439 → B-449 idea — After a relaunch the Files pane starts closed and the right dock is empty
Self-filed: B-439 → B-450 idea — Opening a second file can squeeze the terminal and hide the sidebar
Self-filed: B-439 → B-451 idea — Outline comes back ~20 pt narrower after a window zoom or tile jump
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

Lane: B-439
  Branch: autopilot-lane/B-439
  Base: 095fd564e1c3abfbce82c49343dc0a916af638c8
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 1
  Reviewed-tip: 58b736a723a6a519d31bb5ad21d9984a916ecfb9
  Dispatched: 2026-11-24T14:19:18Z
  Tokens: 84M in (82.7M cache read), ≥233k out, 577 requests
  Call: "Files" = outline plus editor and plugin tabs as one unit; "Browser" = the agent web-view tab — P6
  Call: Both panes default to the right, so layout is unchanged on upgrade — P2
  Call: Dock menu items enable only while Browser or Files has focus, with the current edge checked; no toolbar item or Settings picker — P1
  Call: Both docks clamp at 200 pt; the editor's content minimum drops from 320 to 200 — P1
  Call: An edge change applies live to every open window (one app-wide store) — P6
  Call: After a move, focus returns to the moved pane — P1
  Call: The right dock's remembered width is its tab strip's width; the outline keeps its own 180 pt minimum beside the strip — P1
  Call: The bottom dock sits under whatever the terminal column shows, Chat included, and plain shell rows get it too — P6
  Call: With Files alone on the right, the outline takes the 200 pt dock minimum (fix round 1) — P1

Lane: B-438
  Branch: autopilot-lane/B-438
  Base: 4011ab001ea209a57f368aea2219ee889c0207fa
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: ebbdec92513d97f46639aa6be1e0fa37c9d204d3
  Dispatched: 2026-11-24T11:59:23Z
  Tokens: 64.2M in (63.1M cache read), ≥185k out, 419 requests
  Call: All machines move together as one Agents unit and keep their Settings order — P6
  Call: A drop takes the target header's slot; an accent line marks where it lands; no live reordering while hovering — P1
  Call: No keyboard shortcut for moving sections (headers can't be focused; the context menu covers P1; a shortcut is a follow-up) — P1
  Call: A hidden, disabled or uninstalled section keeps its saved slot and returns to it; with no saved order the default stands — P1/P6
  Call: The order is app-wide across windows, stored in the sidebar preferences — P6
  Call: Drag source sits on the title Button's label, because a Button swallows .onDrag — P1
  Call: Removed the invisible placeholder row under a collapsed plugin section; a shared LeoPluginSectionListing drives both the drawn rows and the row count — P6

Lane: B-442
  Branch: autopilot-lane/B-442
  Base: 310008646a2c15b5965af3ee9c07c873fb7825bf
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-24T14:02:29Z

Progress: resumed after the 2026-11-24 disk-full early stop (Dionysus now 300 GB free); B-439 and B-438 recovered as first picks (lanes clean, Wip: none)
Progress: runners dispatched — B-439 d-d8be886e9d11, B-438 d-a2ee13569eef
Progress: B-438 landed d9842679a (1 fix round, implement.hard); verifier mis-aimed a right-click onto real agent timehop's row menu and dismissed it with Escape, nothing selected
Progress: B-442 built before B-440 (B-440 depends on open lane B-439)
Progress: B-439 landed cca402d84 after 1 re-verify; verifier noted same-edge panes sit side by side, not as tabs (unchecked against Accept) — flag for review; verify.md launch flag -ApplePersistenceIgnoreState shows a Configuration Errors dialog
Finished 1: B-438 landed d9842679a · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-438-8.png
Finished 2: B-439 landed cca402d84 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-439-1.png
