Status: running
Started: 2026-10-10T02:01:17Z
Budget: 20 items, until 2026-10-10T14:01:17Z
Digested-through: 0
Filed: 0/3 bugs, 1/5 ideas
Self-filed: B-274 → B-276 idea — Terminals section needs a manual scroll on a long sidebar
Self-filed: B-273 → dropped (dup of B-244) — sidebar vanishes at the default 800px width when the editor pane opens
Self-filed: B-274 → dropped (dup of B-244) — Sidebar Show disabled at the default 800px width with a side pane
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

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

Lane: B-270
  Branch: autopilot-lane/B-270
  Base: 272c473f02b1fa278607e381ef5f2553cd55cc23
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: bb34cabbf40660d86f40640e3ea760dd2e6651c2
  Dispatched: 2026-10-10T02:03:57Z
  Call: Re-attach after hello rather than delay the first attach — P6
  Call: Hidden unflagged surfaces are released, not re-attached while hidden — P6, D-109
  Call: Shown swap loses Ghostty-local scrollback/selection (slot, focus and row selection kept; tmux history survives) — P6
  Call: Disconnected gating unchanged — P2
  Call: Failed re-attach reported to the row as openFailed; closing-window handle forgotten silently; no contentVersion bump — D-110
  Call: reattachInPlace inherits the old surface's config (deviation, behaviour-neutral)
  Call: Command rebuilt after confirm only when placement changed, since a full rebuild broke aRemoteDispatchGoesThroughTheRemoteBuilder (deviation)
Lane: B-271
  Branch: autopilot-lane/B-271
  Base: 4692ca633a9ac62d2bb7d3bdcb3feb03d6a2ebe8
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 77859dd9c8ba670d04152a56908804edc7c43742
  Dispatched: 2026-10-10T03:28:43Z
  Call: Rows viewed in the caller's session become clickable; a click focuses that pane and shows the parent agent — P6
  Call: Fallback uses only the reported `attachable` and `tmux_target` — P2
  Call: Fallback gated on connected + dispatch_attach + live run; older daemons keep inert rows — P2, D-433
  Call: Headless dispatches (no pane) stay informational — P2
  Call: Same behaviour on remote hosts over ssh — P3
  Call: A failed focus is reported on the parent row, and the agent is still shown — P6
  Call: Focus runs through the injected hostSelectionRunner with a 10 s timeout — AUTONOMY implementation approach
  Call: Remote focus opens a new ssh connection with BatchMode=yes (no ControlMaster reuse) — AUTONOMY implementation approach
  Call: Every click on such a row re-sends the pane focus (idempotent) — P6

Lane: B-275
  Branch: autopilot-lane/B-275
  Base: ae5df8a554fd84f25835402c499cf98247bf618e
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 78b1d8c62741ae9cddd03489a2fc1a9e901cbff1
  Dispatched: 2026-10-10T06:36:00Z
  Call: 24pt dispatch pitch via List-level sidebarRowSize=.small, terminal rows pinned to 32 — P1
  Call: Role chip shows the family only in a fixed column, full role in tooltip and VoiceOver, sub-role shown as the title when a dispatch has no name — P1 (criteria allow shortening)
  Call: Last visible dispatch per agent is taller (40pt, top-aligned) instead of a spacer row, because the row floor makes spacers impossible — P1/P2
  Call: DEBUG fixture advertises dispatch_tree when it lists dispatches — D-396

Lane: B-274
  Branch: autopilot-lane/B-274
  Base: 34e35b0b11ffdd1df23fd42ad82148a9934ff996
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 6a52d680baa9e483028033cfc369f2728330b662
  Dispatched: 2026-10-10T07:09:54Z
  Call: Pane follows the row the window navigates to; panes are per window — P6/P1
  Call: Pool eviction never closes a pane — P6
  Call: A stopped agent's action fills that agent's own pane, never the on-screen row's — P6
  Call: Destination window resolved before the pane is filled; a show that didn't happen fills nothing — P6
  Call: Clean pane closes silently; dirty pane asks Save/Don't Save/Cancel; closes that can't ask (exit, undo, drag) keep the dirty pane as an orphan — D-033
  Call: A shown shell exiting with unsaved edits leaves the start screen holding the pane — D-140
  Call: Delete Agent asks about its dirty panes in every window — P2
  Call: Snapshot prune only on a connected, known-host list, never the shown row — P5

