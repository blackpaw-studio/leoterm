# Backlog

Ranked. Statuses: `ready`, `ready (next run)`, `blocked`, `deferred`, `done`.
Source roadmap: `docs/leo/roadmap.md` on `main` (not edited by autopilot).

## B-001 · Attention model, app side   [done]
Issue: #7
Accept: implement docs/superpowers/specs/2026-09-21-leo-attention-model.md with
D-005 answers (tab focus acks Dock count, row badge stays; focused split =
viewing; ⌃⌥⌘J jump). `LeoAttentionReducer` value type, fixture-driven tests
for every transition. Legacy daemons show Working only. Screenshot row badges
using fixture/scratch data.
Source: roadmap Tier 1
Done: 4e064d6f7 cb18a2a6c 013840a46 465676949 93e0c4f78 60cb67072 f378da52c a0899a492 190b70f4b c5540f3c7 (726 tests). Verified by screenshot with the DEBUG fixture (D-018). Dock badge and notifications were not visually verified.

## B-015 · Attention edge cases before the daemon ships   [done]
Issue: #8
Accept: (a) keep a tombstone incarnation when `retain` drops an agent, so a recreated agent at incarnation 0 isn't suppressed by `lastPosted` (scenario in the final B-001 review); (b) retry a pending /state baseline while the sidebar is hidden (`LeoPollScheduler.swift:125` requires visible), since notifications matter most then; (c) low: a baseline applied outside recovery can falsely bump the incarnation (`LeoAttentionReducer.swift:124`). Each with a failing test first. Must land before the leo daemon ships `attention`.
Source: B-001 final review
Done: c5c24c336 8dfe3aa7c 91fd60791 4fea50a28 a4411496e (866 tests). Also covers leo's 3 live-testing clarifications (unknown never badges; errored survives restart; a fresh row missing the field isn't legacy). Logic only, so not visually verified. Remaining recreate-during-gap edge → B-018.

## B-016 · Tab ↔ row linkage polish   [done]
Issue: #9
Accept: (a) medium, plausible: when clicking a row in a non-key window, the window's activation focus report can land after the tap (it's async via AsyncStream + Task, `LeoAttachCoordinator.swift:74`) and snap the selection back; make the click win deterministically; (b) the row's hover "Attach" button draws over the agent name (shot B-006-3.png); (c) low: `GhosttyAttachTabHost.focusedHandle` uses the controller's focusedSurface, not the first responder, so clicking back into the same terminal after selecting another row doesn't reselect; (d) low: app reactivation sends nil then the real focus, which overwrites an arrow-key selection.
Source: B-006 reviews + visual check
Done: c25cf3523 82c835016 ab3f8c6ff 7d2b676e7 89ff485c9 79f8d61f2 7a3728f4f (867 tests). Verified: shot B-016-1.png (hovered long name truncates before Attach). (a), (c) and (d) are covered by tests only. Test gaps from the review → B-019.

## B-019 · Tests for the host focus sequence and the ordered relay   [done]
Issue: #10
Accept: (a) a host test that collects `lifecycleEvents` around `makeFirstResponder` and checks the exact order: viewing is reported before focus, and focusing the sidebar yields only `.focusChanged(nil)` (`GhosttyAttachTabHostFocusTests.swift:10`); (b) a test that fails if `focusedAgentChanged` stops going through `LeoOrderedRelay` (`LeoRuntime+Attention.swift:10`).
Source: B-016 second review
Done: c92565ac3 ad537d10e 79d5d9375 6be661a48 24000299e (1132 tests). Each test was proven by breaking what it guards (swapped yield order, viewing = focusedHandle, relay bypassed with a Task, a spurious report one hop late). Test-only, so no screenshot. 3 fix rounds; the final HIGH → B-028 (D-045).

## B-028 · Focus test: require the catch-up before asserting   [done]
Issue: #11
Accept: `reports` in `GhosttyAttachTabHostFocusTests.swift:168` ignores a false `caughtUp()`, so an extra yielded report that never reaches the recorder can time out while the order check still passes. Fail the step when `caughtUp()` is false; prove it by dropping one report in the recorder.
Source: B-019 fourth review (D-045)
Done: 256eeec38 1f924ee53 (1132 tests). Each step shares one 20 s deadline and fails at its call site when a report is lost (proven by dropping one in the final step and one mid-sequence). Test-only, so no screenshot. Re-review: MED (drainMainQueue has no deadline) and LOW (a late arrival passes) dismissed: only a main thread stalled for 40 s+ triggers the MED, and the test still fails then.

## B-017 · File-access polish   [done]
Issue: #12
Accept: (a) fix the doc comment in `LeoHostConfiguration.swift:67-71` to say the hash covers the app's argv inputs, not ssh_config aliases; (b) home dirs longer than ~33 chars exceed the control-path budget and lose file access; consider a shorter token or a private short dir; (c) remote errors are vaguer than local ("Failure"); map SFTP status codes more finely where possible.
Source: B-003 reviews
Done: 97781e299 f8b3b4350 fb1bb244b 119697892 198da68e3 adb143d49 1c8ae5131 2f5f51b4d abf708a54 (908 tests). Control sockets now live in the per-user cache dir, a fixed 86 bytes whatever the home dir length; foreign-owned sockets are refused; a vanished socket gets a "Reconnect" message; SFTP errors are specific, and server text and filenames are sanitized. No UI, so no screenshot. Remaining sanitizer gaps → B-020; daemon-socket length → B-021.

