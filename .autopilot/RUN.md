Status: running
Started: 2026-10-03T23:55:13Z
Budget: 20 items, until 2026-10-04T11:55:13Z
Digested-through: 0
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-10-03: previous run finished cleanly; main already in autopilot. Inbox: B-176, B-177 added (/feature). 25 next-run items promoted. No vetoes.
- B-177 landed 5d32041f1 (1 fix round; 1996 tests green).
- B-176 landed 937564be0 (1 fix round; 2015 tests green). Verifier temporarily repointed autopilot-scratch at evandcoleman/nomad-openvpn-deploy-action and restored it; briefly created+deleted a stray leo-claude-autopilot-scratch agent; left clone /Users/evan/.leo/agents/nomad-openvpn-deploy-action.
- B-111: runner handed back "blocked" mid-build (told to hand back while its implementer was still running; not a real block). Not shelved: waiting for the orphaned implementer, then a fresh build runner on the same lane (wip b76844890 + uncommitted test edits).
- Board sync: B-014: unknown status [deferred] (exit 1)
- B-111 resumed runner: ready, general full, suite green on 3rd run (one new flake filed, one known).

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
  State: landed
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
Finished 1: B-177 landed 5d32041f1 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-177-0.png

Lane: B-176
  Branch: autopilot-lane/B-176
  Base: 7a54c7b70d786ccdec4d45a09cd01af1e8d187fe
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: cc9a85fa0303aa88ba5a3bc958a2729e96cf8bd8
  Dispatched: 2026-10-04T01:13:42Z
  Call: Reuse the New Agent sheet in a worktree mode instead of adding a second sheet — P1/P4
  Call: "New Agent in Worktree…" goes right after "Open in New Window"; branch placeholder "feature/my-change"; helper "New branch from origin's default branch"; header "New Agent in Worktree" — P1
  Call: Spawn goes through the selected host's daemon API (branch = --worktree), not a CLI exec; the fake runner is a fake LeoDaemonClient — P3
  Call: Template prefilled and editable; Host and Repository read-only; Name and Prompt optional and empty — Out (no context carried over)
  Call: Item is enabled for any agent status and disabled only when the agent has no owner/repo — P1
  Call: Not added to the menu-bar Agents menu; no shortcut — Out
  Call: A host switch while the sheet is open blocks Create with "Host changed: switch back to <host> to create this agent" — D-103, P3
  Call: LeoAgentActions binds the daemon to its host; spawn refuses with "Not connected to <host> yet" on a mismatch, and the plain New Agent sheet gets the same guard — P3
  Call: A result dropped by a host change resets the sheet with "Host changed; the agent may have been created on <host>"; editing clears a stale error; control characters get their own branch message — AUTONOMY UX
Finished 2: B-176 landed 937564be0 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-176-3.png

Lane: B-111
  Branch: autopilot-lane/B-111
  Base: d9ec5b6bd7169aacf1d0565577d5a5a713c16b1a
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 6c8211537944153dfd95f104504e5a252fd63d7b
  Dispatched: 2026-10-04T02:54:04Z
  Call: LeoTerminalRowsIntegrationTests.freshUndo had the same redundant removeAllActions(withTarget:) next to leoRemoveActionsTestsCanReplay, so it was removed too — AUTONOMY polish / test infrastructure
Finished 3: B-111 landed 148780b7f · shot not visually verified