Lane: B-273
  Branch: autopilot-lane/B-273
  Base: e1fb9d11065b2acf6cb7cbae26caa632c4882075
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: d2503608d0a3f90cae078fb3485b28cf09ca2a1d
  Dispatched: 2026-10-10T09:20:52Z
  Call: Every open adds a tab or selects the file's existing one, and nothing replaces a document (D-033's replace prompt no longer fires) — P1, P2
  Call: Tab strip is inside the pane, appears at 2+ tabs, custom AppKit (NSTabView has no close buttons or overflow); no window tab bar — P1, P6
  Call: ⌘W with editor focus closes the selected tab; Show Next/Previous Editor Tab ⇧⌘]/⇧⌘[; Close Editor Tab has no shortcut; Ghostty next/previous_tab switches editor tabs from the terminal — P1
  Call: A background open never moves focus or navigates, and doesn't override a tab the user picked after the request — P2
  Call: Auto-open window choice: A on screen, then A's pooled surface, then an existing pane for A, then the key window (ties go to the key window); it never attaches — P2
  Call: "Viewed" means A is on screen in a visible, non-miniaturized, non-occluded window; the badge stays until then — P2
  Call: Only live, new events auto-open; auto-open failures are silent and keep the badge; ⌥⌘O still shows errors — P2
  Call: Cap of 10 tabs per pane; the least-recently-selected clean tab is evicted, dirty tabs never — P2, P3
  Call: Remote files go through the same per-window file access (SFTP) — P3
  Call: Tab strip sits under the pane header with a dirty dot and a hover/selected close button; the header close tooltip stays "Close Editor (⌘W)" — P1

Finished 1: B-270 landed 28ade697f · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-270-1.png
Finished 2: B-271 landed 16b35ad0b · not visually verified
Finished 3: B-275 landed e902d0ef1 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-275-6.png
Finished 4: B-274 landed fab510f17 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-274-5.png
Finished 5: B-273 landed 1c99121ce · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-273-5.png

## Progress
- Preflight: B-270 lane recovered (Wip: none, empty lane) as first pick; merged main into autopilot (8af0dcea0, sidebar pill rows); inbox → B-275.
- Lane autopilot-lane/B-233 still unlanded with no block (item done); left in place.
- B-270 landed 28ade697f (full, hard; concurrency review clean; verifier saw one load-flaky LeoTerminalRowMenuIntegrationTests rename failure per full run, passes isolated; implementer run green).
- B-271 landed 16b35ad0b (not visually verified). Verifier ran `peekaboo type` without a frontmost-app check; debug search field stayed empty, so the text may have gone to another app. Flagged for digest.
- B-275 runner d-4d3e1d99e1b9 ended its turn to await its implementer and was idle-closed at 1h; implementer d-681b670617a2 finished 4 commits (report lost to the dead runner). Re-dispatched a fresh build runner from Integrate; briefs now require blocking leo_wait.
- B-275 landed e902d0ef1 (1 fix round: group gap 8→16pt after the first verify failed contrast).
- B-274 landed fab510f17 (1 fix round). Verify near-miss: stale-coordinate clicks selected real stopped agents whatshoveringoverme (a Start prompt appeared, cancelled) and widgeon; nothing started. Flag for digest.
- B-273 landed 1c99121ce (1 fix round). Runner polish 'peekaboo type reports failure even when text lands' not filed: verification tooling, not leoterm. Flake seen once: anEmptyNameRestoresTheLiveTitle.