## B-020 · Sanitize every error string at one choke point   [done]
Issue: #13
Accept: sanitize `reason`/`detail` once, where it renders (`LeoFileAccessError.errorDescription`), instead of at each source. This closes paths from B-003 that are still raw: the SFTP rename temp name `kept` (`LeoSFTPFileBackend.swift:120`), Foundation's `localizedDescription`, which embeds raw local filenames (`LeoLocalFileBackend.swift:145`, `LeoFileAccessError.swift:44`), and the transport's `describe(error)` (`LeoSFTPTransport.swift:124`). Also: add the missing double-quote lookalikes (U+2E42, U+1F676–1F678, U+05F4, U+02BA, U+3003, U+02DD); wrap interpolated names in FSI…PDI so RTL names can't reorder the surrounding text; raise the mark cap to 3–4 for Hebrew and Indic text; keep tag characters after U+1F3F4 (subdivision flags). Test first, with a spoofing filename through every backend.
Source: B-017 third security review (D-032)
Done: ad0807785 796b0a2ec 8b6494d45 935b5a600 (1122 tests). Errors are sanitized once where they render; untrusted parts are wrapped in FSI…PDI; invisible characters survive only from an allowlist (D-042). Error text only, so not visually verified. 3 fix rounds; the last review's HIGH → B-026 (D-043).

## B-026 · Presentation selectors only after emoji   [done]
Issue: #14
Accept: (a) HIGH: FE0E/FE0F survive after any visible character (`LeoTextCleaner.swift:97-99,128-132`), so a filename can carry ~1.58 hidden bits per character. Keep them only right after a pictographic base (the same check the ZWJ rule uses). The property test (`randomInvisiblesLeaveAtMostOneZeroWidthScalarPerVisibleCharacter`) passes either way; add a test that a selector after a letter is dropped. (b) NIT: ZWNJ checks only the next scalar is a letter (`:104-105`); check the previous one too. (c) The SFTP security review role (codex/gpt-6-sol) failed with "Model metadata not found" all run; B-020 was reviewed by the Sonnet fallback.
Source: B-020 final review (D-043)
Done: e5efc61b4 ac9539839 5a44072dd 03ac88d26 (1136 tests). Every surviving invisible now changes what's drawn and the output is NFC (D-046, D-047), using Unicode 18 tables. (c): review.security routed fine today. Error text only, so no screenshot. 3 fix rounds; the 4th review was clean. The dismissed LOW → B-029.

## B-029 · Cleaner: prefix trie for ZWJ matching; ICU-version drift   [done]
Issue: #15
Accept: (a) longest-match ZWJ tries every RGI sequence that starts with the first scalar (356 for 👩); a run of ~1,600 👩 costs ~570k candidate checks, bounded only by the scan limit. Use a prefix trie, with a timing test on a worst-case run. (b) The Unicode 18 base lists sit next to `isEmojiPresentation`, which comes from the OS's ICU; add a test that every embedded variation base has a defined presentation under the running ICU, so drift shows up.
Source: B-026 third review (LOW)
Done: 0747da6d4 cef6e152a (1249 tests). 👩×1,600: 574,400 → ~3,200 steps. Differential over 35,546 inputs: 0 differences. All 371 variation bases are emoji under this machine's ICU (D-066). review.security clean. No UI change, so no screenshot.

## B-021 · Forwarded daemon socket path budget   [done]
Issue: #16
Accept: the forwarded daemon socket in `~/.leo/state/leoterm/` has a 100-byte limit, so home directories longer than roughly 38–58 characters (depending on host name) break the whole tunnel. Move it to the same private per-user cache dir as the control sockets (`LeoControlSocketDirectory`), with the same checks. Failing test first with a long fake home.
Source: B-017 implementer report
Done: cda6610e8 (1130 tests; 8 new in LeoTunnelSocketPathTests, which failed first). No UI and no remote host, so not visually verified. Review: one MEDIUM, dismissed (D-044) → B-027.

## B-027 · One tunnel per host, enforced   [done]
Issue: #17
Accept: (a) `LeoTunnel.removeStaleSocket` (`LeoTunnel.swift:186-190`) unlinks whatever is at the bind path. It's safe today only because `LeoRuntime` shares one `LeoHostSelection`; `LeoAgentActions` can still build its own (`hostSelection ?? LeoHostSelection(...)`). Make a second live tunnel for the same host impossible by construction (remove the fallback or route through one owner), and have the unlink go through `LeoControlSocket` so it can tell an orphaned forward from a live sibling. (b) Tunnel records saved before B-021 point at the old path; add a test for the launch-time cleanup. (c) `LeoSocketActivityClient` (`:57-89`) retries the event stream on an exponential backoff. That's an auto-reconnect timer, against principle 5; fold it into B-007's manual Retry.
Source: B-021 review + implementer report
Plan (D-051): single-instance per bundle at launch; then (a) = remove the `LeoAgentActions` fallback, (b) = the launch-cleanup test, (c) stays in B-007.
Question: architecture may be wrong. After 3 fix rounds (77957fcdf probe → 9bdf7cb22 flock per path (D-049) → 07e8aaa59 → 93032ed6e per-path records + confirmed reaping), every review still found new HIGHs, all about two copies of the same bundle racing over shared tunnel state: an ssh started before its record is written, a record cleared after the lock is released, and (new) a kept lock that Retry can never recover. Reverted in 75f5b8eda; the code is as before B-027. I'd pick making Leo single-instance per bundle (an app-level lock at launch; a second copy activates the first and quits). Then only crash orphans remain, which the old reap already handles, and (a) shrinks to removing the `LeoAgentActions` fallback plus the (b) test. That removes running two copies of the same build side by side (`open -n`), so it's your call.
Answer: yes — make Leo single-instance per bundle (a second copy activates the first and quits), as recommended.
Done: 10be4b608 6fec65c82 67de1e864 682f967c4 73109b6c3 (1163 tests). Leo is single-instance per bundle ID (D-051); an unsafe lock path fails closed with an alert (D-053); `LeoAgentActions` takes the runtime's one `LeoHostSelection`; legacy records are cleared, never signalled. Verified: shots B-027-1 (a second `open -n` exits, the first stays frontmost) and B-027-2 (the "Leo can't start" alert for a symlinked lock). 1 fix round; re-review clean. Note: 10be4b608 and 6fec65c82 also carry a 1 MB `macos/default.profraw`, untracked again in 682f967c4 (history not rewritten).

