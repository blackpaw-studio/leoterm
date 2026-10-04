Status: running
Started: 2026-10-03T23:55:13Z
Budget: 20 items, until 2026-10-04T11:55:13Z
Digested-through: 0
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-10-03: previous run finished cleanly; main already in autopilot. Inbox: B-176, B-177 added (/feature). 25 next-run items promoted. No vetoes.
- Board sync: B-014: unknown status [deferred] (exit 1)

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

Lane: B-177
  Branch: autopilot-lane/B-177
  Base: ae5d8371ee404c85fdf3aaa7f268c854a122d0ce
  Tier: full
  State: verifying
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 10651dd628dd50885f1b5688ab529dc59420a7d2
  Dispatched: 2026-10-03T23:59:27Z
  Call: Custom title lives on the surface (Ghostty user-title state, Codable), one source for row label, window title, pane name and close confirm — P1, P6
  Call: Menu order: Show, Split Right, Split Down, Rename…, divider, Close; "Reveal in content" labelled Show; Split Left/Up stay in Window menu — P1
  Call: Close on a hidden busy row asks with ⌘W's "Close “name”?" text; Cancel or another alert already up keeps the row — P2, D-111
  Call: Rename is a SwiftUI "Rename Terminal" sheet (prefilled, live-title placeholder, "Leave blank to use the terminal’s own title."), not Ghostty's NSAlert — P1
  Call: Confirming the unchanged prefilled title is a no-op, so a live title isn't frozen — P1, P2
  Call: leoSetUserTitle also changes Change Terminal Title…: second rename keeps the live title underneath, blank on an unrenamed surface is a no-op, whitespace-only = blank, control chars stripped — AUTONOMY UX
  Call: Menu Split inherits ⌘D's config (working directory) — P1
  Call: Agent surfaces ignored by rename/close/split — Out (agent names are daemon-owned)
  Call: Title persistence is met through SurfaceView encode/decode only; no shell row is restored at launch today (window restoration off), restoring rows at launch would be a new item — P6, AUTONOMY
