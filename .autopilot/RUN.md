Status: running
Started: 2026-10-10T02:01:17Z
Budget: 20 items, until 2026-10-10T14:01:17Z
Digested-through: 0
Filed: 0/3 bugs, 0/5 ideas
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
  State: verifying
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

Finished 1: B-270 landed 28ade697f · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-270-1.png

## Progress
- Preflight: B-270 lane recovered (Wip: none, empty lane) as first pick; merged main into autopilot (8af0dcea0, sidebar pill rows); inbox → B-275.
- Lane autopilot-lane/B-233 still unlanded with no block (item done); left in place.
- B-270 landed 28ade697f (full, hard; concurrency review clean; verifier saw one load-flaky LeoTerminalRowMenuIntegrationTests rename failure per full run, passes isolated; implementer run green).