## B-032 · Tests leak tunnel sockets into the real cache dir   [done]
Issue: #18
Accept: the per-user cache dir (`$(getconf DARWIN_USER_CACHE_DIR)leo`) held ~70 stale `lt-a14bb2a8-*.sock` files (plus a few `.sock.lock`) timestamped through today's test runs. Find the tests that create them, point them at a temp dir (inject the directory), and add a check that a full run leaves the real dir unchanged. Don't delete the existing files; list them in the report.
Source: B-027 visual check
Done: f6a591e0a 41a653cfd aeb23c6b5 b03191132 (1244 tests). Root cause: `LeoRuntimeConnectionTests.failureDuringGatedFlavorDetection…` built a LeoRuntime on the real socket dir and SIGKILLed the fake ssh; six more test sites used real dirs. The `.sock.lock` files came from the reverted B-027 attempt. A bundle guard now fails the run if the real dirs gain entries (D-064). Existing files left in place: 116 `lt-a14bb2a8-*.sock`, 5 `*.sock.lock`, 1 instance lock (2026-09-23 11:38–21:54), plus the old `/tmp/leoterm-tests-hosts`. Test-only, so no screenshot. 2 fix rounds.

## B-033 · "Leo can't start" alert: readable path   [done]
Issue: #19
Accept: the alert prints the full `/var/folders/…/C/leo/…instance.lock` path, which wraps mid-word (shot B-027-2). Abbreviate it (e.g. `…/leo/<file>`) and add a "Show in Finder" button next to Quit.
Source: B-027 visual check
Done: 7dd3ea2bf f93fab899 e2736fec7 (1269 tests). The sentence is path-free; `…/leo/<file>` sits on one middle-truncated line with the full path as tooltip; Show in Finder reveals the lock (or its folder if it's gone) and keeps the alert up (D-069, D-070). Verified: shots B-033-1 (first build, mid-word break) and B-033-2 (fixed). Show in Finder not clicked live: the alert's AX tree is unreachable (same as B-035); unit-tested through an injected reveal. 2 fix rounds.

## B-034 · DEBUG hook to open a file in the editor at launch   [done]
Issue: #20
Accept: GUI checks of the editor can't get past the Open File panel (Peekaboo: axElementNotFound / focusVerificationTimeout; osascript keystrokes not allowed). Add a DEBUG-only `LEO_OPEN_FILE=<absolute path>` env that opens that local file in the editor pane of the first window once it's up, like Open File in Editor. It must compile out of release builds, with a test. Then screenshot B-024's `Closing “…”…` banner (launch with `LEO_SLOW_SAVE_SECONDS=30`, edit, ⌘S, ⌘W).
Source: B-030 visual check
Done: 2c05c0b83 de2c47114 (1177 tests). Verified: shot B-034-1 (`LEO_OPEN_FILE` opens demo.swift in the first window's editor pane). The banner shot is still missing → B-035. 1 fix round; re-review found only a LOW (dismissed, D-056).

## B-035 · Screenshot the editor's "Closing…" banner   [done]
Issue: #21
Accept: capture B-024's `Closing “…”…` banner (debug app with `LEO_OPEN_FILE` + `LEO_SLOW_SAVE_SECONDS=30`). Typing into the editor works with `peekaboo type --foreground --window-id`, but after ⌘W the "Save changes?" alert can't be reached (axElementNotFound for its window, also via `peekaboo dialog`), and `peekaboo press cmd+s` didn't seem to save. Try File ▸ Save via `peekaboo menu click`, then File ▸ Close while the save runs. If alerts stay unreachable, say what would unblock it.
Source: B-034 visual check
Done: verification only, no code. Shots B-035-2 (the "Do you want to save…" alert, captured by its window id), B-035-4 (`⌛ Closing “b035.txt”…` while a 30 s held save runs), B-035-5 (pane gone once the save landed; file on disk has the edit). Unblocked by a global `peekaboo press return --foreground` after checking the debug app is frontmost (the alert has no AX element). Recipe in verify.md. Polish → B-045.

## B-018 · Drop the recreate heuristic: dedupe on (boot, name, revision)   [done]
Issue: #22
Accept: leo confirmed (2026-09-22, spec addition) that a revision is monotonic per agent NAME per boot, including across delete and recreate; revisions only go backwards when boot_id changes. So remove the backwards-revision heuristic from `LeoAttentionReducer` (incarnation bumps on retain/recovery, tombstones and their 64-cap, `droppedFloors`) and key notification dedupe on (bootID, name, revision). A revision ≤ the last seen for that name in the same boot is a duplicate; a recreated agent simply continues at higher revisions. Keep: list-driven deletion of display state, reset on boot change or host switch, and everything from B-015's (b), (d), (e), (f). Rewrite or delete the heuristic's tests; add fixture tests for the three gaps from B-015's third review (a recreated agent's first signal buffered during recovery notifies; an agent re-added by a baseline at the same revision keeps its Dock acknowledgement; a first seen revision equal to the old floor is a duplicate by contract).
Source: B-015 third review + leo reply (D-027)
Done: f2ed8537a (858 tests; 12 heuristic tests removed, 4 contract tests added; 126 fewer lines). Review clean; 3 LOWs dismissed (D-028). Logic only, so not visually verified.

## B-002 · Request daemon `attention` field from the leo agent   [done]
Issue: #23
Accept: send the leo agent the exact contract from the spec's "Leo-daemon
prerequisite" section; log the reply/ETA in DECISIONS.md. No leo repo edits.
Source: attention spec; D-006
Done: contract sent 2026-09-22 (D-010); leo accepted in principle, ETA pending Evan's approval of the daemon spec (D-011).

## B-003 · File access layer (local FS + SFTP)   [done]
Issue: #24
Accept: one `LeoFileAccess` protocol, local backend and SFTP backend over the
existing SSH ControlMaster for the selected host; list dir, read, write
(atomic), stat/mtime conflict check. Tests with a local sshd or fake.
Source: Evan, vision session; D-003, D-007
Done: 7fd10dad9 6f92f70e9 9b466088a a0b838dcd 1c7c93e5f 7858fbda8 4ee7c8353 515e6554b e780ead10 6f52a67c8 da7fca9c4 (839 tests; the shared contract suite runs against local, sftp-server over pipes, chunked, and no-posix-rename). No UI, so no screenshot. The opt-in E2E against localhost reached the real ControlMaster, but SFTP is disabled in this Mac's sshd_config.

## B-004 · Editor pane for surfaced files   [done]
Issue: #25
Accept: ⌘-click a path / OSC 8 link in an agent's terminal opens it in a Leo
editor pane (syntax highlight, edit, ⌘S save, external-change detection).
Relative paths resolve against the agent's workspace. Works local and remote.
Source: Evan, vision session; D-007
Done: 5980d43a6 95eff7499 8516b9867 f25eefc0c 60b6c5f72 e47c78546 f401ac93e cfb66debf 5036f153b 9db8771af a820ef868 53a8e62b8 120129672 90e96b9ea 0b6569257 eca4cfbc1 a0f19db31 5cd057694 676f70548 (1027 tests; the app launches and stays up). Verified: shot B-004-1.png (Open File in Editor shows a highlighted Swift file in a trailing split). ⌘-click was covered by tests only; with only real agents available, clicking into an agent terminal is off limits. Remote was tested against sftp-server over pipes, with no live remote. Leftovers → B-022 (D-034).

## B-022 · Editor pane: close-gate edge, split width, wiring tests   [done]
Issue: #26
Accept: (a) MEDIUM: the close gate asks only about editors that were dirty when the close began (`LeoUnsavedEditorsGate.swift:97,122`). An editor edited while a system-quit "Keep Waiting / Quit Anyway" offer is up is never asked. Pass the close's full entries into `Resolution` and re-check `hasUnsavedEdits`, with a test. (b) MEDIUM, plausible: logout with a hung SFTP save relies on a second ⌘Q reaching the delegate while `.terminateLater` is pending; check that on the laptop, or offer leave-anyway from within the pending system quit. (c) The pane opens at its 320 pt minimum, not 50/50; position it after the un-collapse finishes, the way the sidebar restores its width. (d) Tests for the TerminalController wiring: `leoKeepForUnsavedEdits`, the early returns in `closeTabImmediately` and `closeWindowImmediately`, the ⌘W override. (e) LOW: the quit review says "Close Anyway" instead of "Quit Anyway"; the offer sheet queues behind an existing sheet.
Source: B-004 reviews
Done: 59ffb1fbd 4130f9e75 e43aaa796 7a5ef7310 a89b18a3c 363468b41 98a558bdf e89dc3ff6 445437a58 af5762504 9865e60b3 b9dd6e318 eeb6b86b2 bbcf58601 (1095 tests). Verified: shot B-022-1 (at 1400 pt the editor opens at half the width it shares with the terminal). The hung-save banner needs a hung remote save to appear, so it's covered by tests only. 3 fix rounds; the 4th review found only LOWs → B-024.

## B-024 · Editor close-wait polish   [done]
Issue: #27
Accept: (a) the editor goes read-only whenever the model queue is busy (`LeoEditorPaneModel.swift:85`), even before the unsaved-changes prompt shows (e.g. a close queued behind a slow Recent open); lock only after the prompt is answered. (b) A plain ⌘W close (no quit) waiting behind a hung remote save locks the text with no explanation; show a small "Closing…" notice whenever `isWaitingToClose`. (c) The new gate test's 50 ms negative check would also pass if the wait gave up early; make it assert on an event instead.
Source: B-022 fourth review
Done: 810596a0a 188851f1f 6a6be8646 7d10d709e 605d43e68 (1145 tests). The text locks only once a close is committed (per-close tokens; the model refuses edits synchronously); `Closing “<file>”…` banner; the gate test waits on an event; DEBUG `LEO_SLOW_SAVE_SECONDS=<n>` delays saves so the banner can be seen. Not visually verified: auto mode refused peekaboo type/press/click, so the Open File dialog couldn't be submitted. 2 fix rounds; the 3rd review found only a LOW → B-030.

## B-030 · Editor: keep the selection when a racing keystroke is refused   [done]
Issue: #28
Accept: a keystroke that races the close lock reloads with `keepingSelection: true`, but `LeoEditorTextView.swift:74` collapses the selection to a caret; if the save then fails and the pane unlocks, the selection is gone. Keep the full range, with a test. Also screenshot B-024's `Closing “…”…` banner (launch with `LEO_SLOW_SAVE_SECONDS=30`) once GUI input is allowed again.
Source: B-024 third review
Done: 31a72e027 0fd885414 ca7f95730 (1171 tests). A refused keystroke restores the whole selection, snapped to whole characters; reloads keep a caret (D-055). Not visually verified: Peekaboo can't focus the Open File panel and osascript may not send keystrokes, so no file could be opened; the banner shot moves to B-034. 2 fix rounds (the first implementer window was lost; a fresh one did round 2); 3rd review clean.

## B-025 · Timing-sensitive test flakes under load   [done]
Issue: #29
Accept: `LeoSidebarFeedActivityCoalescingTests` failed once and `LeoSyntaxHighlighterAdversarialTests` hit its time limits several times and `LeoProcessRunnerTests/timeoutEscalatesToSIGKILL` took 3.9 s against 3 s, all while the machine's load average was ~100 (2026-09-23, B-022/B-020 runs); all passed on rerun. Make both deterministic (inject a clock, or measure work instead of wall time) and prove 10/10 under load.
Source: B-022 implementer runs
Done: cbc79e25c ba6e9d140 e37de61ee 1f96bee20 4eb3f5fa5 6e1267756 ba23155a9 (1146 tests). SIGKILL escalation driven by an injected `LeoProcessScheduler` (+ a `.dispatch` test); the highlighter counts ICU match steps instead of timing (budget 1 tick/128 chars); the coalescing tests use an event-driven fake clock. Each passed 10/10 under 28× `yes` load and each was proven by breaking what it guards. Test-only, so no screenshot. 3 fix rounds; the final MED (pid reused by another child in the failure-only cleanup) dismissed.

## B-031 · Flake: LeoSidebarFeedFixTests/sseRefreshTask…   [done]
Issue: #30
Accept: `sseRefreshTaskReplacesAPendingPredecessorAndIsCancelledOnStop` failed once at load ~245 (`clock.sleepCount == 1`). Its test clock removes cancelled sleeps asynchronously, the pattern B-025 replaced in the coalescing tests; apply the same fix and prove 10/10 under load.
Source: B-025 implementer run
Also seen (B-034, 2026-09-23): one full run stopped after 828 of 1177 tests with no summary and no crash marker; the rerun passed. Find out why.
Done: 05ec8fd2d 3e3859708 235748c7a b32c98cd4 40fdb2b8a (1180 tests). The SSE test uses the shared firing clock and checks exact pending sleeps (10/10 under 28× `yes`; proven by removing each cancel). The 828-test stop was the script's 400 s timeout on a heavily loaded machine; the script now fails loudly (D-057). Also fixed: parallel `xcodebuild test` hosts were quit by the single-instance check. Test-only and launch-time logic, so no screenshot. 2 fix rounds; 3rd review clean. Other load flakes → B-036.

## B-036 · More sidebar-feed flakes under load   [done]
Issue: #31
Also seen once (B-032 run): `LeoSidebarFeedDisconnectTests/aPassingWakeCheckChangesNothingAndIsNotRepeated`.
Accept: under 4× load (B-031 run) `LeoSidebarFeedRecoveryTests` failed 19 times (~4 s each), `LeoSidebarFeedAttentionRaceTests` 4, `LeoSidebarFeedHostSwitchTests` and `LeoSidebarTests` once each. Find each root cause, move them onto `LeoFiringClock` or event-driven waits, prove 10/10 under load and that each still fails when its behavior is broken.
Source: B-031 implementer run
Done: 744ff0a71 fa3a8ff43 c4498f88e d32b2f060 0a9f77d2f b301bc587 (1244 tests). All 13 LeoSidebar* suites 10/10 under 42× load (2020/2020); each flaky test failed when its behavior was broken. Causes: wall-clock deadlines, a Disconnect count taken before the post-baseline emission, an AttentionRace restart wait satisfied too early, and a defaults domain shared across parallel hosts. No product race (D-065). Test-only. The first implementer hung in a hook and was replaced. Follow-ups → B-039, B-040.

## B-039 · Tests leave empty preference plists behind   [done]
Issue: #32
Accept: `~/Library/Preferences` holds ~830 empty stubs from test runs (737 `LeoSidebarFeedRecoveryTests.picker.<UUID>`, 45 `…visible.<UUID>`, 44 `LeoSidebarTests.widths.<UUID>`, plus fixed-name ones); `removePersistentDomain` doesn't remove the file. Inject an in-memory defaults store (or a single reused suite per test class, cleared per test) so a full run adds no plist files, and add that to the B-032 bundle guard. Don't delete the existing stubs; list them.
Source: B-036 review
Done: 558a0585e a00d37484 b9cc40d4b (1360 tests). Tests use an in-memory `UserDefaults` subclass; the bundle guard fails on any new `Leo*Tests*`/`Ghostty*Tests*` plist (D-080). Full run: 0 new plists (was +74). Break-checked (a real suite back in `LeoSidebarTests.widths` → guard fails). 1 fix round; 1 LOW dismissed. Test-only. Stubs → B-044.

## B-044 · Delete the old test preference stubs   [done]
Issue: #33
Accept: ~/Library/Preferences on Dionysus holds 31,098 empty stubs from old test runs (list: /private/tmp/b039-stubs.txt; mostly `Leo*Tests.<UUID>.plist` and 4,220 bare `<UUID>.plist`). B-039 stopped new ones.
Question: Needs Evan to do: deleting user files is on the Never list. OK to move the `Leo*Tests*` ones (not the bare UUIDs, which may not all be ours) to the Trash? I'd pick yes; the bare UUIDs stay.
Answer: accept your recommendation (yes; the bare UUIDs stay)
Needs Evan to do: moving files to the Trash is still on the Never list (an answer settles the call, not the action). Run on Dionysus: `mkdir -p ~/.Trash/leo-test-stubs && find ~/Library/Preferences -maxdepth 1 -name 'Leo*Tests*.plist' -exec mv {} ~/.Trash/leo-test-stubs/ +`, then mark this done.
Done: by Evan 2026-09-24: 26,878 `Leo*Tests*.plist` moved to ~/.Trash/leo-test-stubs; bare UUID plists untouched (D-089). No commits.

## B-040 · AttentionRace: `…RecoveryListIsStillInFlight` doesn't guard boot reset   [done]
Issue: #34
Accept: the test still passes with boot reset disabled, because no fetch returns the old boot's data; it fails only when the recovery baseline is skipped. Redesign it so an old-boot answer arrives in flight and the test fails when boot reset is broken.
Source: B-036 implementer break-check
Done: 669c92d1f 892b6f18e fb92b79d9 (1352 tests). Test-only: an old boot's buffered needs_input now outranks the new baseline unless boot reset works (D-079). Break-checked (boot reset off, post-restart baseline skipped: both fail); 10/10 under 3× core-count load. 2 fix rounds (review.concurrency: list deadline race, fetch-count ambiguity); 1 LOW dismissed. Not visually verified (test-only).

## B-005 · Per-agent workspace browser   [done]
Issue: #35
Accept: from a sidebar row (context menu + shortcut), browse the agent's
workspace tree via B-003 and open files in B-004's pane. Keyboard navigable.
Source: Evan, vision session; D-007
Done: 864a16bc6 7204dd557 a2620137c 75a0feeef 860df8083 (1069 tests). Verified: shots B-005-1..5 on autopilot-scratch (row menu ▸ Browse Files, arrow and →/← navigation, Return opens a highlighted file, ⇧⌘. shows dotfiles; in an 800 pt window the sidebar collapses so the terminal keeps its room). Remote tested with the SFTP fake only. Polish → B-023.

## B-023 · Workspace browser polish   [done]
Issue: #36
Accept: (a) hidden files show dimmed when Show Hidden Files is on, like Finder; (b) opening a new root waits for the old SFTP access to finish closing before its first listing (`LeoWorkspaceBrowserModel.swift:153`); start the listing first; (c) the 300 pt terminal floor is only enforced when a pane opens, not when the window narrows or ⌘⇧L shows the sidebar again. Decide whether that matters in use.
Source: B-005 visual check + second review
Done: 30233456a aa5f8d878 39441c27d 36aee4e9e fac40cd67 b6a773954 f8c0c7c77 abd49da71 459098e6b (1207 tests). Hidden entries dim; a new root lists at once and the old access closes immediately and for good; the terminal keeps 300 pt on resize and ⌘⇧L is greyed out when the sidebar can't fit (D-058, D-059, D-060). Verified: shots B-023-1 (at 700 pt the terminal holds 300, the editor gives way) and B-023-2 (back at 1400 the editor regains its width). (a) and (b) are covered by tests only (no autopilot-scratch agent to browse). 2 fix rounds; the 3rd review's two P2s dismissed (D-060). Sidebar return on a single jump → B-037.

## B-037 · Floor-collapsed sidebar doesn't return on a single big widen   [done]
Issue: #37
Accept: with the editor open, resizing 1400 → 700 → 1400 in single jumps brings the editor back but not the sidebar (shot B-023-2); in the round-1 build it did come back. D-059 says a floor-collapsed sidebar returns once the terminal keeps 300 + 24 pt. Add the single-jump case to the real-window harness and fix.
Source: B-023 visual check
Done: 9307c661c (1239 tests). Two causes: a divider move after regrowth never re-checked the sidebar, and the editor's width was recorded after NSSplitView had already shrunk it (D-063). Verified: shots B-037-1/2/3 (1400 → 700 → 1400 in single jumps: the sidebar and the editor's full width both return). Review clean.

