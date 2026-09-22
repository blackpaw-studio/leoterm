# Backlog

Ranked. Statuses: `ready`, `ready (next run)`, `blocked`, `done`.
Source roadmap: `docs/leo/roadmap.md` on `main` (not edited by autopilot).

## B-001 · Attention model, app side   [done]
Accept: implement docs/superpowers/specs/2026-09-21-leo-attention-model.md with
D-005 answers (tab focus acks Dock count, row badge stays; focused split =
viewing; ⌃⌥⌘J jump). `LeoAttentionReducer` value type, fixture-driven tests
for every transition. Legacy daemons show Working only. Screenshot row badges
using fixture/scratch data.
Source: roadmap Tier 1
Done: 4e064d6f7 cb18a2a6c 013840a46 465676949 93e0c4f78 60cb67072 f378da52c a0899a492 190b70f4b c5540f3c7 (726 tests). Verified by screenshot with the DEBUG fixture (D-018). Dock badge and notifications were not visually verified.

## B-015 · Attention edge cases before the daemon ships   [done]
Accept: (a) keep a tombstone incarnation when `retain` drops an agent, so a recreated agent at incarnation 0 isn't suppressed by `lastPosted` (scenario in the final B-001 review); (b) retry a pending /state baseline while the sidebar is hidden (`LeoPollScheduler.swift:125` requires visible), since notifications matter most then; (c) low: a baseline applied outside recovery can falsely bump the incarnation (`LeoAttentionReducer.swift:124`). Each with a failing test first. Must land before the leo daemon ships `attention`.
Source: B-001 final review
Done: c5c24c336 8dfe3aa7c 91fd60791 4fea50a28 a4411496e (866 tests). Also covers leo's 3 live-testing clarifications (unknown never badges; errored survives restart; a fresh row missing the field isn't legacy). Logic only, so not visually verified. Remaining recreate-during-gap edge → B-018.

## B-016 · Tab ↔ row linkage polish   [ready]
Accept: (a) medium, plausible: when clicking a row in a non-key window, the window's activation focus report can land after the tap (it's async via AsyncStream + Task, `LeoAttachCoordinator.swift:74`) and snap the selection back; make the click win deterministically; (b) the row's hover "Attach" button draws over the agent name (shot B-006-3.png); (c) low: `GhosttyAttachTabHost.focusedHandle` uses the controller's focusedSurface, not the first responder, so clicking back into the same terminal after selecting another row doesn't reselect; (d) low: app reactivation sends nil then the real focus, which overwrites an arrow-key selection.
Source: B-006 reviews + visual check

## B-017 · File-access polish   [ready]
Accept: (a) fix the doc comment in `LeoHostConfiguration.swift:67-71` to say the hash covers the app's argv inputs, not ssh_config aliases; (b) home dirs longer than ~33 chars exceed the control-path budget and lose file access; consider a shorter token or a private short dir; (c) remote errors are vaguer than local ("Failure"); map SFTP status codes more finely where possible.
Source: B-003 reviews

## B-018 · Drop the recreate heuristic: dedupe on (boot, name, revision)   [ready]
Accept: leo confirmed (2026-09-22, spec addition) that a revision is monotonic per agent NAME per boot, including across delete and recreate; revisions only go backwards when boot_id changes. So remove the backwards-revision heuristic from `LeoAttentionReducer` (incarnation bumps on retain/recovery, tombstones and their 64-cap, `droppedFloors`) and key notification dedupe on (bootID, name, revision). A revision ≤ the last seen for that name in the same boot is a duplicate; a recreated agent simply continues at higher revisions. Keep: list-driven deletion of display state, reset on boot change or host switch, and everything from B-015's (b), (d), (e), (f). Rewrite or delete the heuristic's tests; add fixture tests for the three gaps from B-015's third review (a recreated agent's first signal buffered during recovery notifies; an agent re-added by a baseline at the same revision keeps its Dock acknowledgement; a first seen revision equal to the old floor is a duplicate by contract).
Source: B-015 third review + leo reply (D-027)

