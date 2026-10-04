Status: running
Started: 2026-10-03T23:55:13Z
Budget: 20 items, until 2026-10-04T11:55:13Z
Digested-through: 10
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-10-03: previous run finished cleanly; main already in autopilot. Inbox: B-176, B-177 added (/feature). 25 next-run items promoted. No vetoes.
- B-177 landed 5d32041f1 (1 fix round; 1996 tests green).
- B-176 landed 937564be0 (1 fix round; 2015 tests green). Verifier temporarily repointed autopilot-scratch at evandcoleman/nomad-openvpn-deploy-action and restored it; briefly created+deleted a stray leo-claude-autopilot-scratch agent; left clone /Users/evan/.leo/agents/nomad-openvpn-deploy-action.
- B-111: runner handed back "blocked" mid-build (told to hand back while its implementer was still running; not a real block). Not shelved: waiting for the orphaned implementer, then a fresh build runner on the same lane (wip b76844890 + uncommitted test edits).
- Board sync: B-014: unknown status [deferred] (exit 1)
- B-111 resumed runner: ready, general full, suite green on 3rd run (one new flake filed, one known).
- B-112 runner: ready, general full, 2017/2017 on rerun (one load flake filed).
- B-113 runner: ready, general+concurrency full, 2023/2023 green.
- B-114 runner: ready, general full, 2023/2023 with the new tracked script.

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

Lane: B-112
  Branch: autopilot-lane/B-112
  Base: 6eee05ad3e0a85fa64e66ffb9f011b83717a7a65
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: f70a4d0d6e81957f0c4cfbeff02dd164967029fc
  Dispatched: 2026-10-04T03:24:15Z
  Call: Removed LeoCLI.init's runner default too, so a test that forgets a fake fails to compile, matching D-200 — AUTONOMY test infrastructure/implementation approach
  Call: Named the helpers LeoRecordingTemplateRunner(templates:) and LeoCLI.recordingForTests — AUTONOMY naming
  Call: Kept GatedTemplateRunner and GatedTemplateProcess as separate fakes, because they test concurrency rather than plain recording — AUTONOMY test infrastructure
Finished 4: B-112 landed fc43c0acf · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-112-1.png

Lane: B-113
  Branch: autopilot-lane/B-113
  Base: f5997c8fd4fa50b729d82b435cc84ee295a3baaa
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 723b11250625b413f304f1d6044374d9ad6cae3a
  Dispatched: 2026-10-04T04:29:32Z
  Call: Name "Quick Terminal" everywhere: start screen, menu and button, keeping upstream's menu title — P1, AUTONOMY copy/naming
  Call: Quick Terminal glyph is now menubar.arrow.down.rectangle, refining D-207 — P1 HIG, AUTONOMY polish
  Call: Start-screen Quick Terminal gets the live-shortcut tooltip, title only when unbound (D-208) — P2
  Call: No retain cycle existed in the start-screen closures; the self capture is removed anyway (weak delegate and app captures), guarded by weak-reference tests — AUTONOMY bug fixes/test infra
  Call: One LeoSidebarButtonActions value replaces the two loose closures; LeoPlaceholderNewTerminal is deleted, so newTab: and send are each defined once — AUTONOMY implementation approach
Finished 5: B-113 landed 0a5a29f3c · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-113-1.png

Lane: B-114
  Branch: autopilot-lane/B-114
  Base: f0463bf5b2fb0f0a1d5e7a17c7bd44be872e4423
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: f551c48f18b04e3ec056d9ca6decab2a779d7e14
  Dispatched: 2026-10-04T05:22:06Z
  Call: runtests.sh moves into the repo as a tracked script outside scratchpad/ so lanes and checkouts share one copy — AUTONOMY test infrastructure
  Call: Tracked the runner at macos/scripts/leo-runtests.sh with its parse test macos/scripts/test_leo-runtests.sh beside it (outside scratchpad/) — AUTONOMY test infrastructure
  Call: Dropped the stale "ConfigTests/errorsEmptyForValidConfig is an expected baseline failure" note from the failures header (verify.md says treat it as real) — AUTONOMY test infrastructure
Finished 6: B-114 landed 1306d0e4c · shot not visually verified
Finished 7: B-117 done (no code change)
Finished 8: B-137 done (no code change)
Finished 9: B-169 done (no code change)

Lane: B-116
  Branch: autopilot-lane/B-116
  Base: 2e7653f1dc4b0f626a93367b077f2171aeb9fae6
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 2dc1014bd8587751493844d9237281c8172bb877
  Dispatched: 2026-10-04T05:44:39Z
Finished 10: B-116 landed 85d8668a8 · shot not visually verified

Lane: B-118
  Branch: autopilot-lane/B-118
  Base: 2c64c6fb001a163a0e244d1a5a0001fd1ffadd25
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-04T06:22:18Z