## B-006 · Tab ↔ row linkage   [done]
Issue: #38
Accept: highlighted row follows the focused attach tab; tab-count glyph on rows
with live tabs; clicking a highlighted row focuses its tab.
Source: roadmap Tier 2
Done: 54ae397a2 e05e818b7 71d366ad1 e07fa6b65 (744 tests). Verified with shots B-006-1..4 using autopilot-scratch.

## B-007 · Disconnected state   [done]
Issue: #39
Accept: on tunnel drop or wake, grey the list and show a Retry banner instead
of stale rows. Manual retry only. Includes B-027(c): replace `LeoSocketActivityClient`'s exponential-backoff stream retry with this Retry (D-048).
Source: roadmap Tier 2
Done: 7a2bf5da5 4f1cd16b7 0ed8a6b8f (1237 tests). A dropped stream, a dead tunnel or a failed wake check dims the rows and shows "Disconnected from <host>" with Retry (Agents ▸ Reconnect, ⇧⌘R); the backoff is gone (D-061, D-062). Verified: shots B-007-1 (banner over dimmed rows) and B-007-2 (Reconnect restores rows and badges), on the first build; the 2 fix rounds changed phase ordering and error sanitizing only. Banner polish → B-038.

## B-038 · Disconnected banner: reason text wraps mid-word   [done]
Issue: #40
Accept: in the default-width sidebar the banner's reason breaks mid-identifier (shot B-007-1: "LEO_-FORCE_DISCO…"), and the main pane's "Choose Agent…" stays enabled while disconnected. Truncate the reason to one line with the full text in a tooltip, and disable or explain Choose Agent while disconnected.
Source: B-007 visual check
Done: 622783dad d1e8e149a (1254 tests). The reason is one line with the full text as a tooltip; Choose Agent… is disabled (plain bordered) with "Disconnected from <host>. Reconnect first (⇧⌘R)." (D-067, D-068). Verified: shots B-038-1 (one-line reason), B-038-2 (visibly disabled button). 1 fix round. New: B-041.

## B-041 · Palette's disconnected row: same one-line treatment   [done]
Issue: #41
Accept: the command palette's disconnected row shows the same banner text as the sidebar but wasn't given B-038's one-line truncation + tooltip. Match it.
Source: B-038 implementer
Done: 40966ae59 (1347 tests). The palette row reuses the sidebar's banner value: one-line reason, tooltip, accessibility label (D-077). Verified: shot B-041-2 (palette row, `LEO_FORCE_DISCONNECTED=1`, New Tab); the forced reason is short, so the "…" isn't visible. Review: 1 LOW dismissed.

## B-008 · Fix order-dependent test flake + swiftlint baseline   [done]
Issue: #42
Accept: `LeoHostSelectionReloadTests.editingAnUnrelatedHostDoesNotReselect`
passes 10/10 in full serial runs (pid-file read race in
`LeoHostSelectionTestSupport`); clear the 3 `large_tuple` violations in
`macos/Tests/Leo/LeoAttachCoordinatorTests.swift:316-319`.
Source: roadmap Test infra; vision-session test run
Done: d806f8ecf c3edaf507 a80bd0475. Root cause: fake_ssh wrote the pid file non-atomically. 10/10 full runs; swiftlint clean. Also fixed the Observe 50 ms deadline flake. Test-only change, so no screenshot.