## B-002 · Request daemon `attention` field from the leo agent   [done]
Accept: send the leo agent the exact contract from the spec's "Leo-daemon
prerequisite" section; log the reply/ETA in DECISIONS.md. No leo repo edits.
Source: attention spec; D-006
Done: contract sent 2026-09-22 (D-010); leo accepted in principle, ETA pending Evan's approval of the daemon spec (D-011).

## B-003 · File access layer (local FS + SFTP)   [done]
Accept: one `LeoFileAccess` protocol, local backend and SFTP backend over the
existing SSH ControlMaster for the selected host; list dir, read, write
(atomic), stat/mtime conflict check. Tests with a local sshd or fake.
Source: Evan, vision session; D-003, D-007
Done: 7fd10dad9 6f92f70e9 9b466088a a0b838dcd 1c7c93e5f 7858fbda8 4ee7c8353 515e6554b e780ead10 6f52a67c8 da7fca9c4 (839 tests; the shared contract suite runs against local, sftp-server over pipes, chunked, and no-posix-rename). No UI, so no screenshot. The opt-in E2E against localhost reached the real ControlMaster, but SFTP is disabled in this Mac's sshd_config.

## B-004 · Editor pane for surfaced files   [ready]
Accept: ⌘-click a path / OSC 8 link in an agent's terminal opens it in a Leo
editor pane (syntax highlight, edit, ⌘S save, external-change detection).
Relative paths resolve against the agent's workspace. Works local and remote.
Source: Evan, vision session; D-007

## B-005 · Per-agent workspace browser   [ready]
Accept: from a sidebar row (context menu + shortcut), browse the agent's
workspace tree via B-003 and open files in B-004's pane. Keyboard navigable.
Source: Evan, vision session; D-007

## B-006 · Tab ↔ row linkage   [done]
Accept: highlighted row follows the focused attach tab; tab-count glyph on rows
with live tabs; clicking a highlighted row focuses its tab.
Source: roadmap Tier 2
Done: 54ae397a2 e05e818b7 71d366ad1 e07fa6b65 (744 tests). Verified with shots B-006-1..4 using autopilot-scratch.

## B-007 · Disconnected state   [ready]
Accept: on tunnel drop or wake, grey the list and show a Retry banner instead
of stale rows. Manual retry only.
Source: roadmap Tier 2

## B-008 · Fix order-dependent test flake + swiftlint baseline   [done]
Accept: `LeoHostSelectionReloadTests.editingAnUnrelatedHostDoesNotReselect`
passes 10/10 in full serial runs (pid-file read race in
`LeoHostSelectionTestSupport`); clear the 3 `large_tuple` violations in
`macos/Tests/Leo/LeoAttachCoordinatorTests.swift:316-319`.
Source: roadmap Test infra; vision-session test run
Done: d806f8ecf c3edaf507 a80bd0475. Root cause: fake_ssh wrote the pid file non-atomically. 10/10 full runs; swiftlint clean. Also fixed the Observe 50 ms deadline flake. Test-only change, so no screenshot.

## B-009 · Search polish   [ready]
Accept: ⌘F focuses the sidebar filter, fuzzy match, Escape clears.
Source: roadmap Tier 2

## B-010 · Sort and pin   [ready]
Accept: default sort by last activity; pin favourites to top; remember
collapsed sections.
Source: roadmap Tier 2

## B-011 · Row metadata   [ready]
Accept: relative "last active" time and current task line; tokens/cost only
when the daemon exposes them.
Source: roadmap Tier 2

## B-012 · Cold start   [ready]
Accept: measure launch with sidebar visible; if first fetch blocks first
paint, render cached last snapshot and refresh in place.
Source: roadmap Tier 3

## B-013 · Daemon-pushed "surface file" event   [blocked]
Accept: an agent calls a leo tool; the daemon emits a file-surfaced event;
Leo badges the row and opens/queues the file.
Question: needs a leo daemon change — request it from the leo agent after
B-004 ships, or wait for you? — I'd pick requesting it after B-004 ships.
Answer:

## B-014 · All hosts at once as sidebar sections   [blocked]
Question: deferred by D-008 until several remotes are in daily use. Tell me
when that's true. — I'd pick keeping it deferred.
Answer:
