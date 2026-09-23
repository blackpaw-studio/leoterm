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

## B-016 · Tab ↔ row linkage polish   [done]
Accept: (a) medium, plausible: when clicking a row in a non-key window, the window's activation focus report can land after the tap (it's async via AsyncStream + Task, `LeoAttachCoordinator.swift:74`) and snap the selection back; make the click win deterministically; (b) the row's hover "Attach" button draws over the agent name (shot B-006-3.png); (c) low: `GhosttyAttachTabHost.focusedHandle` uses the controller's focusedSurface, not the first responder, so clicking back into the same terminal after selecting another row doesn't reselect; (d) low: app reactivation sends nil then the real focus, which overwrites an arrow-key selection.
Source: B-006 reviews + visual check
Done: c25cf3523 82c835016 ab3f8c6ff 7d2b676e7 89ff485c9 79f8d61f2 7a3728f4f (867 tests). Verified: shot B-016-1.png (hovered long name truncates before Attach). (a), (c) and (d) are covered by tests only. Test gaps from the review → B-019.

## B-019 · Tests for the host focus sequence and the ordered relay   [ready]
Accept: (a) a host test that collects `lifecycleEvents` around `makeFirstResponder` and checks the exact order: viewing is reported before focus, and focusing the sidebar yields only `.focusChanged(nil)` (`GhosttyAttachTabHostFocusTests.swift:10`); (b) a test that fails if `focusedAgentChanged` stops going through `LeoOrderedRelay` (`LeoRuntime+Attention.swift:10`).
Source: B-016 second review

## B-017 · File-access polish   [done]
Accept: (a) fix the doc comment in `LeoHostConfiguration.swift:67-71` to say the hash covers the app's argv inputs, not ssh_config aliases; (b) home dirs longer than ~33 chars exceed the control-path budget and lose file access; consider a shorter token or a private short dir; (c) remote errors are vaguer than local ("Failure"); map SFTP status codes more finely where possible.
Source: B-003 reviews
Done: 97781e299 f8b3b4350 fb1bb244b 119697892 198da68e3 adb143d49 1c8ae5131 2f5f51b4d abf708a54 (908 tests). Control sockets now live in the per-user cache dir, a fixed 86 bytes whatever the home dir length; foreign-owned sockets are refused; a vanished socket gets a "Reconnect" message; SFTP errors are specific, and server text and filenames are sanitized. No UI, so no screenshot. Remaining sanitizer gaps → B-020; daemon-socket length → B-021.

## B-020 · Sanitize every error string at one choke point   [done]
Accept: sanitize `reason`/`detail` once, where it renders (`LeoFileAccessError.errorDescription`), instead of at each source. This closes paths from B-003 that are still raw: the SFTP rename temp name `kept` (`LeoSFTPFileBackend.swift:120`), Foundation's `localizedDescription`, which embeds raw local filenames (`LeoLocalFileBackend.swift:145`, `LeoFileAccessError.swift:44`), and the transport's `describe(error)` (`LeoSFTPTransport.swift:124`). Also: add the missing double-quote lookalikes (U+2E42, U+1F676–1F678, U+05F4, U+02BA, U+3003, U+02DD); wrap interpolated names in FSI…PDI so RTL names can't reorder the surrounding text; raise the mark cap to 3–4 for Hebrew and Indic text; keep tag characters after U+1F3F4 (subdivision flags). Test first, with a spoofing filename through every backend.
Source: B-017 third security review (D-032)
Done: ad0807785 796b0a2ec 8b6494d45 935b5a600 (1122 tests). Errors are sanitized once where they render; untrusted parts are wrapped in FSI…PDI; invisible characters survive only from an allowlist (D-042). Error text only, so not visually verified. 3 fix rounds; the last review's HIGH → B-026 (D-043).

## B-026 · Presentation selectors only after emoji   [ready (next run)]
Accept: (a) HIGH: FE0E/FE0F survive after any visible character (`LeoTextCleaner.swift:97-99,128-132`), so a filename can carry ~1.58 hidden bits per character. Keep them only right after a pictographic base (the same check the ZWJ rule uses). The property test (`randomInvisiblesLeaveAtMostOneZeroWidthScalarPerVisibleCharacter`) passes either way; add a test that a selector after a letter is dropped. (b) NIT: ZWNJ checks only the next scalar is a letter (`:104-105`); check the previous one too. (c) The SFTP security review role (codex/gpt-6-sol) failed with "Model metadata not found" all run; B-020 was reviewed by the Sonnet fallback.
Source: B-020 final review (D-043)

## B-021 · Forwarded daemon socket path budget   [ready]
Accept: the forwarded daemon socket in `~/.leo/state/leoterm/` has a 100-byte limit, so home directories longer than roughly 38–58 characters (depending on host name) break the whole tunnel. Move it to the same private per-user cache dir as the control sockets (`LeoControlSocketDirectory`), with the same checks. Failing test first with a long fake home.
Source: B-017 implementer report