## B-009 · Search polish   [done]
Issue: #43
Accept: ⌘F focuses the sidebar filter, fuzzy match, Escape clears.
Source: roadmap Tier 2
Done: 93a8c5b9f 823a717fb 03974e177 (1309 tests). Agents ▸ Find Agent… (⌥⌘F, since ⌘F is Ghostty's Find) shows and focuses the filter; ranked fuzzy match with bold matched letters; Escape clears, then returns focus; Return = click the top row (D-071, D-072). Verified: shots B-009-1 ("lha" → leo-home-assistant), B-009-2 (Escape clears), B-009-3 (hidden sidebar → shown + focused, bold "vit"). 1 fix round. New: B-042.

## B-042 · Agent palette: use the sidebar's fuzzy matcher   [done]
Issue: #44
Accept: the agent palette (Choose Agent… / ⌘T picker) still uses substring filtering. Reuse `LeoFuzzyMatcher` ranking and bolding so both searches behave the same.
Source: B-009 implementer
Done: 9a355633e (1352 tests). Palette ranks and bolds with `LeoFuzzyMatcher`; secondary field is repo (D-078). Verified: shot B-042-1 ("lha" → leo-home-assistant on top, bold letters). Review clean.

## B-010 · Sort and pin   [done]
Issue: #45
Accept: default sort by last activity; pin favourites to top; remember
collapsed sections.
Source: roadmap Tier 2
Question: architecture may be wrong — the pin, collapse, Name sort and menus all worked (shots B-010-2..5), but advancing Last Activity from live `agent_activity` events keyed only by agent NAME failed review 4 times running: a stale /observe/state fetch or SSE recovery can put a deleted agent's activity on a recreated namesake, or drop a just-spawned agent's activity (commits c7e629b18..94cb3a42b, reverted in f6dfc8aec). I'd pick re-scoping it: sort by `last_activity_at` from /observe/state snapshots only (no event-driven reordering, which is also calmer), and ship pins/collapse/Name sort as they were. The alternative is asking the leo agent for a per-agent incarnation id on list/state/events so activity can be keyed by (name, incarnation). OK to re-scope?
Answer: accept your recommendation (re-scoping it: sort by `last_activity_at` from /observe/state snapshots only (no event-driven reordering, which is also calmer), and ship pins/collapse/Name sort as they were)
Done: dfe6f29e8 (1393 tests). Snapshot-only Last Activity sort (D-082, D-085); pins (⌥⌘P, row menu), collapsible sections per host, Sort By ▸ Last Activity / Name restored from the reverted attempt minus event-driven activity. Verified: shots B-010-1 (Pinned + activity order) and B-010-2 (Name sort). Review clean.

## B-011 · Row metadata   [done]
Issue: #46
Accept: relative "last active" time and current task line; tokens/cost only
when the daemon exposes them.
Source: roadmap Tier 2
Done: a8b800d41 fd679d90a 8b5808341 (1338 tests). Rows show "· 13h" / "· Sep 23" from identity-checked /observe/state snapshots (`started_at` match), and a task line when the daemon reports `current_action` (none live today). Tokens/cost aren't exposed per agent, so they're omitted (D-074, D-075). Verified: shots B-011-1 (first build, time truncated) and B-011-2 (time always shown). Task line not seen live (no agent reports one); unit-tested. 2 fix rounds. New: B-043.

## B-043 · Row subtitle squeezes the template to "clau…"   [done]
Issue: #47
Accept: at default sidebar width, B-011's never-truncating time squeezes the template to "clau…" or "…" (shot B-011-2). Drop the template from the subtitle when it can't fit at least ~5 characters, or move the time to the trailing badge column, so the line reads cleanly.
Source: B-011 visual check
Done: bb7b9f81c 94685a65c (1346 tests). The template drops when fewer than 5 chars would show; a template that fits whole always shows (D-076). Verified: shot B-043-1 ("claude · Finished · 16h", "assist… · Finished · 16h"). 1 fix round (review MED: whole-fit check first); re-review clean.

## B-045 · Editor "Closing…" banner replaces the header with a near-empty strip   [done]
Issue: #48
Accept: while a close waits on a save (shot B-035-4), the pane's header row (file name, path, mode) disappears and the banner sits alone at the right edge of an otherwise blank strip. Keep the header visible and show the banner as its own leading-aligned row (or in the header's trailing status slot), matching the other editor banners.
Source: B-035 visual check
Done: 10ec5d41f 350a88ecc f778624b5 (1395 tests). Two causes: the pane's stack didn't stretch rows (banner hugged the right edge), and `LeoEditorBannerView.draw` filled the whole dirtyRect, which macOS 14+ lets reach past its bounds, painting over the header and separator. Rows pinned to the pane width; the fill clipped to bounds (D-090). Verified: shot B-045-2.png (header, Edited, separator and a leading `Closing …` row during a held save). 2 fix rounds (header overpaint found by screenshot; test cleanup in defer). 2 review P2s on test strength dismissed (only on an already-failing path; the flat-header regression and the cause are both guarded).

