Status: running
Started: 2026-10-11T15:41:34Z
Budget: 20 items, until 2026-10-12T03:41:34Z
Digested-through: 5
Filed: 0/3 bugs, 4/5 ideas
Self-filed: B-148 → B-293 idea — Empty sidebar list under the state view may shift its layout
Self-filed: B-149 → B-294 idea — Terminals-section exit may cut the selected row off the same way
Self-filed: B-149 → B-295 idea — Disconnected banner and panel error can clip the selected bottom row
Self-filed: B-150 → B-296 idea — Two sidebar test suites still poll first population with Task.sleep
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
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-284
  Branch: autopilot-lane/B-284
  Base: d4520371097a0592f7340c0599bfea8055219bbf
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 1
  Reviewed-tip: 855c271bdfe6b7292bbab21cc2be1c08ab5f3716
  Dispatched: 2026-10-11T17:02:00Z

Lane: B-285
  Branch: autopilot-lane/B-285
  Base: d3382717920cfd6220dfbcf6b83413e5eacb92ce
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: d373c51d2c3ff128a862681bab624d42e996b98e
  Dispatched: 2026-10-11T17:11:00Z

Lane: B-288
  Branch: autopilot-lane/B-288
  Base: b3546376b5636711819a43e7bf3b86098df0d965
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: a3124af94b23d43cee6da0c3365ac9aca7e2ccbb
  Dispatched: 2026-10-11T17:55:00Z
  Call: Detect `--rw` by probing `dispatch attach --help` for an indented flag line under "Flags:"; any doubt (no line, non-zero exit, throw, timeout) means read-only — P2/P3
  Call: A read-write pane shows no badge; the fallback keeps today's read-only badge and copy — P1/P2
  Call: Both definite probe answers are cached per host (local key = path + mtime, remote key = host config); failed probes are never cached — P2
  Call: Workspace file-drop upload stays off for dispatches — P4
  Call: A dispatch attach waiting on the probe is dropped as superseded if a newer request replaced the window's content — review fix
  Call: `leoWatchingDispatch` is no longer `@Published` (nothing observed it); `leoDispatchReadOnly` is the badge flag — simplification

Lane: B-268
  Branch: autopilot-lane/B-268
  Base: 58d0598f692feaa157d1986d9613ba379d89ea26
  Tier: light
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: a65a3d650c40203d8220bdfdcb49ba4403928a51
  Dispatched: 2026-10-11T18:53:00Z
  Call: A same-state needs_input revision bump never re-notifies and keeps an existing acknowledgement, whatever the reason change — P2 calm
  Call: finished→finished at a newer revision keeps its current "new event" behaviour (out of scope) — P2

Lane: B-269
  Branch: autopilot-lane/B-269
  Base: a31f97f9569f7c7229c0e25ebf76b3681078b86e
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 83fc576c6ed9ee57d1e9b5d17850a337608fb2fa
  Dispatched: 2026-10-11T19:42:00Z
  Call: Missing-server marker is matched as an exact ASCII line on raw stderr bytes (optional single CR, truncated final segment never counts), where it was a substring match on the decoded text — D-422 / P5

Lane: B-148
  Branch: autopilot-lane/B-148
  Base: 762dccd13aceb49e275f9b778584e1452c40c6df
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 1f91cc260248fe8b7b6639195e8ac7a4dc196da7
  Dispatched: 2026-10-11T20:15:00Z

Lane: B-149
  Branch: autopilot-lane/B-149
  Base: e376ef063618831dfb7b0f38b626598ecf1316af
  Tier: light→full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: b45451b9e6c2ae85abee9a39ecb7303e3666146c
  Dispatched: 2026-10-11T21:08:00Z
  Escalated: implement/sonnet (light build, no repro; reported Promote) → implement.hard/opus (full plan; followed the re-plan after a first plan couldn't produce a failing test)
  Call: The selected-terminal reveal now runs after AppKit layout (new LeoListLayoutAnchor), in both directions; still one-shot, so refreshes never scroll (D-130) — P6.
  Call: LeoRevealScheduler (.nextTurn default, .immediate for tests) is kept as a test seam through LeoSidebarView's init; only .immediate gives a 30/30 red — AUTONOMY test infrastructure.
  Call: The reproduced cut-off is the list shrinking when agents go (connected→Loading/Failed/No Agents); Loading→connected can't cut the row off in current code, so the criterion is met by the shrink direction instead — P6, AUTONOMY bug fixes.
  Call: `request` also schedules window.layoutIfNeeded() for the next turn; needsLayout alone left the reveal waiting for a display pass that run-loop turns never reach — plan Risk 4.

Lane: B-150
  Branch: autopilot-lane/B-150
  Base: 3a46e54f24e05f657ef9622fbb6517a54a829e8e
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: b7a0a923d5ebc266b237846c7df017d46742708d
  Dispatched: 2026-10-11T22:47:00Z
  Call: The agents-going direction needs no new test: B-149's aRowRevealedAtTheBottomStaysWhollyOnScreenWhenTheAgentsGo already covers listsAgents true→false (loading, failed, no agents) — P6, test infra agent-decided.
  Call: The first-population signal is run-loop turn counting with a layout pass per turn, not a product hook; no seam added — B-099 turn-counting decision.

Lane: B-151
  Branch: autopilot-lane/B-151
  Base: 2ef7f863fc3ce2224eb05f8ad7bc0a22e6b8aaab
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 3f782fe923d3f4baccada8d84b3aa2ba06fd5c2a
  Dispatched: 2026-10-11T23:14:00Z

Finished 1: B-284 landed 1c1f5aa66 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-284-w515414.png
Finished 2: B-285 landed d34e7d42f · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-285-1.png
Finished 3: B-288 landed 492d7d37f · not visually verified
Finished 4: B-268 landed faa9f0140 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-268-1.png
Finished 5: B-269 landed c4be21582 · not visually verified
Finished 6: B-148 landed aab4e56d0 · not visually verified
Finished 7: B-149 landed 039ec8dad · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-149-2.png
Finished 8: B-150 landed 7f9da972e · not visually verified
Finished 9: B-151 landed 6bf3484f7 · not visually verified

## Progress
- Preflight: autopilot already at main (60e80df75); applied 1 inbox entry (B-288 answer → D-518; stays blocked until leo ships `--rw`; leo 0.45.0 has none).
- Lane autopilot-lane/B-233 exists unlanded with no RUN.md block (left from an earlier run); left in place.
- B-284 picked (tier light): the four ready bugs go before the B-148… test-polish items (bugs-first ordering; B-284 built before B-148).
- B-284 runner dispatched: d-c2a6fef36c6a (implement → claude/sonnet, tier light). Brief passed as a file path (scratchpad brief-B-284.md) to keep the orchestrator prompt small.
- 12:29 EDT: leo agent reports `--rw` in leo PR #264 (no feature-flag gate per Evan; no release yet). B-288's Question updated; it stays blocked until a leo release ships it.
- 12:37 EDT: B-284 runner reported blocked: fix a4f586bde built, general review clean, GUI pass (shot B-284-w515414.png), but 8 focus/key-window tests fail (also on baseline 5f97da7) because an orphaned codesign keychain prompt (SecurityAgent pid 13373, no codesign alive) holds Secure Input. Lane-tip 1f4dfba54, Integrated-at 5f97da7f3. Killing the prompt and shelving were both denied by the permission classifier; waiting on Evan.
- 13:00 EDT: Evan approved killing the stale keychain prompt; SIGKILLed SecurityAgent 13373 (SIGTERM ignored). Deviation: instead of shelving the blocked B-284 report, a re-verify round re-runs the suite on the unchanged, already-reviewed Lane-tip. My screen check triggered a 'leo would like to record screen' TCC prompt; Evan asked to Deny it.
- B-284 landed 1c1f5aa66 (light; re-verify suite 2662/2662 green). Runner note: a second SecurityAgent (pid 69473, user heracles, non-console session, ~10 days) is harmless unless that user becomes console.
- B-285 picked (tier light): same contentViewController pattern; reuse B-284's NSWindow.presentLeoSheet helper.
- B-285 runner dispatched: d-9fd59b2bcca2 (implement → claude/sonnet, tier light).
- 13:10 EDT: leo agent reports `--rw` shipped in leo v0.47.0. That meets D-518's condition, so B-288 is set to ready (Update line added). Local leo is still 0.45.0, so the item is built with a fallback and fake-CLI tests.
- B-285 landed d34e7d42f (light, 1 fix round: test isolation; suite 2665 green; Rename/Delete by tests only).
- B-288 picked (tier full: earlier attempt on autopilot-shelved/B-288; owner's report, unblocked by leo v0.47.0). B-288 built before B-268/B-269 (owner-sourced bug first).
- B-288 runner dispatched: d-5bacc1a48ca0 (implement → claude/sonnet, tier full).
- B-288 landed 492d7d37f (full, 1 fix round: probe race; suite 2683 green; not visually verified).
- B-268 picked (tier light: one narrow attention/ack comparison).
- B-268 runner dispatched: d-331c0899af6d (implement → claude/sonnet, tier light).
- B-268 landed faa9f0140 (fixes 1).
- B-269 picked (tier light: one stderr-decoding path).
- B-269 runner dispatched: d-e2dee81f388d (implement → claude/sonnet, tier light).
- B-269 landed c4be21582 (fixes 0).
- B-148 picked (top ready; tier light: keep one sidebar list mounted + doc comments).
- B-148 runner dispatched: d-a7489852d58a (implement → claude/sonnet, tier light).
- 16:16 EDT: B-148 runner ended its turn early ("waiting on implementer"); sent follow-up #2 telling it to block on leo_wait for d-9665567f2291. Dispatched time unchanged.
- B-148 landed aab4e56d0 (fixes 0).
- B-149 picked (tier light: order one reveal after layout).
- B-149 runner dispatched: d-28e147c6b7a4 (implement → claude/sonnet, tier light).
- B-149 landed 039ec8dad (fixes 1).
- B-149 landed (light→full: the light build and first plan couldn't go red; the re-plan reproduced the shrink direction). Filed B-294/B-295; the third polish line (pre-layout geometry in resize tests) goes to B-150 as a lane note.
- B-150 picked (tier light: test hardening; runner d-00ab00580600).
- B-150 landed 7f9da972e (fixes 0).
- B-150 landed. Filed B-296 from the runner's Notes (leftover Task.sleep polls outside the scroll tests).
- B-151 picked (tier light: test hardening; runner d-983382f93c62).
- B-151 landed 6bf3484f7 (fixes 0).