## B-018 · Drop the recreate heuristic: dedupe on (boot, name, revision)   [done]
Accept: leo confirmed (2026-09-22, spec addition) that a revision is monotonic per agent NAME per boot, including across delete and recreate; revisions only go backwards when boot_id changes. So remove the backwards-revision heuristic from `LeoAttentionReducer` (incarnation bumps on retain/recovery, tombstones and their 64-cap, `droppedFloors`) and key notification dedupe on (bootID, name, revision). A revision ≤ the last seen for that name in the same boot is a duplicate; a recreated agent simply continues at higher revisions. Keep: list-driven deletion of display state, reset on boot change or host switch, and everything from B-015's (b), (d), (e), (f). Rewrite or delete the heuristic's tests; add fixture tests for the three gaps from B-015's third review (a recreated agent's first signal buffered during recovery notifies; an agent re-added by a baseline at the same revision keeps its Dock acknowledgement; a first seen revision equal to the old floor is a duplicate by contract).
Source: B-015 third review + leo reply (D-027)
Done: f2ed8537a (858 tests; 12 heuristic tests removed, 4 contract tests added; 126 fewer lines). Review clean; 3 LOWs dismissed (D-028). Logic only, so not visually verified.

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

## B-004 · Editor pane for surfaced files   [done]
Accept: ⌘-click a path / OSC 8 link in an agent's terminal opens it in a Leo
editor pane (syntax highlight, edit, ⌘S save, external-change detection).
Relative paths resolve against the agent's workspace. Works local and remote.
Source: Evan, vision session; D-007
Done: 5980d43a6 95eff7499 8516b9867 f25eefc0c 60b6c5f72 e47c78546 f401ac93e cfb66debf 5036f153b 9db8771af a820ef868 53a8e62b8 120129672 90e96b9ea 0b6569257 eca4cfbc1 a0f19db31 5cd057694 676f70548 (1027 tests; the app launches and stays up). Verified: shot B-004-1.png (Open File in Editor shows a highlighted Swift file in a trailing split). ⌘-click was covered by tests only; with only real agents available, clicking into an agent terminal is off limits. Remote was tested against sftp-server over pipes, with no live remote. Leftovers → B-022 (D-034).

## B-022 · Editor pane: close-gate edge, split width, wiring tests   [done]
Accept: (a) MEDIUM: the close gate asks only about editors that were dirty when the close began (`LeoUnsavedEditorsGate.swift:97,122`). An editor edited while a system-quit "Keep Waiting / Quit Anyway" offer is up is never asked. Pass the close's full entries into `Resolution` and re-check `hasUnsavedEdits`, with a test. (b) MEDIUM, plausible: logout with a hung SFTP save relies on a second ⌘Q reaching the delegate while `.terminateLater` is pending; check that on the laptop, or offer leave-anyway from within the pending system quit. (c) The pane opens at its 320 pt minimum, not 50/50; position it after the un-collapse finishes, the way the sidebar restores its width. (d) Tests for the TerminalController wiring: `leoKeepForUnsavedEdits`, the early returns in `closeTabImmediately` and `closeWindowImmediately`, the ⌘W override. (e) LOW: the quit review says "Close Anyway" instead of "Quit Anyway"; the offer sheet queues behind an existing sheet.
Source: B-004 reviews
Done: 59ffb1fbd 4130f9e75 e43aaa796 7a5ef7310 a89b18a3c 363468b41 98a558bdf e89dc3ff6 445437a58 af5762504 9865e60b3 b9dd6e318 eeb6b86b2 bbcf58601 (1095 tests). Verified: shot B-022-1 (at 1400 pt the editor opens at half the width it shares with the terminal). The hung-save banner needs a hung remote save to appear, so it's covered by tests only. 3 fix rounds; the 4th review found only LOWs → B-024.

## B-024 · Editor close-wait polish   [ready (next run)]
Accept: (a) the editor goes read-only whenever the model queue is busy (`LeoEditorPaneModel.swift:85`), even before the unsaved-changes prompt shows (e.g. a close queued behind a slow Recent open); lock only after the prompt is answered. (b) A plain ⌘W close (no quit) waiting behind a hung remote save locks the text with no explanation; show a small "Closing…" notice whenever `isWaitingToClose`. (c) The new gate test's 50 ms negative check would also pass if the wait gave up early; make it assert on an event instead.
Source: B-022 fourth review

## B-025 · Timing-sensitive test flakes under load   [ready (next run)]
Accept: `LeoSidebarFeedActivityCoalescingTests` failed once and `LeoSyntaxHighlighterAdversarialTests` hit its time limits several times and `LeoProcessRunnerTests/timeoutEscalatesToSIGKILL` took 3.9 s against 3 s, all while the machine's load average was ~100 (2026-09-23, B-022/B-020 runs); all passed on rerun. Make both deterministic (inject a clock, or measure work instead of wall time) and prove 10/10 under load.
Source: B-022 implementer runs

## B-005 · Per-agent workspace browser   [done]
Accept: from a sidebar row (context menu + shortcut), browse the agent's
workspace tree via B-003 and open files in B-004's pane. Keyboard navigable.
Source: Evan, vision session; D-007
Done: 864a16bc6 7204dd557 a2620137c 75a0feeef 860df8083 (1069 tests). Verified: shots B-005-1..5 on autopilot-scratch (row menu ▸ Browse Files, arrow and →/← navigation, Return opens a highlighted file, ⇧⌘. shows dotfiles; in an 800 pt window the sidebar collapses so the terminal keeps its room). Remote tested with the SFTP fake only. Polish → B-023.

## B-023 · Workspace browser polish   [ready (next run)]
Accept: (a) hidden files show dimmed when Show Hidden Files is on, like Finder; (b) opening a new root waits for the old SFTP access to finish closing before its first listing (`LeoWorkspaceBrowserModel.swift:153`); start the listing first; (c) the 300 pt terminal floor is only enforced when a pane opens, not when the window narrows or ⌘⇧L shows the sidebar again. Decide whether that matters in use.
Source: B-005 visual check + second review

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