## B-012 · Cold start   [done]
Issue: #49
Accept: measure launch with sidebar visible; if first fetch blocks first
paint, render cached last snapshot and refresh in place.
Source: roadmap Tier 3
Done: e45d323fb 826e921ee (1393 tests). Measured, no product change needed (D-087): 4 cold launches, 103 agents, local daemon: sidebar appears at +378–400 ms, list lands at +500–523 ms (~120 ms of "Loading agents…"); the fetch doesn't block first paint, so no snapshot cache. DEBUG-only `LaunchTiming` log category kept for re-measuring (`/usr/bin/log show --predicate 'category == "LaunchTiming"'`). Remote (tunnel) cold start not measured: no autopilot remote host. Not visually verified (measurement only).

## B-013 · Daemon-pushed "surface file" event   [done]
Issue: #50
Accept: an agent calls a leo tool; the daemon emits a file-surfaced event;
Leo badges the row and opens/queues the file.
Old-Question: needs a leo daemon change — request it from the leo agent after
B-004 ships, or wait for you? — I'd pick requesting it after B-004 ships.
Old-Answer: accept your recommendation (requesting it after B-004 ships)
Daemon: contract sent and approved by Evan via the leo agent 2026-09-24 (D-086); leo is building it, no restart, release at Evan's call.
Question: architecture may be wrong — decode, incarnation-keyed badge, Surfaced Files menus, ⌥⌘O and the path/regular-file/size/SFTP-timeout hardening all passed review, but AUTO-OPENING a file when the agent's tab is focused failed review 4 times running, each fix exposing a new race: new incarnation opening in an old tab; stale stat replacing a newer file; then a queued open always dropped and a closed pane reopening (commits 30fe234bf..69b736464, reverted in f3e8d36b3). I'd pick dropping auto-open: badge only, and you open with ⌥⌘O / the row's Surfaced Files menu (calmer, never steals the pane). The rest re-applies from those commits. OK?
Answer: yes — drop auto-open; surfaced files are badge-only, opened with ⌥⌘O / the row Surfaced Files menu; re-apply the rest from 30fe234bf..69b736464
Done: 70a2b21e8 eed22646d 813d4f335 263040196 (1459 tests). Re-applied f3e8d36b3's revert minus all auto-open (D-088): badge only; opens via row ▸ Surfaced Files ▸ or Agents ▸ Open Surfaced File (⌥⌘O, needs a selected row). Pane re-checks the incarnation after the read and after the unsaved prompt; identity and seen ledger keyed by agent + started_at + id; live events ordered by `at` (D-091). Verified: shots B-013-1 (row badge 2), B-013-2-screen (Surfaced Files submenu, screen capture), B-013-3 (menu open → notes.md at line 3, badge 1), B-013-4 (⌥⌘O → plan.py, badge cleared), with a DEBUG `LEO_SURFACE_FIXTURE` on a temporary autopilot-scratch (deleted). Daemon side not released, so fixture only; remote not visually verified. 2 fix rounds (review.concurrency: open-queue identity HIGH, id-only identity, baseline ordering ×3); 2 round-3 P2s dismissed → B-046.

## B-014 · All hosts at once as sidebar sections   [deferred]
Question: deferred by D-008 until several remotes are in daily use. Tell me
when that's true. — I'd pick keeping it deferred.
Answer: accept your recommendation (keeping it deferred)

## B-046 · Surfaced files: keep `at` order through a partial /state merge   [done]
Issue: #51
Accept: a partial baseline appends event-only files as newest, so `[t1, t2(live), t3]` becomes `[t1, t3, t2]` and ⌥⌘O picks t2 (`LeoSurfacedFileIndex.swift:64`). Place event-only files by `at` when merging. Also: a full (20-sent) baseline whose entries are all malformed returns early and leaves stale live files (`:59`); treat it as an empty full baseline. Failing tests first.
Source: B-013 third review (dismissed as non-blocking)
Done: a91e50296 a70d51027 (1463 tests). Event-only files placed by `at` in partial merges (shared rule with live events); an all-malformed full baseline clears stale live files; cleared incarnations leave the 64-slot LRU (D-092). Tests: partial-merge order, ⌥⌘O picks t3 after `[t1, t2(live), t3]` (red on pre-B-046 code), malformed full baseline, cleared-incarnation bound. Not visually verified: index-only change, no UI change. 1 fix round (review.concurrency LOW: empty cleared entry held an LRU slot); round 2 clean.


## B-047 · One tab per agent — sidebar and palette focus the existing tab   [ready]
Issue: #52
Why: Clicking an agent row, or choosing an agent in the palette (Choose Agent… / ⌘T picker), goes to that agent's open tab instead of attaching a duplicate. Serves "Everything through Leo" (no hunting for an agent's tab) and "Keyboard-first".
Accept: With a tab already attached to agent X, clicking X's row (highlighted or not) selects that tab and focuses its terminal, and the tab count stays the same; the same happens when X is chosen from the palette, including when the tab is in another window (that window comes forward); with no tab open for X, clicking or choosing X attaches a new tab as it does today; ⌘-click on a row and ⌘-Return in the palette force a new tab (Safari convention; shown in the menu or tooltip); the row's tab-count glyph is removed (Evan approved the removal 2026-09-24); tests cover the lookup for each entry point, plus a screenshot from the isolated debug build using autopilot-scratch.
Out: Closing or merging duplicate tabs that already exist (focus the most recently used one); changing Split (⌘D), which still attaches a new split; any per-agent limit enforced by the daemon.
Source: Evan (/feature, 2026-09-24)
Inbox: 20260925T002247437461Z-47b2bf9d#1
