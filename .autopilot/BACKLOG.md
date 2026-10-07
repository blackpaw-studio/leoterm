# Backlog

Ranked. Statuses: `ready`, `ready (next run)`, `blocked`, `deferred`, `done`, `idea`, `dropped`.
Source roadmap: `docs/leo/roadmap.md` on `main` (not edited by autopilot).

## B-067 · Terminals row scrolls into view when created or selected   [done]
Issue: #71
Why: the section sits under a long agent list (~40 agents); a new or selected Terminals row stays off-screen — seen in B-057 verify
Accept: creating or selecting a Terminals row scrolls it into view; test
Source: autopilot polish (B-057)
Done: c905bd4c9 f8135ef58 (1715 tests). A created or selected Terminals row scrolls fully into view, also after the filter clears; retitles and refreshes never scroll. Decisions D-129, D-130.

## B-068 · Tell same-directory shells apart   [done]
Issue: #72
Why: two shells in the same directory both read "~" in the Terminals section
Accept: rows for shells with identical titles get a distinguishing suffix (tty or index); test
Source: autopilot polish (B-057)
Done: 59b259e37 677060e4f (1724 tests). Same-titled Terminals rows read "~", "~ (2)", "~ (3)"; closing an older one renumbers later ones. Decisions D-131..D-133.

## B-069 · Start screen: New Terminal button   [done]
Issue: #73
Why: the start screen says "open a plain shell" but offers no New Terminal button (principle 1: visible action)
Accept: start screen has a New Terminal button doing exactly ⌘T; test + screenshot
Source: autopilot polish (B-057)
Done: 7ba7c4400 (1727 tests). A bordered New Terminal button (⌘T tooltip) sits beside Choose Agent… on the start screen and creates a Terminals row in that window. Decisions D-134..D-137.

## B-070 · Window title after the last shell closes   [done]
Issue: #74
Why: after the last Terminals row closes the window title is just the ghost icon, without "Ghostty"
Accept: window title reads the normal start title; test
Source: autopilot polish (B-057)
Done: 01fb138dd (1730 tests). After the last shell closes the window reads "👻 Ghostty", like a fresh window; a Change Window Title… override survives. Decisions D-138, D-139.

## B-084 · Sidebar width isn't remembered between launches   [done]
Issue: #88
Type: bug
Report: the sidebar width is not remembered between launches
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-09-29)
Inbox: 20260929T222627147110Z-2d6d1eb8#1
Done: 14a220074 1f5142c27. (1740 tests). The sidebar width is stored in leo.sidebarWidth and restored at launch without being overwritten. Decisions D-144..D-146.

## B-085 · Window doesn't always appear on launch   [done]
Issue: #89
Type: bug
Report: on launch the window doesnt always appear
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-09-29)
Inbox: 20260929T222806706604Z-d192c093#1
Done: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642. (1787 tests). The first window opens at launch even without activation; tiny saved frames are neither saved nor restored; an untouched launch window gives way to a requested one. Decisions D-147..D-154.

## B-086 · Window shrinks to a tiny size on first agent attach after launch   [done]
Issue: #90
Type: bug
Report: when attaching to the first agent after launching, the app window shrinks to a tiny size
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-09-29)
Inbox: 20260929T222831661985Z-ec1de91b#1
Done: 3c3189960 c8fa29411 528d63ebe. (1787 tests). A window already on screen keeps its frame on its first agent attach; window-width/window-height size only a window filled before it shows. Decisions D-155..D-158.

## B-071 · Bug — ⌘Z of a split close after a row switch can silently kill a busy hidden row's shell   [done]
Issue: #75
Why: B-057 concurrency review (MEDIUM, dismissed as pre-existing): ⌘D, ⌘W the split, switch rows, ⌘Z within 5 s replays the old tree, bypassing retire/kept. Suggested fix: undoManager.removeAllActions(withTarget:) in leoReplaceContent/leoShowStartScreen. Also: a keyboard-selected but not shown hidden row that exits leaves the selection nil (LOW)
Accept: a failing test reproduces the undo-replay kill; it passes after the fix; selection falls back to what's shown; nothing else regresses
Source: autopilot polish (B-057)
Done: 3c11d58f5 554d32298 73ccd5035 c32e920d8 1c7b13222 c9ce67411 bc8aae9f1 (1737 tests). After a content swap or the start screen ⌘Z no longer replays the old tree; a selected row that closes hands the selection to what's shown. Decisions D-140..D-143.

## B-072 · Test infra: runtests.sh crashes the test host (libghostty env pointer vs setenv)   [done]
Issue: #76
Why: canonical scratchpad/runtests.sh crashes at LeoLivePoolIntegrationTests/switchingBackShowsTheSameSurfaceInstance (libghostty holds a pointer into environ; later FAKE_SSH_* setenv invalidates it), also on baseline; B-057 used a wrapper presetting LANG, __CF_USER_TEXT_ENCODING, __LLVM_PROFILE_RT_INIT_ONCE. Also lengthen aNewShellIsASelectedRowTitledByItsTerminal's eventually timeout (flaky under load)
Accept: the canonical suite runs green without the wrapper (fix the setenv use or copy env for libghostty); flaky timeout lengthened; verify.md updated
Note: B-068 moved aNewShellIsASelectedRowTitledByItsTerminal to a /bin/cat stand-in (the flake's cause was a login shell's prompt retitle), so the timeout part may already be moot.
Source: autopilot polish (B-057)
Done: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938. (1788 tests, no wrapper). libghostty's syncEnviron keeps its own copy of the environment, so a later setenv can't free it under a new surface; the canonical runner is green without the env wrapper; verify.md updated. Decisions D-159..D-166.

## B-073 · runtests.sh test-host timeout too short under load   [done]
Issue: #77
Why: the 400 s test-host timeout cut off a full run at this host's load (300–950) during B-063 verify
Accept: timeout configurable/raised so a loaded run completes; flake-free rerun
Source: autopilot polish (B-063)
Done: no code change — timeout already configurable via LEO_TEST_TIMEOUT (D-057); autopilot runtests.sh default raised 400→900 s (untracked scratch) and verify.md documents it. Runs since at load were complete (B-072: 1788/1788 twice). Decision D-168.

## B-074 · Sidebar under the traffic lights with macos-titlebar-style=hidden   [done]
Issue: #78
Why: pre-existing: .ignoresSafeArea(.top) (TerminalView.swift:205) puts the whole sidebar under the traffic lights in the hidden titlebar style (seen in B-064)
Accept: with titlebar-style hidden the sidebar header clears the traffic lights; layout test in the real split-view hierarchy; screenshot
Source: autopilot polish (B-064)
Done: 995fab04e 67ee5def8. In the hidden titlebar style the sidebar header sits 14 pt from the top (no empty 52 pt band); other styles unchanged. No style draws the traffic lights over the sidebar. Decisions D-169..D-172.

## B-075 · Search field grabs keyboard focus on launch   [done]
Issue: #79
Why: the sidebar search field shows a focus ring on launch (seen in B-064 verify); a first-party sidebar doesn't take focus from content
Accept: on launch focus goes to the content area, not the search field; test
Source: autopilot polish (B-064)
Done: 6b5dfa44a da808024b. (1793 tests). A new window's focus starts in the content area; the search field no longer takes focus at launch. Decisions D-173..D-175.

## B-076 · Tighten LeoNoTabBarTests' xib ⌘T guard   [done]
Issue: #80
Why: the guard at LeoNoTabBarTests:92-93 can only pass: New Terminal takes ⌘T from the Ghostty config, and an empty `<modifierMask/>` slips past the filter
Accept: the guard fails if any xib item other than New Terminal binds ⌘T (including an empty modifierMask), or its message is reworded to say what it really checks; suite green
Source: autopilot polish (B-066)
Done: 922ba4b00. (1797 tests). The xib guard now fails if any item other than New Terminal binds ⌘T or a bare T; proved red by a mutation. Decisions D-176..D-177.

## B-077 · verify.md: palette is Choose Agent… (⌘O), not File ▸ New Tab   [done]
Issue: #81
Why: verify.md still says "the agent palette opens with File ▸ New Tab"; that menu item is now New Terminal (⌘T), and the palette is Choose Agent… (⌘O)
Accept: verify.md's palette instructions name Choose Agent… (⌘O); the B-057 GUI tip is corrected (AX set-value on the search field changes its text but not the filter; use Agents ▸ Find Agent… plus peekaboo type / press delete, per B-067 verify)
Source: autopilot polish (B-066)
Done: no code change — verify.md edited by the orchestrator (dca59c5f9): palette is Choose Agent… (⌘O); search filter via Find Agent… + type/delete. Decision D-167.

## B-078 · Tests for B-067's calm-scroll claims   [done]
Issue: #82
Why: "a retitle doesn't move the scroll offset" and "re-selecting a row already on screen doesn't scroll" hold only by construction; nothing catches a regression
Accept: tests assert both; reword the misleading doc comment on aNewRowBelowAListedOneIsRevealedWhole's "same turn" case (it passed before the fix)
Source: autopilot polish (B-067)
Done: 125f2a501. (1799 tests). Tests pin that a retitle/refresh doesn't scroll and re-selecting an on-screen row doesn't scroll; each proved red by a mutation; doc comment reworded. Decisions D-178..D-179.

## B-079 · Terminals row label polish (tooltip, trimmed title, test comments)   [done]
Issue: #83
Why: B-068 review polish: hovering the "(2)" suffix shows no tooltip (`.help` sits on the title Text only, LeoTerminalRowView.swift:27); labels group by the trimmed title but show the untrimmed one, so " ~ " shows a stray space (LeoTerminalRowLabel.swift:31,36); the "(B-068)" comments at LeoTerminalRowsIntegrationTests.swift:126,267 wrongly imply B-068 caused the prompt-retitle race
Accept: the tooltip covers the whole row label; displayTitle is trimmed; the comments cite the shell-integration prompt retitle; tests for the first two
Source: autopilot polish (B-068)
Done: 2aa0a78b3. (1801 tests). The Terminals row tooltip covers the whole label including the (2) suffix; displayed titles are trimmed. Decisions D-180..D-181.

## B-080 · Start-screen shortcut hints follow the live keybinds   [done]
Issue: #84
Why: B-069's New Terminal tooltip hardcodes "⌘T", but AppDelegate syncs ⌘T from the user's Ghostty new_tab keybind, so a rebind makes the hint wrong; the menu-item tests look items up by key "t" and would fail on a rebind instead of catching drift
Accept: the start-screen hints are built from the synced menu items (or config.keyboardShortcut(for:)); tests look items up by selector (TerminalController.newTab(_:)); a rebind test shows the hint following
Source: autopilot polish (B-069)
Done: d864297ac. (1811 tests). Start-screen New Terminal and Choose Agent… hints read the live menu shortcuts, so a rebind shows the new key; no shortcut means no hint. Decisions D-182..D-184.

## B-081 · Sidebar scroll and start title after the last shell closes   [done]
Issue: #85
Why: B-070 verify: after the last shell closes, the sidebar stays scrolled to the bottom where the Terminals section was; leoStartTitle is captured once at windowDidLoad (a config `title` reload doesn't reach an open window's start screen; matches upstream) and has no explicit test with a config `title` set
Accept: after the last Terminals row closes the sidebar keeps a sensible scroll position (the selection or the top), calmly; a comment documents leoStartTitle's capture; a test with a config `title` set
Source: autopilot polish (B-070)
Done: 1b7d6fefc, c56e8fdc9. After the last Terminals row closes, the sidebar lands on the selected agent or the top, unanimated; the start screen reads the controller's config title, with a comment and a config-title test Decisions D-185..D-189.

## B-082 · Bug — closing a row's original pane beside a split orphans the other pane   [done]
Issue: #86
Why: B-071 verify (shot B-071-9): File ▸ Close on the row's original pane while a split is open drops the row but leaves the other pane on screen with no row, and the next New Terminal kills that orphaned shell without asking (breaks principles 2 and 6). Pre-existing; related to D-117 and B-058
Accept: a failing test reproduces it; after the fix the remaining pane stays reachable from a row (or asks before it is replaced); nothing else regresses
Source: autopilot polish (B-071)
Done: b3e29e2c4, b818ba40a, 4d41627b1. Closing a row's pane beside a split hands the row on to the surviving plain shell (still selected), so it stays reachable and New Terminal no longer kills it Decisions D-190..D-195.

## B-083 · B-071 test and undo-manager polish   [done]
Issue: #87
Why: B-071 review polish: EditorCloseTests:91-93 doc says "S exits" but the test closes S; LeoContentSwapIntegrationTests.swift:126 calls undo() on the shared manager without leoRemoveActionsTestsCanReplay; RowsIntegrationTests:639 should also assert busyView.view?.processExited == false; ExpiringUndoManager.removeAllActions() crashes from re-entrant deinit (latent upstream bug, no production caller: snapshot the set before clearing). Also: Move Split cross-window undo leaves the other window's half after a swap (concurrency review, narrowed by B-071)
Accept: each fixed or explicitly dismissed; suite green
Source: autopilot polish (B-071)
Done: 02fa5f775, 81126012d, 7c4403ba4, f971917cf. ExpiringUndoManager.removeAllActions no longer crashes on re-entry; B-071 undo-test polish; the cross-window Move Split undo limit is documented and parked as B-110 Decisions D-196..D-199.

## B-115 · In-app updates on (repo is public)   [done]
Issue: #119
Why: Leo finds and installs its own updates from GitHub Releases instead of manual DMG downloads (P4 everything through Leo)
Accept: Ghostty-Info.plist no longer forces SUEnableAutomaticChecks off, and the `auto-update` config (off/check/download, unset → Sparkle's first-launch "check automatically?" prompt) drives the updater again, with a test per value; a test parses a fixture copy of the published appcast and confirms the newest item, version and edSignature are read; in the isolated debug build, Check for Updates… reaches the public appcast and shows the available/up-to-date UI, not an error (shot, without clicking Install); build-app.sh's comment and docs/leo/ci.md's "Auto-update" section describe it as on, with the go-public checklist marked done
Out: moving hosting off GitHub Releases; delta updates; a separate beta channel; changes to the release workflow or signing; installing an update over any real Leo install (the end-to-end install check on Evan's laptop stays his step after the next release)
Source: Evan (/feature, 2026-09-30)
Inbox: 20260930T181536331640Z-c923592e#1
Done: 2026-09-30 · 1616be959, 33d913f26, 5136f6c76, d5b151c71, aba15d23a, bf2628285, a24ed1fae, 10bb68570 · D-220, D-221, D-222, D-223, D-224, D-225, D-226

## B-087 · Cursor looks unfocused after a row switch or palette Escape   [done]
Issue: #91
Why: B-071 verify saw a hollow (unfocused) cursor right after a row switch and after Escape closes the palette; pre-existing
Accept: after a row switch or dismissing the palette, the shown terminal is first responder and its cursor is focused; test
Source: autopilot polish (B-071)
Done: 2026-09-30 · 03136e14f, 09f7d4de2 · D-227

## B-088 · "Close Terminal?" confirm names the pane it closes   [done]
Issue: #92
Why: B-071 verify: the close confirm doesn't say which pane/row it will close, which is ambiguous beside a split
Accept: the confirm names the row/pane being closed; test
Source: autopilot polish (B-071)
Done: 2026-09-30 · c606e4f2d · D-228, D-229, D-230

## B-089 · Sidebar width persistence hardening   [done]
Issue: #93
Why: B-084 review: lastPersistedWidth records the requested width, not the applied one (narrow-then-widen launch could persist a clamped width); the pending branch's programmatic-width flag relies on pendingWidth always clearing via applyProgrammaticWidth; "leo.sidebarWidth" literal repeated 3x
Accept: lastPersistedWidth comes from the sidebar's actual frame after setPosition, with a harness case for narrow-then-widen; the flag is documented or dropped; one key constant; suite green
Source: autopilot polish (B-084)
Done: 2026-09-30 · 0cd940a68, 111c6aff9, d373aecc3, 5ea58f8a0, 1b956fa7c, 862fbb512, 5ee90bebb, e41196534 · D-231, D-232, D-233, D-234

## B-090 · Bug — a sidebar hidden at launch un-collapses, then re-collapses with animation   [done]
Issue: #94
Type: bug
Report: B-084 review/implementer: a sidebar that starts hidden is un-collapsed by the pending setPosition at first layout, then re-collapsed with an animation (pre-existing). Breaks P2 calm and "hidden with ⌘⇧L stays hidden"
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: autopilot polish (B-084)
Done: 2026-09-30 · 980ec80b4, 8e7cd5d02 · D-213, D-214

## B-091 · Wide sidebar truncates the content toolbar   [done]
Issue: #95
Why: B-084 verify: at a 420 pt sidebar in an 800 pt window, "Show Terminal Drawer" truncates
Accept: a content minimum width (or a sidebar maximum tied to window width) keeps content controls untruncated; test + screenshot
Source: autopilot polish (B-084)
Done: 2026-09-30 · 25f7b4bd7, 42ecc4794 · D-235, D-236, D-237, D-238

## B-092 · Bug — a fast quit-then-reopen can leave no Leo running   [done]
Issue: #96
Type: bug
Report: B-085 diagnosis: a new copy launched ~50 ms into the previous copy's quit (forced `open -n`) yields to the still-exiting copy under the single-instance lock, and then no Leo remains (1/5 forced, 0/24 via plain open). LaunchServices reports the dying copy isTerminated=false. Candidate fix: mark the lock "exiting" in applicationWillTerminate; a new copy that sees the mark blocks on flock instead of quitting (keeps D-051/D-053)
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: autopilot polish (B-085)
Done: 2026-09-30 · 85ca7d75b, 712e5b926, 8094e6416 · D-215, D-216, D-217, D-218, D-219

## B-093 · Launch-window replacement polish   [done]
Issue: #97
Why: B-085 review/verify: with a hidden launch (`open -j`, login item hidden) the requested window may read isVisible=false so both windows stay; the queued close doesn't re-check the launch window is still visible (narrow double-close); after a request replaces the launch window the sidebar search isn't focused; plan file not amended for LeoLaunchPlaceholder, the palette change, the 300x150 floor
Accept: each fixed or explicitly dismissed with a test where behaviour changes
Source: autopilot polish (B-085)
Done: 2026-09-30 · 3d90cb41f, b09da3a64, 846d9b336, 6f0759f97, 5f7b9c4fb · D-239, D-240, D-241, D-242, D-243

## B-094 · B-085 integration test hardening   [done]
Issue: #98
Why: B-085 review: the launch-placeholder integration tests silently pass without a live Ghostty.App (use .enabled(if:)); the defer close is registered after a #require; drainMainQueue waits a fixed 4 turns; lastCascadePoint isn't restored; the newTab test lacks a launchWindow==nil assert
Accept: each fixed; suite green
Source: autopilot polish (B-085)
Done: 2026-10-01 · 17f1d88b6

## B-095 · Reopen and fallback New Window flash the palette   [done]
Issue: #99
Why: B-085 verify: Dock reopen and the fallback New Window still route through the palette (present-then-dismiss flash), unlike the launch window which now opens as the bare start screen (P2)
Accept: reopen and fallback New Window open the bare start screen with no palette flash; test
Source: autopilot polish (B-085)
Done: 2026-10-01 · 13d56313c · D-244, D-245

## B-096 · B-086 test and doc fixes   [done]
Issue: #100
Why: B-086 review: firstFillAfterAStartScreenLeaveKeepsTheFrame can never fail (initialSize is set after the refill and the size step is never called); LeoFirstAttachWindowSizeTests doc comment (~L141) wrongly says New Terminal can fill before the window shows
Accept: the test calls leoApplyInitialSize after setting initialSize and fails without the B-086 guard (or is dropped); the comment is corrected
Source: autopilot polish (B-086)
Done: 2026-10-01 · 0bc16b549

## B-097 · Bug — Reset Window Size shrinks a start-screen window   [done]
Issue: #101
Type: bug
Report: B-086 review (both lenses): Reset Window Size (returnToDefaultSize / reset_window_size) still reads the SwiftUI intrinsic size because container.initialContentSize stays nil for start-screen windows; the same class of shrink as B-086 when window-width/window-height are set. Suggested fix: set initialContentSize = leoConfiguredContentSize on first fill
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: autopilot polish (B-086)
Done: 2026-09-30 · d1161c857, 88c4d4088

## B-098 · B-072 environ test and Zig follow-ups   [done]
Issue: #102
Why: B-072 review: the Swift regression test fails without the fix only if environ was already on the heap at init (a host that inherits LANG can pass without the fix); the init OOM path has no test (std.testing.checkAllAllocationFailures on dupeEnvironBlock); the environ arena grows one copy per syncEnviron; io_impl.environ_initialized stays set after a sync
Accept: the regression test forces environ to move (or asserts its precondition); an allocation-failure test for dupeEnvironBlock; the other two fixed or documented; suite green
Source: autopilot polish (B-072)
Done: 2026-10-01 · 7a79610f8, 6b44c1a22, e0c6a8db1 · D-246, D-247, D-248, D-249, D-250

## B-099 · Flaky sidebar scroll test after a filter clears   [done]
Issue: #103
Why: LeoSidebarTerminalScrollTests/aRowSelectedWhileFilteredIsRevealedWhenTheFilterClears flaked once in B-071 verify and once in B-074's red run (the "no-such-agent" case), passing on rerun
Accept: root cause found and the test is deterministic (no timing-based waits); suite green on repeated runs
Source: autopilot polish (B-074)
Note: B-078 hint (unverified): in the "no-such-agent" case "No matches" replaces the list, so the table may be a fresh one revealed by onAppear; the test uses a Task.sleep+eventually pattern.
Done: 2026-10-01 · 2e7667d9b, 811717ef8, 6fcb8552c, 757c80895, 291915f91 · D-251, D-252, D-253, D-254, D-255

## B-100 · Hidden titlebar style: side-pane headers and corner inset   [done]
Issue: #104
Why: B-074 verify: in hidden style the editor/workspace-browser header rows now run to the window top and may sit flush (untested, not captured); the sidebar header is 14 pt from the rounded corner, a little tight
Accept: in hidden style the side-pane headers have the same top inset as the sidebar header; a layout test; screenshot
Source: autopilot polish (B-074)
Done: 50fdea4fa 32d413573 7c9cb2d1f. In hidden titlebar style the editor and workspace-browser headers centre on the sidebar header's line (10 pt D-169 inset, kept per D-169); layout test LeoSidePaneTitlebarStyleTests; suite 1941 green; shots B-100-1..4.

## B-101 · Launch-focus test gaps   [done]
Issue: #105
Why: B-075 review/verify: the key-view-loop rebuild timing is untested at real launch order (the test waits ~1 s for the search field before windowDidBecomeKey; if the rebuild runs before the field exists, Tab won't reach it until the window regains key — TerminalController+LeoLaunchFocus.swift:26-30); no unit test for "row shown → terminal surface becomes first responder" (verified only visually); the comment overstates when the loop refreshes after a sidebar/pane toggle
Accept: a test in real launch order proves Tab reaches the search field; a test that showing a row makes its surface first responder; comment corrected
Source: autopilot polish (B-075)
Done: c640ac20b f09c93245. Real-launch-order Tab test (parameterized .nextTurn/.immediately) proves Tab reaches the search field; row-shown → first-responder covered by B-087's LeoContentFocusTests.aRowSwitchFocusesTheShownTerminal; launch-focus comment corrected. No production change; suite 1941 green; mutation-checked.

## B-102 · Menu shortcut guard coverage   [done]
Issue: #106
Why: B-076 review: chooseAgentIsCommandO (LeoNoTabBarTests.swift:68) still filters inline and misses a bare O (use LeoMenuXib.claims(on:byAnyoneBut:)); the ⌘T guard exempts newTab: from the bare-T rule; the live-menu ⌘T check covers only Quick Terminal
Accept: ⌘O guard catches a bare O; New Terminal may hold only ⌘T; the live-menu check covers every item; each proved red by a mutation
Source: autopilot polish (B-076)
Done: 1f32b5966. ⌘O guard catches a bare O; New Terminal may hold only ⌘T (refines D-177); the live-menu check covers every item; each guard proved red by mutation. Tests only; suite 1948 green.

## B-103 · Calm-scroll test hardening   [done]
Issue: #107
Why: B-078 review polish: afterPendingUpdates only catches a scroll within ~5 dispatches (an animated/asyncAfter/Task.sleep scroll would pass); the tests park at offset 0 so a reset-to-top or a table rebuild goes unseen; the retitle case doesn't await its positive signal; the doc comment cites project history and omits D-129's "list reappears" half
Accept: the helper documents its window limit; tests park mid-list and assert table identity; retitle awaits the new row text before counting turns; comment fixed
Source: autopilot polish (B-078)
Done: 396984a56. Calm-scroll tests park mid-list, assert same-list identity, await the retitle's drawn signal before counting turns; helper documents its window; comments cite both halves of D-129. Tests only; each proved red by sabotage; suite 1948 green.

## B-104 · Shortcut hint polish   [done]
Issue: #108
Why: B-080 review: LeoMenuShortcutHint lacks @MainActor (LeoShortcutHints.swift:43); a function-key binding (super+f1) gives no hint where "⌘F1" could be spelled (:56); no test for publish-only-on-change (:95-96); theButtonsHintNamesTheMenuItemsLiveShortcut passes trivially if both sides are nil (LeoPlaceholderNewTerminalTests.swift:370); stale "(⌘T)" doc comment in LeoPlaceholderView.swift; the disconnected Choose Agent… tooltip hardcodes ⇧⌘R
Accept: each fixed or explicitly dismissed; tests for the function-key and unchanged-sync cases
Source: autopilot polish (B-080)
Done: 3612df84d 83224b8a9. LeoMenuShortcutHint is @MainActor; hints spell F-keys (⌘F1); publish-only-on-change and function-key tests; the nil==nil trivial pass fixed; stale (⌘T) comment fixed; the disconnected Choose Agent… tooltip reads Reconnect's live shortcut. F-key config rebinds reaching menus dismissed as out of scope (follow-up filed). Suite 1952 green; shots B-104-1..2.

## B-105 · Terminals-close landing polish   [done]
Issue: #109
Why: B-081 review: the top landing after the last shell closes also fires when the Terminals section was already scrolled off, moving rows the user was reading (P2); removing the !isFiltering guard (LeoTerminalsSectionExit.swift:83) fails no test; the top landing sits 10 pt below the true top (scrollTo on the first section can't reach offset 0 past the table's top margin)
Accept: the landing happens only when the Terminals section was on screen; a test pins the filter guard; the top landing reaches the list's launch offset, or a comment explains why it doesn't
Source: autopilot polish (B-081)
Done: 5ce958ac9 75c512e4c 1b9d09aed. Closing the last shell lands only when the Terminals section was on screen (refines D-187); the top landing reaches the launch offset (refines D-185); a test pins the filter guard. Promoted light→full (163-line diff); 1 fix round (cell-reuse flake fixed deterministically). Suite 1962 green ×3; shots B-105-1..4.

## B-106 · Selected agent row unhighlighted after the last shell closes   [done]
Issue: #110
Why: B-081 implementer: after the last Terminals row closes, the selected agent row isn't highlighted while it's off screen
Accept: the selected agent row shows its selection highlight once revealed, with a test
Source: autopilot polish (B-081)
Done: 6b08d7233 c1b36b866. Didn't reproduce: the selected agent row is already highlighted once revealed after the last shell closes (fails when the selection's agent fallback is removed). Regression test added (isSelected, selectedRowIndexes, pixel probe); no production change.

## B-107 · Row hand-on polish after a split pane closes   [done]
Issue: #111
Why: B-082 review: the row goes to the first pane in tree order, not the pane upstream focuses next (focusedSurface is stale at both call sites), so the sidebar selection can differ from keyboard focus; adoption runs a turn late (run pending reconciles synchronously at the top of confirmReplacingContent/showInContent/reveal); the `controller.window != nil` comment overstates "window open"; the fate() doc doesn't mention an adopted row in a [row, plain] tree; the verifier saw the survivor's "Last login" lines scroll away on reflow (unconfirmed)
Accept: the row follows upstream's next-focus pane (or the doc says tree order), with a test; a same-turn adoption test; the comments are corrected
Source: autopilot polish (B-082)
Done: 0ede659d9 0c129e5cd 5679f7b0a. A closed row hands on to upstream's next-focus pane (refines D-191), in the same turn (pending reconciles drain at the top of showInContent/reveal/confirmReplacingContent); tests for next-focus and same-turn switch; comments corrected; Last-login reflow assessed (upstream/shell). Suite 1969 green; shots B-107-1..5.

## B-108 · Undo-restored split panes get no terminal handle   [done]
Issue: #112
Why: B-082 review: close the row's pane, undo the close, then undo New Split (or close the carried-on row's pane): the restored pane has no handle and is orphaned again. Not a regression; overlaps B-058
Accept: a failing test reproduces it; restored panes are adopted or reachable from a row
Source: autopilot polish (B-082)
Done: 4540801bc dda028e02 f8878eeca 8f0d20276 05160bf62. Undo-restored plain-shell panes get their Leo handle back (re-registered, never adopted handle-less), so they are reachable as plain splits beside the carried-on row; same mechanism for any undo/redo; failing test first; same-turn close test. 1 fix round. Suite 1975 green; shots B-108-1..10.

## B-109 · Closed split pane's shell lingers ~40 s   [done]
Issue: #113
Type: bug
Why: B-082 verify: after File > Close on a split pane, its shell (pid 36119) was still alive 2 s later and gone about 40 s later
Accept: confirm or rule out with a test; if real, closing a pane ends its shell promptly
Source: autopilot polish (B-082)
Question: couldn't reproduce — a test shows a closed pane's shell lives only for the Close Terminal undo window (undo closure holds the tree; undo-timeout 5 s default): view freed 5.1–5.25 s after close, zsh reaped right after; forgetting undo ends it in 0.13–1.13 s; ⌘Z within the window restores the same shell. B-082's "gone ~40 s later" was likely just the next check. Pin tests + a doc comment are on autopilot-shelved/B-109 (unreviewed). Work kept on autopilot-shelved/B-109. Reply "B-109: close" to close it, or "B-109: <more detail>" to retry.
Answer: close
Done: closed — not reproducible (Evan)

## B-110 · Dragging a Leo surface between windows: rows, window ownership and undo   [blocked]
Issue: #114
Why: B-083 (point 5, parked): the host keeps surface S under window A after splitDidDrop or drag-to-new-window; the Move Split undo halves misbehave after either window swaps, and ⌘Z can free S's shell without a confirm once the redo expires (P2: nothing dies without asking). Candidate fixes: (a) a swap-generation guard in upstream's cross-window branches, or (b) moving row ownership on drop
Accept: failing tests reproduce the orphaned ownership and the unconfirmed shell free; after the fix a moved surface belongs to (and is reachable from) the window it's in, and no undo path frees a shell without asking
Source: autopilot (B-083 dismissal)
Question: runner timed out after 3h — last known step: build mode, fix round 2 of 3 in progress (review rounds 1–2 found races: pre-reconcile ordering and the focus a drop's undo resigns; both reproduced and mostly fixed); lane's last commit 1eee9b5b0 "test(B-110): the focus a drop's undo resigns, as a pure decision". Work kept on autopilot-shelved/B-110 (15 commits: handles follow surfaces across windows, the coordinator re-keys moved agents, a guarded Move Split undo). I'd pick: retry next run from that branch with the hard implementer.
Answer:

## B-177 · Context menu on Terminals rows   [done]
Issue: #180
Why: plain-shell rows get the same right-click affordances agent rows have, so managing shells doesn't need the File menu (P1 every action has a menu item; P6 the sidebar is the navigation)
Accept: right-clicking a Terminals row shows a menu with Rename…, Close (same confirm as File ▸ Close when a process is running), and the row's split/pane actions that already exist in menus (e.g. Split Right, Reveal in content); Rename sets a custom row title that sticks over the shell's own title changes until cleared (an empty name restores the live title); custom titles persist across an app restart wherever the shell row is restored (window restoration); tests for each action and the persistence, plus a debug-build screenshot of the menu and a renamed row
Out: renaming agent rows (daemon-owned names); drag-to-reorder; new keyboard shortcuts
Source: Evan (/feature, 2026-10-03)
Inbox: 20261002T013226996464Z-7ea15972#1
Done: fd55a3a90 d8d41b5da 10651dd62 (1996 tests). Terminals rows get a context menu: Show, Split Right, Split Down, Rename…, Close (asks like ⌘W when busy). Rename sets a custom title on the surface that sticks over OSC titles; blank restores the live title. Title persists via surface encode/decode (round-trip test only: no shell row is restored at launch today). Decisions D-284–D-292. Verified: shots B-177-0..7 (menu, Rename sheet, renamed row sticking after cd, cleared to live title, close). 1 fix round (pinned that no hidden row keeps a busy split for Close).

## B-176 · New Agent in Worktree from a sidebar row   [done]
Issue: #181
Why: branch a parallel agent off an existing agent's repo without leaving the app (P4 everything through Leo; P1 every action has a menu item)
Accept: an agent row's context menu has "New Agent in Worktree…", opening the New Agent sheet prefilled with that agent's template, host and owner/repo plus a required branch field; submitting runs the spawn with --worktree <branch> on the agent's host (local and remote, tested with a fake runner) and selects the new agent's row; the item is disabled for agents with no owner/repo; screenshot of the menu and the prefilled sheet
Out: carrying the source agent's context or prompt over; basing on the source agent's branch (base stays origin HEAD); worktree cleanup/removal; a shortcut beyond the menu item
Source: Evan (/feature, 2026-10-03)
Inbox: 20261001T230248695398Z-abe4ea92#1
Done: 7f3a25018 233fae09f 6d8f5f392 cc9a85fa0 (2015 tests). Agent rows get "New Agent in Worktree…" (after Open in New Window; disabled with no owner/repo), opening the New Agent sheet in a worktree mode: template prefilled, host and repo read-only, required branch. Create spawns through the host's daemon API with branch = worktree, and selects the new row; a host switch mid-sheet blocks Create. Decisions D-293–D-301. Verified: shots B-176-1..3 (menu, prefilled sheet; never submitted). Remote covered by fake-daemon tests only. 1 fix round (host/daemon race; a selectedHost guard that failed open).

## B-111 · Undo docs and test-name polish   [done]
Issue: #115
Why: B-083 review: leoForgetContentUndo's doc (TerminalController+Leo.swift:68-71) says "Close Terminal + replace", which fits only splitDidDrop (say "one action per window") and understates the cross-window effect (name the B-110 shell-free risk); redundant removeAllActions(withTarget:) before leoRemoveActionsTestsCanReplay at LeoTerminalControllerEditorCloseTests.swift:~99; rename removeAllActionsDropsExpiringUndosWithoutReentering to ...WithoutAnExclusivityViolation; the removeAllActions() comment doesn't mention the explicit expire() plus the idempotent second expire
Accept: each fixed or explicitly dismissed; suite green
Source: autopilot polish (B-083)
Done: b76844890 0203d466f (2015 tests). Docs: leoForgetContentUndo names the per-window Move Split halves and B-110's shell-free risk; removeAllActions() documents its explicit expire(). Renamed the exclusivity test; dropped two removeAllActions(withTarget:) calls the replay helper covers. Not visually verified: no UI change. Decision D-302.

## B-112 · Finish test isolation for LeoRuntime / LeoAgentActions   [done]
Issue: #116
Why: B-061 review: LeoRecordingTemplateRunner nearly duplicates the private TemplateSSHRunner (LeoAgentActionsTests.swift:293) — merge them with an injectable stdout; LeoRuntime tests still run the real local `leo template list` via LeoCLI(); LeoAgentActions.init still defaults processRunner to the real runner (about 10 tests rely on it)
Accept: one shared template-runner fake; LeoRuntime tests inject a fake LeoCLI runner; LeoAgentActions.init has no real-runner default and no test spawns a real process for templates
Source: autopilot polish (B-061)
Done: 6c370c99c 925854efc 05b50deec (2017 tests). One shared template-runner fake (LeoRecordingTemplateRunner(templates:)) and LeoCLI.recordingForTests; every template path in tests uses it; LeoAgentActions and LeoCLI have no real-runner default, so a test that forgets a fake fails to compile. Gated concurrency fakes kept separate. Verified: shots B-112-1..5 (New Agent template list still loads). Decisions D-303–D-305.

## B-113 · Sidebar button bar polish   [done]
Issue: #117
Why: B-065 review: LeoSidebarButton.send duplicates LeoPlaceholderNewTerminal.send and `newTab:` is defined twice (route the placeholder closures through LeoSidebarButton, TerminalView.swift:173-176, 200-203, 322-323); the start-screen placeholder closures still capture self in TerminalView (the capture that leaked displaced surfaces from the sidebar) — check for a leak; swapping the two closures in LeoSidebarView.perform passes every test (add a view-glue test with recording closures); parameterize the footer layout test over failed/loading states; the Quick Terminal glyph (rectangle.tophalf.inset.filled, also Split Up's) doesn't read as a drop-down terminal; the start screen says "Show Terminal Drawer" while the menu and button say "Quick Terminal"
Accept: each fixed or explicitly dismissed; one naming for the quick terminal; tests for the closure wiring and footer states
Source: autopilot polish (B-065)
Done: ed647aea6 4dcfc5918 1e7158bb5 8cb00814a (2023 tests). "Quick Terminal" everywhere (start screen no longer says Show Terminal Drawer); Quick Terminal glyph menubar.arrow.down.rectangle; the start screen uses the sidebar footer's buttons via one LeoSidebarButtonActions value (LeoPlaceholderNewTerminal deleted, newTab:/send defined once); no leak found, self capture removed anyway with weak-reference tests; footer layout test parameterized over failed/loading. Verified: shots B-113-1..7. Decisions D-306–D-310.

## B-114 · runtests.sh misses parameterized test failures in its grep   [done]
Issue: #118
Why: B-065 implementer: runtests.sh's failure grep misses parameterized tests (names with `(_:)`); only the summary count catches them
Accept: the failure list names parameterized failures; verify.md updated
Source: autopilot polish (B-065)
Done: e113fee0e a5e1b3de8 (2023 tests). The test runner is now tracked at macos/scripts/leo-runtests.sh (scratchpad/runtests.sh retired) and its failure list names parameterized failures (`foo(_:) with N test cases failed`); parse test macos/scripts/test_leo-runtests.sh (5/5). verify.md updated. Not visually verified: no UI change. Decisions D-311–D-313.

## B-116 · Sidebar programmatic-width doc comment   [done]
Issue: #120
Why: B-090 review polish
Accept: applyProgrammaticWidth's doc comment (LeoSplitViewRepresentable.swift) says a collapsed sidebar drops the pending width and gets it when shown
Source: autopilot polish (B-090)
Done: 8a83a617d (2023 tests). applyProgrammaticWidth doc comment now says a collapsed sidebar drops the pending width and gets it when shown; reviewer and verifier checked each claim against the code. Not visually verified: no UI change.

## B-117 · verify.md: sidebar toggle menu path reads Hide/Show   [done]
Issue: #121
Why: B-090 verify couldn't find "Agents ▸ Show Agents Sidebar" while the sidebar was visible (the item reads "Hide Agents Sidebar" then)
Accept: verify.md's GUI tips name the toggle as Show/Hide Agents Sidebar depending on state
Source: autopilot polish (B-090)
Done: no code change — verify.md (orchestrator) now names the toggle Show/Hide Agents Sidebar by state, in the peekaboo example and the Agents menu tip.

## B-118 · Single-instance: reject a marked pid that isn't this bundle   [done]
Issue: #122
Why: compare proc_pidpath or bundle ID as well as the uid before waiting on a marked pid; shrinks the same-user pid-reuse wait risk (security + concurrency)
Accept: compare proc_pidpath or bundle ID as well as the uid before waiting on a marked pid; test where behaviour changes
Source: autopilot polish (B-092)
Done: 882b0040f (2029 tests). Before waiting on a marked pid, single-instance now checks it is a copy of this bundle (bundle ID + CFBundleExecutable from its Info.plist, read safely); unreadable identity takes the bounded ~5 s path. Verified: shots B-118-1..2 (still yields to a real copy; survives a quit race). The wait branch itself is covered by unit tests only. Decisions D-314–D-319.

## B-119 · Single-instance: log when the release retry runs out   [done]
Issue: #123
Why: log an error naming the pid and pause count when the release retry is exhausted, so a stuck-mark yield is distinguishable in the field
Accept: log an error naming the pid and pause count when the release retry is exhausted, so a stuck-mark yield is distinguishable in the field; test where behaviour changes
Source: autopilot polish (B-092)
Done: 819fa9299 (2030 tests). When the instance-lock release retry runs out, single-instance now logs an error naming the pid and pause count (existing leo logger, injected logError sink with a test). Not visually verified: log-only change. Decisions D-320–D-321.

## B-120 · Single-instance: fix maxReleasePauses doc comment   [done]
Issue: #124
Why: the attempt doc comment says "maxReleasePauses times (seconds; …)" but the constant is a count, ~5 s total
Accept: the attempt doc comment says "maxReleasePauses times (seconds; test where behaviour changes
Source: autopilot polish (B-092)
Done: fdbdb1a36 (2030 tests). The attempt doc comment now describes maxReleasePauses as a pause count (2,500 × 2,000 µs ≈ 5 s); also reworded the B-119 pid-line comment. Not visually verified: comments only.

## B-121 · LeoTestProcess.gone() pid reuse flake   [done]
Issue: #125
Why: gone() returns a reaped pid that can be reused; re-check ESRCH just before use
Accept: gone() returns a reaped pid that can be reused; test where behaviour changes
Source: autopilot polish (B-092)
Done: 4dba68680 (2034 tests). LeoTestProcess.gone() checks the pid is still free at hand-out (injectable probe, 5 bounded retries, EINTR-safe waitpid) so a test never gets a pid a live process reused. Not visually verified: test support only. Decisions D-322–D-324.

## B-122 · Test Return To Default Size menu enabled state   [done]
Issue: #126
Why: a test for the Return To Default Size menu item's enabled state (validateMenuItem/isChanged) on a filled start screen
Accept: a test for the Return To Default Size menu item's enabled state (validateMenuItem/isChanged) on a filled start screen
Source: autopilot polish (B-097)
Done: e18cc1bac (2036 tests). Two tests pin the Reset Window Size (Return To Default Size) menu item enabled state on a filled start screen; shown able to fail by reverting the B-097 fix and by inverting validateMenuItem. Not visually verified: tests only. Decision D-325.

## B-123 · Updater mayPerform adapter test   [done]
Issue: #127
Why: test updater(_:mayPerform:) beyond the pure UpdatePolicy.mayCheck (both B-115 reviewers)
Accept: test updater(_:mayPerform:) beyond the pure UpdatePolicy.mayCheck (both B-115 reviewers)
Source: autopilot polish (B-115)
Done: 0d97ffa3c (2039 tests). UpdateDelegateTests exercise the real updater(_:mayPerform:) adapter (allowed and refused paths, and the error it returns) through an unstarted SPUUpdater subclass; no product seam added; shown able to fail by mutation. Not visually verified: tests only. Decision D-326.

## B-124 · Name UpdateDelegate error constants   [done]
Issue: #128
Why: inline error code 1 and domain string in UpdateDelegate.swift:119 should be named constants
Accept: inline error code 1 and domain string in UpdateDelegate.swift:119 should be named constants
Source: autopilot polish (B-115)
Done: 9893742e4 (2039 tests). The update check-refusal error code and domain are named constants UpdateDriver.CheckRefusal.{domain,code}; UpdateDelegateTests use them. Not visually verified: refactor, no UI change. Decisions D-327–D-328.

## B-125 · GhosttyMouseStateTests launch arguments   [done]
Issue: #129
Why: it uses activate(), not launch(); confirm -SUEnableAutomaticChecks NO applies or switch to launch()
Accept: it uses activate(), not launch(); confirm -SUEnableAutomaticChecks NO applies or switch to launch()
Source: autopilot polish (B-115)
Done: bb76eeb16 (2039 tests). GhosttyMouseStateTests and GhosttyCommandPaletteTests now launch() the app first, so -SUEnableAutomaticChecks NO (D-224) applies; activate() attached to an already running app without its arguments. UI tests aren't run by leo-runtests.sh: compile-verified only. Not visually verified: UI-test code only. Decisions D-329–D-330.

## B-126 · Pin update defaults reset before startUpdater   [done]
Issue: #130
Why: the migration-before-startUpdater order (AppDelegate.swift:313) has no test or comment pinning it
Accept: the migration-before-startUpdater order (AppDelegate.swift:313) has no test or comment pinning it
Source: autopilot polish (B-115)
Done: 7e46debf8 (2040 tests). Launch now runs reset defaults → apply config → start updater through UpdateLaunchSequence.run, and UpdateLaunchSequenceTests pins the order (shown failing with it reversed). Not visually verified: launch-code reorganisation only. Decisions D-331–D-333.

## B-127 · Appcast fixture refresh note   [done]
Issue: #131
Why: AppcastFixtureTests hard-codes 18527/0.5.0 against a #filePath fixture; document refreshing both together
Accept: AppcastFixtureTests hard-codes 18527/0.5.0 against a #filePath fixture; document refreshing both together
Source: autopilot polish (B-115)
Done: abe0f1962 (2040 tests). AppcastFixtureTests names its expected values (newestVersion/newestShortVersion) and documents refreshing the fixture and both constants together, verbatim, in one commit. Not visually verified: test docs only. Decisions D-334–D-335.

## B-128 · Update permission prompt shows twice at launch   [done]
Issue: #132
Why: B-115 verify: the pill and Sparkle's standard alert both asked "Check for updates automatically?" at launch (likely no terminal window visible yet); ci.md says pill popover only
Accept: B-115 verify: the pill and Sparkle's standard alert both asked "Check for updates automatically?" at launch (likely no terminal window visible yet); ci.md says pill popover only
Source: autopilot polish (B-115)
Done: a135885de d5c5f68ee d0c990083 3ac5e5321 d4f4f67a3 (2044 tests). The automatic-updates question is asked once, in the pill popover, never in Sparkle's alert; with no window yet it waits for the first window, survives closing the last window, and Check for Updates… while it is pending opens a window for the pill. ci.md updated. Verified: shots B-128-1..6. 1 fix round (a manual check while asking overwrote the request; test window cleanup). Decisions D-336–D-340.

## B-129 · Debug update alert offers auto-install checkbox   [done]
Issue: #133
Why: B-115 verify: Sparkle's standard permission alert offers "Automatically download and install updates" in Debug builds; hide it or make it inert there
Accept: B-115 verify: Sparkle's standard permission alert offers "Automatically download and install updates" in Debug builds; hide it or make it inert there
Source: autopilot polish (B-115)
Done: d1cbb8942 (2045 tests). Debug builds set Sparkle's SUAllowsAutomaticUpdates=NO (Info.plist, Debug only), so no Sparkle alert offers Automatically download and install updates; a test pins the Debug plist. Verified: shots B-129-1..4 (update-found alert with no checkbox; nothing clicked). Decisions D-341–D-342.

## B-130 · App menu says About Ghostty   [done]
Issue: #134
Why: B-115 verify: the app menu still lists "About Ghostty" (pre-existing); should read About Leo
Accept: B-115 verify: the app menu still lists "About Ghostty" (pre-existing); should read About Leo
Source: autopilot polish (B-115)
Done: 342cba7a4 (2048 tests). The app menu reads About Leo (also in Debug) and the About window names Leo; LeoAboutMenuTests pins the menu title. Verified: shots B-130-1 (app menu, screen) and -2 (About window). Remaining Ghostty strings filed as a branding sweep. Decision D-343.

## B-219 · Agents stuck in errored state in the sidebar while working fine   [blocked]
Issue: #223
Type: bug
Report: agents are stuck in errored state in the sidebar even though theyre working fine
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-10-04)
Inbox: 20261004T000358126791Z-1ba543a9#1
Question: Root cause is in the leo daemon, not the app: `isAgentHookSession` (leo internal/web/handlers_attention.go:80-105) drops every attention hook whose session_id differs from the stored record's, and /clear never updates the stored id (agentstore/store.go:119). After the 2026-10-03 11:39 tmux-server restart set everything to errored, the /cleared agents (leo, leoterm, blackpaw-games-site) have stayed running+errored for ~35 h; agents not /cleared recover normally. The app's reducer already supersedes errored on a newer revision. I'd pick: send the leo agent the bug report plus a failing Go test spec (TestAgentHookAfterClearStillTransitionsAttention), add three Swift pin tests here, and add no app-side "hide errored while running" rule (would break D-011 and principle 2); you then release+restart the daemon. Reply "B-219: yes" to go. Work kept on autopilot-shelved/B-219 (no commits).
Answer:

## B-220 · ssh fails in in-app terminals: missing ghostty binary in Leo.app   [done]
Issue: #224
Type: bug
Report: i cant use ssh in the in-app terminals ~ arm64 ❯ ssh evan@10.0.4.16                                                                                                                                          miniforge3-arm64 ssh:4: no such file or directory: /Applications/Leo.app/Contents/MacOS/ghostty
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-10-04)
Inbox: 20261004T004211350709Z-7fddc581#1
Done: 29ebbb822 (2051 tests, lint clean). A build phase links Contents/MacOS/ghostty -> Leo (relative), so the shell-integration ssh wrapper finds the binary; 3 new tests failed before the fix. Verified: wrapper's exact `ghostty +ssh … -- -G localhost` line ran rc=0 in the debug app; shots B-220-1..3. Decisions D-344–D-345. Note: 3 focus/key-window tests fail on this host on every run, also without this change (environmental).

## B-221 · CI never runs .github/scripts/leo/tests/test_*.sh   [done]
Issue: #225
Type: bug
Report: CI never runs .github/scripts/leo/tests/test_*.sh (incl. test_info-plist-valid.sh, test_sparkle-key-check.sh) — no leo-*.yml step loops over them, so a regression like the B-129 #ifdef in Ghostty-Info.plist only surfaces when a release fails. Add a step (leo-ci or leo-build) that runs every test_*.sh and fails the job on any failure.
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-10-04)
Inbox: 20261004T205201781706Z-77d0eac5#1
Done: 3eac947b4 8e9147557 34fe5d427 (2051 tests, lint clean, actionlint clean). New `.github/scripts/leo/run-tests.sh` runs every test_*.sh (9/9 pass) and leo-ci.yml calls it; a guard test (red at base, green after) fails if no CI step runs it. Not visually verified: no UI change. Decisions D-346–D-348.

## B-222 · sparkle-key-check.sh hides PlistBuddy parse errors   [done]
Issue: #226
Type: bug
Report: .github/scripts/leo/sparkle-key-check.sh drops PlistBuddy stderr (2>/dev/null), so an unreadable/invalid Info.plist is reported as a SUPublicEDKey mismatch/missing instead of a parse error (this misled the leo-v0.7.0 release diagnosis). Capture stderr and surface it in the ::error:: line; add a test with an invalid plist.
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-10-04)
Inbox: 20261004T205201781706Z-77d0eac5#2
Done: b8581509f 47482639c (2051 tests, lint clean; run-tests.sh 10/10). Root cause was worse than reported: PlistBuddy prints "Error Reading File: …" to stdout, which the script used as the expected key. It now reports parse/unreadable/missing-key errors with PlistBuddy's output in the ::error:: line; new test failed 2/4 at base, 4/4 after under /bin/bash 3.2. Not visually verified: no UI change. Decisions D-349–D-351.

## B-131 · B-087 focus test hardening   [done]
Issue: #135
Why: LeoContentFocusTests: drive Escape via LeoPickerPresentation.commit(.cancel) not panel.dismiss() (45-48); #require(window.isKeyWindow) after dismiss in the split test (154); row-switch guard doc says it covers the host step only (24-36)
Accept: LeoContentFocusTests: drive Escape via LeoPickerPresentation.commit(.cancel) not panel.dismiss() (45-48); #require(window.isKeyWindow) after dismiss in the split test (154); row-switch guard doc says it covers the host step only (24-36)
Source: autopilot polish (B-087)
Done: 516c57d9e (2051 tests, lint clean). Escape now goes through the panel key path to LeoPickerPresentation.commit(.cancel); both palette tests #require the window to be key again (old file passed vacuously under a mutation that skipped orderOut); row-switch guard doc narrowed to the host step. Not visually verified: test-only. Decisions D-352–D-353.

## B-233 · Workspace browser reports lost host connection   [done]
Issue: #236
Type: bug
Report: browsing files doesnt even work says it lost connection to the host
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-10-05)
Inbox: 20261005T223845014618Z-e87d3338#1
Done: 8a23dede5 b3a182a55 f3913f58c 13d7da667. Workspace browsing retains the host subsystem path and falls back safely when rejected. Independent full review and 2,067 tests/222 suites + strict SwiftLint passed. Remote GUI not visually verified (no safe remote fixture). Decision D-354.


## B-234 · Surfaced files report lost host connection   [done]
Issue: #237
Type: bug
Report: same issue with surfacing files, same error (says it lost connection to the host) — likely same root cause as the file-browsing bug logged just before this
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-10-05)
Inbox: 20261005T224249855758Z-b473c7f0#1
Done: 8a23dede5 b3a182a55 f3913f58c 13d7da667. Covered by B-233: shared regression lists an absolute workspace and reads an absolute surfaced-file path through the same SFTP accessor. Independent full review and 2,067 tests/222 suites + strict SwiftLint passed. Remote GUI not visually verified (no safe remote fixture). Decision D-354.


## B-232 · Drop files into an agent's workspace (local + SSH)   [blocked]
Issue: #238
Why: Drag files from Finder onto an agent and they land in its workspace through the same file backend locally and over SFTP — principles 3 (Local = remote) and 4 (Everything through Leo). Two drop targets: the workspace browser (into the dropped-on folder, or root) and the agent terminal (upload into the workspace, then type the workspace path at the prompt instead of the local Mac path a remote agent can't read).
Accept: Dropping one or more Finder files on a workspace-browser folder writes them there via both local and SFTP backends (tested) and the browser lists them; dropping files on an agent terminal uploads them into the workspace and inserts the shell-escaped workspace paths, not local paths (tested for a remote daemon); a name clash or failed upload is shown plainly and never silently overwrites (tested); a screenshot of each drop target taking a drop from the isolated debug build
Out: folder/recursive drops; drag-out from Leo to Finder; progress UI beyond a simple in-flight indicator; clipboard-paste upload; drops on plain-shell rows with no agent workspace
Source: Evan (/feature, 2026-10-05)
Inbox: 20261005T223808026251Z-abc8b354#1
Question: Final fix limit reached. Remaining blockers: reject NUL anywhere in source URLs; bound or stream source buffering; add transport-level lost-RENAME coverage; resolve independent focus/palette suite failures. Work kept on autopilot-shelved/B-232. Generated artifacts were preserved separately. I'd pick finishing these scoped fixes in a later run; D-355 already settles SFTP semantics.
Answer:


## B-132 · Focused-surface report ordering on split open   [blocked]
Issue: #136
Why: focusedSurface didSet posts .leoFocusedSurfaceDidChange before register(), so a brief nil focus report is possible (GhosttyAttachContentHost.swift:470, same in fillPlaceholder); move the assignment after register
Accept: focusedSurface didSet posts .leoFocusedSurfaceDidChange before register(), so a brief nil focus report is possible (GhosttyAttachContentHost.swift:470, same in fillPlaceholder); move the assignment after register
Source: autopilot polish (B-087)
Question: Shared focus/palette verification failures predate B-132: same three failures on older default-main 3dadd1e42, fixtureless lane, and full lane; new ordering tests pass, both reviews clean. Work kept on autopilot-shelved/B-132 (815c1719d). I’d pick diagnosing shared AppKit focus scheduling first, using B-136/B-230 as related leads, then re-verifying this lane.
Answer:


## B-133 · Close-confirm polish   [done]
Issue: #137
Why: guard surfaceTree.contains(node) before leoConfirmClosingPane (TerminalController.swift:950-955); narrow title cleaning in LeoCloseConfirmation.swift:43-49 so ZWJ emoji survive and spacing matches the sidebar; add a left/right hint when two panes share a name
Accept: guard surfaceTree.contains(node) before leoConfirmClosingPane (TerminalController.swift:950-955); narrow title cleaning in LeoCloseConfirmation.swift:43-49 so ZWJ emoji survive and spacing matches the sidebar; add a left/right hint when two panes share a name
Source: autopilot polish (B-088)
Done: 8e6eda39d, 97ce0fef34

## B-134 · Clamped sidebar regrows to its stored width on widen   [done]
Issue: #138
Why: B-089 verify: after a window narrows and widens again, the sidebar stays ~195 pt until relaunch; regrow it toward the stored width
Accept: B-089 verify: after a window narrows and widens again, the sidebar stays ~195 pt until relaunch; regrow it toward the stored width
Source: autopilot polish (B-089)
Done: no code change — existing D-237 implementation and resize tests; fresh independent 2,072-test suite passes.

## B-135 · Sidebar width comment refresh   [done]
Issue: #139
Why: LeoSplitViewRepresentable :240 and clearProgrammaticWidthFlagSoon still say the resize notification "arrives on a later layout pass"; class doc :195-198 should say "when the user moves the sidebar's divider"
Accept: LeoSplitViewRepresentable :240 and clearProgrammaticWidthFlagSoon still say the resize notification "arrives on a later layout pass"; class doc :195-198 should say "when the user moves the sidebar's divider"
Source: autopilot polish (B-089)
Done: 59f98e25d

## B-136 · Serialize event-posting test suites   [done]
Issue: #140
Why: mouseDragDivider and LeoSidebarCommandClickTests.click share the app event queue in a parallelizable plan; serialize them
Accept: mouseDragDivider and LeoSidebarCommandClickTests.click share the app event queue in a parallelizable plan; serialize them
Source: autopilot polish (B-089)
Done: de79492d7d8eb453aca41fdb26f739cc21339db6
Note: 2026-10-06 run stopped on three pre-existing focus/palette failures; B-132 baseline comparisons exclude its changes. Shared AppKit scheduling is the suspected mechanism, not yet an isolated cause. Inspect alongside B-230 before broadening this item.


## B-137 · runtests.sh baseline note for ConfigTests   [done]
Issue: #141
Why: runtests.sh labels ConfigTests/errorsEmptyForValidConfig an "expected baseline failure", contradicting verify.md; drop the label
Accept: runtests.sh labels ConfigTests/errorsEmptyForValidConfig an "expected baseline failure", contradicting verify.md; drop the label
Source: autopilot polish (B-089)
Done: no code change — already satisfied by B-114 (a5e1b3de8): the tracked macos/scripts/leo-runtests.sh no longer labels ConfigTests/errorsEmptyForValidConfig a baseline failure (grep "baseline" → 0).

## B-138 · Start-screen button row adapts below 450 pt content   [done]
Issue: #142
Why: content can still fall under 450 pt (window < ~651 pt, hidden sidebar in a < 450 pt window, a narrow split leaf, a side pane open) and the start-screen buttons truncate; let the row adapt (e.g. ViewThatFits)
Accept: content can still fall under 450 pt (window < ~651 pt, hidden sidebar in a < 450 pt window, a narrow split leaf, a side pane open) and the start-screen buttons truncate; let the row adapt (e.g. ViewThatFits)
Source: autopilot polish (B-091)
Done: a7f3215aebe6041ae270f2dcc32f39e3f45521b9

## B-139 · B-091 resize test hardening   [done]
Issue: #143
Why: add a per-step "clamp never shows" frame check in the live narrowing test; use a 1 pt tolerance in LeoFirstAttachWindowSizeTests.swift:193
Accept: add a per-step "clamp never shows" frame check in the live narrowing test; use a 1 pt tolerance in LeoFirstAttachWindowSizeTests.swift:193
Source: autopilot polish (B-091)
Done: 91b448d74520b0b7f7bc4a8ff68eea98d5a5f0a9

## B-140 · Return To Default Size restores a launch-clamped sidebar   [done]
Issue: #144
Why: Return To Default Size leaves a launch-clamped sidebar at ~349 pt instead of the stored 420 until relaunch; settle together with the regrow item
Accept: Return To Default Size leaves a launch-clamped sidebar at ~349 pt instead of the stored 420 until relaunch; settle together with the regrow item
Source: autopilot polish (B-091)
Done: 8a96bd527eb8cbbd49393a605c6dd899e92b1544, 01b5b5bc0e14068e6131fd52dfad4988acfaec7b

## B-141 · Inject NSApp.isHidden into isLeoWindowShown   [done]
Issue: #145
Why: the hidden branch of TerminalController.isLeoWindowShown reads a global and its real wiring is untested; inject it (DI preference)
Accept: the hidden branch of TerminalController.isLeoWindowShown reads a global and its real wiring is untested; inject it (DI preference)
Source: autopilot polish (B-093)
Done: 8016b94b4fdf5389f14e6cb9c4f9ae921c65494d

## B-142 · Off-screen 500x500 window on folder-open   [done]
Issue: #146
Why: B-093 verify: an untitled 500x500 pixels-only window at (0,550) appears on every folder-open path (cold or running); likely pre-existing — find and remove it
Accept: B-093 verify: an untitled 500x500 pixels-only window at (0,550) appears on every folder-open path (cold or running); likely pre-existing — find and remove it
Source: autopilot polish (B-093)
Done: be6f60ff7d5c34ca89f927f91585f89c986bb979, ff8302d491aacba3152dffafb175ecbd6980e231, 16f07b69226415cdf1cbd0746277600f51cd50d3

## B-143 · Replaced launch window lingers in the window list   [blocked]
Issue: #147
Why: B-093 verify: a replaced launch window stays off-screen in the CG window list; check whether its controller is ever freed
Accept: B-093 verify: a replaced launch window stays off-screen in the CG window list; check whether its controller is ever freed
Source: autopilot polish (B-093)
Question: runner timed out after 3h — it was in fix round 2 (the lane's last commit is da8d504d4 "keep waking until the window-server window is gone too", plus wip a3fe1df0d). Root cause: a closed window's controller is freed only when the event loop next wakes, so it lingers while Leo is idle; the fixes so far wake the loop until it is freed and make New Tab's undo hold the window weakly. Work kept on autopilot-lane/B-143 (held: shelve refused over untracked generated files). I'd pick: resume next run from this lane on the hard implementer.
Answer:

## B-257 · Agent stays Working while child dispatches run, plus a dispatch tree   [done]
Issue: #256
Why: Unblocks B-051 via the attention.outstanding + Snapshot.dispatches[] contract shipped in leo v0.35.0 (PR #226, spec leo docs/specs/2026-10-06-bridge-observe.md). Serves "never invent a state"
Accept: a scripted turn that starts a dispatch keeps the parent row Working until the child finishes, guarded by a regression test that replays the SSE trace; child dispatches render nested under their parent row via parent_dispatch_id; child rows appear and disappear live
Out: app-side heuristics overriding daemon state; codex/opencode subagent detection
Source: Evan (/feature, 2026-10-07)
Inbox: 20261007T144804725046Z-b671a71b#1
Done: 2026-10-07 · f3371acc7, b044b90ba, 3eb5b6f96, cb1d27825, 9cc9e591c, f9471c174, b7578c893, bdee9f0c6 · D-374, D-375, D-376, D-377, D-378, D-379

## B-258 · Attention badge and notification show the reason   [done]
Issue: #257
Why: "Needs you" is only actionable when it says what for (attention.reason from leo PR #226). Serves "never invent a state"
Accept: a scripted permission prompt shows a "permission" reason with the tool name on the badge and in the notification; question and elicitation each show their own reason; when no reason field is present, current behaviour is unchanged
Out: answering the prompt from leoterm
Source: Evan (/feature, 2026-10-07)
Inbox: 20261007T144804818307Z-97aae0e0#1
Done: 2026-10-07 · d5234d8c6 · D-380, D-381, D-382, D-383, D-384, D-385, D-386, D-387

## B-259 · Agent row shows last-turn preview and usage   [ready]
Issue: #258
Why: See what an agent just did and what it cost without attaching (agent_turn_completed + Agent.usage, leo PR #226). Serves "Calm, attention-driven"
Accept: after a scripted turn completes on autopilot-scratch the row shows a one-line preview of that turn; tokens, cost, and context % from Agent.usage appear on the row or inspector; against a daemon whose SSE hello lacks these features nothing new renders and nothing errors
Out: turn history or transcript browsing; usage charts
Source: Evan (/feature, 2026-10-07)
Inbox: 20261007T144804912652Z-653eac6a#1

## B-260 · Show the tool an agent is running right now   [ready]
Issue: #259
Why: Glanceable answer to what a working agent is busy with (current_action kind "tool", leo PR #226)
Accept: during a scripted tool call the row shows the tool name; it clears when the call ends; other action kinds keep today's display
Out: tool arguments or output
Source: Evan (/feature, 2026-10-07)
Inbox: 20261007T144805010219Z-54b3b801#1

## B-261 · Compaction indicator   [ready]
Issue: #260
Why: Explains a pause and a context reset (agent_compaction events, leo PR #226)
Accept: an agent_compaction start event shows a compacting state on the row that clears on the end event; context % updates afterwards
Out: triggering compaction (covered by the prompt box and controls item)
Source: Evan (/feature, 2026-10-07)
Inbox: 20261007T144805108862Z-f2956aed#1

## B-262 · Prompt box and interrupt, compact, and clear controls   [ready]
Issue: #261
Why: Drive an agent without attaching or typing into tmux (operator-only POST /api/v1/agents/{name}/{message,interrupt,compact,clear}, leo PR #226)
Accept: sending from the box POSTs .../message and the turn appears on the agent; interrupt, compact, and clear buttons hit their endpoints, with clear behind a confirmation; a 401/403 for a non-operator token shows an inline error and disables the controls
Out: attachments; rich multi-line editing; offline message queueing
Source: Evan (/feature, 2026-10-07)
Inbox: 20261007T144805204560Z-7cda212b#1

## B-235 · SFTP rejection diagnostic with invalid UTF-8 suffix   [ready]
Issue: #240
Why: Final B-233 security review: invalid or truncated UTF-8 suffix can suppress an earlier complete canonical rejection line; safe failure but fallback may be missed.
Accept: A complete canonical rejection line is recognized despite invalid UTF-8 in a later suffix; truncated noncanonical lines still never trigger fallback; regression tests.
Source: autopilot polish (B-233)

## B-144 · Launch-placeholder test cleanup closes pending windows   [ready]
Issue: #148
Why: LeoLaunchPlaceholderIntegrationTests close() (:90,100-101) only closes visible windows; also close windows whose controller has leoIsAwaitingPresentation, and fold the trait's duplicated MainActor.run restore into one helper
Accept: LeoLaunchPlaceholderIntegrationTests close() (:90,100-101) only closes visible windows; also close windows whose controller has leoIsAwaitingPresentation, and fold the trait's duplicated MainActor.run restore into one helper
Source: autopilot polish (B-094)

## B-145 · File ▸ New Window and ⌘N skip the palette flash   [ready]
Issue: #149
Why: File ▸ New Window while a start-screen window is key, and ⌘N (ghosttyNewWindow) from a terminal with content, still route through leoRouteNewWindow and the palette (TerminalController.swift:1638-1642); swap to the bare start screen like B-095, and document the Dock right-click New Window in AppDelegate.newWindow's doc comment
Accept: File ▸ New Window while a start-screen window is key, and ⌘N (ghosttyNewWindow) from a terminal with content, still route through leoRouteNewWindow and the palette (TerminalController.swift:1638-1642); swap to the bare start screen like B-095, and document the Dock right-click New Window in AppDelegate.newWindow's doc comment
Source: autopilot polish (B-095)

## B-147 · Rebuild the shared autopilot xcframework after B-098   [done]
Issue: #151
Why: B-098 changed src/global.zig; .git/autopilot/shared/GhosttyKit.xcframework + zig-out were built at B-072, so lanes that symlink them per verify.md run a stale libghostty; rebuild and update verify.md's note
Accept: B-098 changed src/global.zig; .git/autopilot/shared/GhosttyKit.xcframework + zig-out were built at B-072, so lanes that symlink them per verify.md run a stale libghostty; rebuild and update verify.md's note
Source: autopilot polish (B-098)
Done: no code change — shared GhosttyKit.xcframework + zig-out rebuilt 2026-10-01 17:45 from 708717ded (ghostty-internal.a newer than last src/ commit 6b44c1a22); old copies moved to ~/.Trash; suite 1962 green through the symlinks (implementer and verifier); verify.md note updated. Lane cleared on autopilot-shelved/B-147 (untracked scratch only).

## B-146 · Environ comment wording   [ready]
Issue: #150
Why: src/global.zig:309: say "environ_initialized stays set" only matters if the I/O side scanned before the sync; macos/Sources/App/main.swift:34-38: the probe runs after ghostty_cli_try_action too ("after init, before NSApplicationMain")
Accept: src/global.zig:309: say "environ_initialized stays set" only matters if the I/O side scanned before the sync; macos/Sources/App/main.swift:34-38: the probe runs after ghostty_cli_try_action too ("after init, before NSApplicationMain")
Source: autopilot polish (B-098)

## B-148 · Sidebar list stays mounted in No Agents/Loading/Failed with terminals   [ready]
Issue: #152
Why: the onAppear remount race is still reachable in those states with terminals and a filter (LeoSidebarView.swift:216); keep the list mounted when terminal rows exist; fix the doc comments that say only the first list uses onAppear (LeoSidebarView.swift:214, LeoTerminalRowReveal.swift:12)
Accept: the onAppear remount race is still reachable in those states with terminals and a filter (LeoSidebarView.swift:216); keep the list mounted when terminal rows exist; fix the doc comments that say only the first list uses onAppear (LeoSidebarView.swift:214, LeoTerminalRowReveal.swift:12)
Source: autopilot polish (B-099)

## B-149 · Reveal the selected row after AppKit layout   [ready]
Issue: #153
Why: Loading→connected leaves the row partly cut off ~7/60 (pre-existing); order the reveal after layout
Accept: Loading→connected leaves the row partly cut off ~7/60 (pre-existing); order the reveal after layout
Source: autopilot polish (B-099)

## B-150 · B-099 scroll test hardening   [ready]
Issue: #154
Why: loading test: assert rect(ofRow:).intersects(visibleRect) with a minY == 0 precondition; test the agents-going listsAgents direction; replace settledTable's 3 s first-population poll with a signal
Accept: loading test: assert rect(ofRow:).intersects(visibleRect) with a minY == 0 precondition; test the agents-going listsAgents direction; replace settledTable's 3 s first-population poll with a signal
Source: autopilot polish (B-099)

## B-151 · B-100 pane layout test measures from the window top   [ready]
Issue: #155
Why: assert the side-pane close glyph's midY is within 1 pt of topInset + headerRowHeight/2 below the window top; the B-074 sidebar bound (gap 9–16 pt) ties the panes to the window edge only indirectly
Accept: assert the side-pane close glyph's midY is within 1 pt of topInset + headerRowHeight/2 below the window top; the B-074 sidebar bound (gap 9–16 pt) ties the panes to the window edge only indirectly
Source: autopilot polish (B-100)

## B-152 · headerRowHeight is a minimum, not a height   [ready]
Issue: #156
Why: LeoSidebarHeader uses .frame(minHeight: headerRowHeight), so the sidebar row can grow and move its centre while the side panes stay at 18 pt; use .frame(height:) or rename it headerRowMinHeight
Accept: LeoSidebarHeader uses .frame(minHeight: headerRowHeight), so the sidebar row can grow and move its centre while the side panes stay at 18 pt; use .frame(height:) or rename it headerRowMinHeight
Source: autopilot polish (B-100)

## B-153 · Header centres differ by 1–1.5 px in hidden style   [ready]
Issue: #157
Why: B-100 shot: browser close ≈17, editor ≈18, sidebar + ≈18.5 px; align them exactly
Accept: B-100 shot: browser close ≈17, editor ≈18, sidebar + ≈18.5 px; align them exactly
Source: autopilot polish (B-100)

## B-154 · Titled styles: browser header close glyph tight under the titlebar   [ready]
Issue: #158
Why: B-100 verify: in titled styles the workspace-browser header's close glyph sits about 3 pt under the titlebar
Accept: B-100 verify: in titled styles the workspace-browser header's close glyph sits about 3 pt under the titlebar
Source: autopilot polish (B-100)

## B-155 · LeoLaunchFocusTests #require message wording   [ready]
Issue: #159
Why: LeoLaunchFocusTests.swift:60 says "wasn't built when the loop was rebuilt" but the check runs one turn after the rebuild; reword to "doesn't exist after the rebuild turn"
Accept: LeoLaunchFocusTests.swift:60 says "wasn't built when the loop was rebuilt" but the check runs one turn after the rebuild; reword to "doesn't exist after the rebuild turn"
Source: autopilot polish (B-101)

## B-156 · waitForSearchField counts turns instead of sleeping   [ready]
Issue: #160
Why: LeoLaunchFocusTests.swift:110-117 still polls with Task.sleep(20ms); D-178/D-254 prefer nextMainTurn() turn counting
Accept: LeoLaunchFocusTests.swift:110-117 still polls with Task.sleep(20ms); D-178/D-254 prefer nextMainTurn() turn counting
Source: autopilot polish (B-101)

## B-157 · Rebuild the key view loop after a sidebar or pane toggle   [ready]
Issue: #161
Why: while the window stays key, Tab uses the old loop after a sidebar/pane toggle until the window becomes key again (documented in B-101's comment); rebuild it on toggle
Accept: while the window stays key, Tab uses the old loop after a sidebar/pane toggle until the window becomes key again (documented in B-101's comment); rebuild it on toggle
Source: autopilot polish (B-101)

## B-158 · Document LeoMenuXib's ignored modifier flags   [ready]
Issue: #162
Why: LeoMenuXib.swift:52-56: the live encoder ignores .function/.numericPad/.capsLock; the old exact-.command check was dropped silently — document it
Accept: LeoMenuXib.swift:52-56: the live encoder ignores .function/.numericPad/.capsLock; the old exact-.command check was dropped silently — document it
Source: autopilot polish (B-102)

## B-159 · liveShortcutsDecodeLikeTheXib compares against the xib decoder   [ready]
Issue: #163
Why: it compares hard-coded strings rather than the xib decoder's output; add a bare "T" (→ "⇧t") case so the name holds
Accept: it compares hard-coded strings rather than the xib decoder's output; add a bare "T" (→ "⇧t") case so the name holds
Source: autopilot polish (B-102)

## B-160 · Live ⌘O check can pass vacuously   [ready]
Issue: #164
Why: chooseAgentIsCommandO's live check passes if the live walk returns nothing; assert the walk finds Choose Agent… on "⌘o"
Accept: chooseAgentIsCommandO's live check passes if the live walk returns nothing; assert the walk finds Choose Agent… on "⌘o"
Source: autopilot polish (B-102)

## B-161 · Retitle signal: wait for a stable measurement   [ready]
Issue: #165
Why: the pixel-width retitle signal could pass on a half-laid-out first render; measure until two consecutive turns agree or require titleEnd past icon+gap; it also depends on "vim notes.md" drawing wider than "Terminal" (fragile if fonts or the fixture change)
Accept: the pixel-width retitle signal could pass on a half-laid-out first render; measure until two consecutive turns agree or require titleEnd past icon+gap; it also depends on "vim notes.md" drawing wider than "Terminal" (fragile if fonts or the fixture change)
Source: autopilot polish (B-103)

## B-162 · turns(limit:until:) stops when the condition holds and gets a clearer name   [ready]
Issue: #166
Why: it keeps evaluating condition() after it turns true (up to ~50 extra renders) — use a while loop; rename to e.g. turnsUntil(_:limit:) to avoid confusion with afterPendingUpdates' turns:
Accept: it keeps evaluating condition() after it turns true (up to ~50 extra renders) — use a while loop; rename to e.g. turnsUntil(_:limit:) to avoid confusion with afterPendingUpdates' turns:
Source: autopilot polish (B-103)

## B-163 · Drop remaining project-history comments in LeoSidebarTerminalScrollTests   [ready]
Issue: #167
Why: :256 ("before B-081"), :390 ("only wait on time (B-099)") and the retitle test's "B-078 (D-130)" opener: keep IDs as labels, drop the history
Accept: :256 ("before B-081"), :390 ("only wait on time (B-099)") and the retitle test's "B-078 (D-130)" opener: keep IDs as labels, drop the history
Source: autopilot polish (B-103)

## B-164 · F-key config rebinds reach menu items and hints   [ready]
Issue: #168
Why: map GHOSTTY_KEY_F1…F25 in Ghostty.keyToEquivalent / keyboardShortcut(for:) so a binding like super+f1=new_tab shows on the menu item and the start-screen hint (B-104 left it: upstream drops F-keys)
Accept: map GHOSTTY_KEY_F1…F25 in Ghostty.keyToEquivalent / keyboardShortcut(for:) so a binding like super+f1=new_tab shows on the menu item and the start-screen hint (B-104 left it: upstream drops F-keys)
Source: autopilot polish (B-104)

## B-165 · Shortcut hint test helper takes a reconnect: parameter   [ready]
Issue: #169
Why: LeoShortcutHintsTests.swift:351 passes the Reconnect item through the chooseAgent: parameter; give it its own parameter
Accept: LeoShortcutHintsTests.swift:351 passes the Reconnect item through the chooseAgent: parameter; give it its own parameter
Source: autopilot polish (B-104)

## B-166 · LEO_FORCE_DISCONNECTED sometimes doesn't arm on first launch   [ready]
Issue: #170
Why: B-104 verify: the DEBUG fixture didn't take effect on the first launch; a relaunch worked — possible arming race
Accept: B-104 verify: the DEBUG fixture didn't take effect on the first launch; a relaunch worked — possible arming race
Source: autopilot polish (B-104)

## B-167 · Pin the Terminals section as non-collapsible   [ready]
Issue: #171
Why: LeoSidebarView.swift:304's labels.count + 1 assumes the section is never natively collapsed; if a .sidebar List lets users hide it, last-N rows could include agent rows and land falsely — confirm or add .collapsible(false)
Accept: LeoSidebarView.swift:304's labels.count + 1 assumes the section is never natively collapsed; if a .sidebar List lets users hide it, last-N rows could include agent rows and land falsely — confirm or add .collapsible(false)
Source: autopilot polish (B-105)

## B-169 · runtests.sh baseline message contradicts verify.md   [done]
Issue: #173
Why: runtests.sh still labels ConfigTests/errorsEmptyForValidConfig "an expected baseline failure"; verify.md says to treat a failure of that test as real (see also B-137)
Accept: runtests.sh still labels ConfigTests/errorsEmptyForValidConfig "an expected baseline failure"; verify.md says to treat a failure of that test as real (see also B-137)
Source: autopilot polish (B-147)
Done: no code change — already satisfied by B-114 (a5e1b3de8), same as B-137.

## B-168 · Drop dead non-flipped branches in LeoTerminalsViewport   [ready]
Issue: #172
Why: scrollToTop/unobscuredBounds (LeoTerminalsViewport.swift:68,:78) have untested, unreachable non-flipped branches (NSTableView is flipped) — drop or test them
Accept: scrollToTop/unobscuredBounds (LeoTerminalsViewport.swift:68,:78) have untested, unreachable non-flipped branches (NSTableView is flipped) — drop or test them
Source: autopilot polish (B-105)

## B-170 · isOffScreen fails loudly on a bad row index   [ready]
Issue: #174
Why: LeoSidebarTerminalScrollTests.swift:543 returns true for a row that doesn't exist, so a bad index would pass the off-screen precondition silently
Accept: LeoSidebarTerminalScrollTests.swift:543 returns true for a row that doesn't exist, so a bad index would pass the off-screen precondition silently
Source: autopilot polish (B-106)

## B-171 · A focus report after a shell closes could reselect another agent   [ready]
Issue: #175
Why: B-106 review (unconfirmed): after the last shell closes and the list lands, a late focus report could reselect a different agent a turn later; pin with a test through the real attach/focus path
Accept: B-106 review (unconfirmed): after the last shell closes and the list lands, a late focus report could reselect a different agent a turn later; pin with a test through the real attach/focus path
Source: autopilot polish (B-106)

## B-172 · Drain pending reconciles before a sidebar click selects   [ready]
Issue: #176
Why: a sidebar click queued just before the row's pane closes runs ahead of the drain hop, selects nil, and leaves the adopted row unselected; drain in showTerminal or isOpen/selectShownTerminal (B-107 concurrency review)
Accept: a sidebar click queued just before the row's pane closes runs ahead of the drain hop, selects nil, and leaves the adopted row unselected; drain in showTerminal or isOpen/selectShownTerminal (B-107 concurrency review)
Source: autopilot polish (B-107)

## B-173 · pendingFocusMovesLand polls instead of sleeping 1 s   [ready]
Issue: #177
Why: replace the fixed 1 s sleep with an eventually-poll on firstResponder/focusedSurface (moveFocus retries on asyncAfter timers); a disclosed D-178 exception that could flake under a main-thread stall
Accept: replace the fixed 1 s sleep with an eventually-poll on firstResponder/focusedSurface (moveFocus retries on asyncAfter timers); a disclosed D-178 exception that could flake under a main-thread stall
Source: autopilot polish (B-107)

## B-174 · Close Terminal undo window is only 5 s by default   [ready]
Issue: #178
Why: B-108 verify needed undo-timeout=300s to reach Edit ▸ Undo from the menu; with the default 5 s a human may barely use the restore path — consider a longer Leo default
Accept: B-108 verify needed undo-timeout=300s to reach Edit ▸ Undo from the menu; with the default 5 s a human may barely use the restore path — consider a longer Leo default
Source: autopilot polish (B-108)

## B-054 · Bug — template lists are empty in New Agent and row Set Template   [done]
Issue: #59
Why: with a remote host selected, creating an agent or changing its template shows no templates (principle 3, local = remote; principle 4, everything through Leo)
Accept: with a remote host selected, the New Agent sheet's Template picker lists the remote daemon's templates, not the local CLI's (test with a fake remote fetch); a row's right-click Set Template submenu lists the host's templates on the first open, confirmed by a debug-build screenshot; after a host switch both lists show the new host's templates, never the old host's (test)
Out: no changes to the Agents menu bar ▸ Set Template path (already works); no template editing or creation UI
Note: diagnosis 2026-09-28: (1) SpawnAgentModel.loadTemplates() always calls the local cli.templateList(), ignoring the selected host (the laptop's own leo returns []); LeoAgentActions.templates() already handles remote hosts through LeoTemplateCache plus an ssh exec, verified working from the laptop. (2) LeoAgentRow's Set Template Menu inside .contextMenu fills from row @State through a .task, which likely never runs in the NSMenu-snapshotted context menu (unconfirmed; reproduce first). Suggested fix: one published, host-aware template list on LeoAgentActions, prefetched on host change, read by both.
Source: Evan (/feature, 2026-09-28)
Inbox: 20260929T012753703255Z-9360b771#1
Done: 3a2205a65 (1573 tests, lint clean, review clean). Root causes: SpawnAgentModel used the local CLI regardless of host; the row fetched templates itself after the context menu was built. Verified by screenshot: row Set Template submenu filled on first open (B-054-3), New Agent sheet (B-054-4). The sheet's Template popup and the remote-host path were not visually verified (no AX on the sheet; no autopilot remote host); covered by LeoTemplateListTests with a fake remote.

## B-061 · Tests: inject the template fetch so LeoRuntime tests don't run real ssh   [done]
Issue: #65
Why: since B-054, selecting the remote host "work" in LeoRuntimeConnectionTests also starts a real `/usr/bin/ssh -o BatchMode=yes evan@work … template list` (tests already open real tunnels there). Hang/isolation risk.
Accept: LeoRuntime takes an injectable template-fetch runner; tests pass a fake; no test spawns ssh for templates (assert via the fake).
Out: the existing tunnel tests' real ssh use.
Source: B-054 implementer + review
Done: f859b45c5. LeoRuntime takes an injected template-fetch runner; tests pass a recording fake, so no test spawns ssh for templates Decision D-200.

## B-055 · One content area per window; sidebar selects what's shown   [done]
Issue: #60
Why: principle 6 (the sidebar is the navigation) and principle 1 (Mac-native: Mail/Finder switch content from the sidebar, no tabs)
Accept: no tab bar appears in any window, including after ⌘N or a restored session; clicking a row, Return, or palette choice shows that agent in the window's content area, replacing what was shown; the sidebar (width, collapse, scroll, search) never changes or redraws on a switch (before/after screenshot pair); one agent is on screen in at most one window, and selecting it elsewhere focuses that window (as B-047); tab-only affordances (Attach in New Tab, ⌘-click/⌘↩ new tab, start-tab fill) are removed or remapped, each logged; tests plus screenshots with autopilot-scratch only
Out: the live pool (B-056), plain-shell rows (B-057), splits (B-058); multi-window layouts beyond ⌘N
Source: Evan (/vision revision, 2026-09-28)
Done: 4134ce4f4 6fb5c8c8d (1593 tests, lint clean; general + lifecycle reviews: no blockers). Verified by screenshots: B-055-1 → -2 (start screen → autopilot-scratch in the content area; no tab bar; sidebar geometry unchanged; window titled with the agent; one tmux client), -3 (⌘N window, no tab bar, on-screen row highlighted), -4 (clicking scratch from the new window focused the existing one and closed the untouched start window; still one client).

## B-062 · Rename tab-era internals (AttachTabHost, tabCount, LeoTabTitleSource)   [done]
Issue: #66
Why: after B-055 there are no tabs; internal names still say "tab" (kept to shrink B-055's diff).
Accept: mechanical rename to content/window vocabulary; unify the two "is this an agent" predicates (attachment.isAttach vs leoAgentName, B-056 review) into one source; prune contentVersion on window close; fix LeoLivePoolIntegrationTests' `hiddenSurfaces(in: fixture.origin)` assertions, which check a test-local session id and so pass vacuously; no behaviour change; suite green.
Out: behaviour changes.
Source: B-055 implementer
Done: 93b48c55f, 419cb7a7f, 16e2c07cb, 14a6cfe2c, 99e7b46aa, 465cad581. Tab-era internals renamed to content/attach vocabulary; one agent predicate (isRegisteredAgent primitive, isAgent union); contentVersion pruned on window close; vacuous pool assertions fixed; no behaviour change Decisions D-201..D-205.

## B-056 · Live surface pool: instant switches, detach beyond it   [done]
Issue: #61
Why: principle 6 (switching must feel instant) and principle 2 (calm: no flicker or redraw on switch)
Accept: switching back to one of the N most recently viewed agents shows its existing surface with Ghostty scrollback, scroll position and selection intact, with no new tmux client (test via the attach count); selecting an agent outside the pool evicts the least recently viewed one (its tmux client detaches) and attaches the new one; the tmux client count never exceeds N per window, and none leaks after a close or quit; after an agent restart the shown surface reattaches in place; N is a named constant chosen and logged by autopilot; works the same over the SSH tunnel
Out: persisting pools across app launches; per-agent pinning into the pool
Source: Evan (/vision revision, 2026-09-28)
Done: b9e6ec48a 9d4b8033b b40d3a4bb (1636 tests, lint clean; 1 fix round; re-review: all fixes hold, no CRITICAL/HIGH). Verified live with autopilot-scratch: hide → reveal kept the same tmux client (same tty and created time) and scrollback (B-056-2 → -3, fixed build); cross-window selection released the other window's hidden copy and attached one fresh client (B-056-4, pre-fix build). Eviction past N=4 needs 5 agents: tests only. SSH path: tests only (no autopilot remote host).

## B-063 · Bug — running agents' sidebar order keeps switching   [done]
Issue: #67
Type: bug
Report: The order of the running agents in the sidebar keeps switching around. It's a little jarring.
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-09-29)
Inbox: 20260929T161723581510Z-15416219#1
Done: 857387ff9 745f2568e 554584894 1479faac8 (1707 tests, lint clean; general review clean; 0 fix rounds. Root cause: busy agents' last_activity_at leapfrogged on every snapshot; fixed with streak hysteresis (D-118..D-121). Verified by tests (5 of 8 new tests fail on the test-only commit); shots B-063-1..9 show a stable order, but agents were idle so the live leapfrog wasn't exercised)

## B-064 · Bug — no spacing at the top of the sidebar   [done]
Issue: #68
Type: bug
Report: Can we also fix the spacing at the top of the sidebar? It looks like between the title bar of the window, the agents text, and the plus button, there's no space.
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-09-29)
Inbox: 20260929T161756385296Z-8ceb2d26#1
Done: 2c56d320f 35f2f475f 4331c902a (1711 tests, lint clean; general review clean; 0 fix rounds. Header now has a 10 pt top inset and ≥8 pt title–button gap via LeoSidebarChromeMetrics (shared with B-065). Verified at native pixels in shot B-064-1: ~14 pt clear below the titlebar, + on the same row. Hidden-titlebar style → B-074)

## B-066 · Bug — ⌘T shortcut collides (agent palette vs quick terminal)   [done]
Issue: #69
Type: bug
Report: I think we have Command-T opening the agent palette but we also have it for the quick terminal so I think we need to update those keyboard shortcuts.
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-09-29)
Inbox: 20260929T161943538717Z-c7a22381#1
Done: 930a1f331 (1713 tests). ⌘T was already New Terminal alone after B-057; the remaining clash was the start screen's Choose Agent… tooltip still saying ⌘T. It now reads ⌘O from one constant tied to the menu item by a test. Quick Terminal has no default key (upstream unbound). If ⌘T still opens the quick terminal, check for a toggle_quick_terminal keybind in your personal Ghostty config. Decisions D-125..D-128.

## B-065 · Sidebar convenience button bar (Quick Terminal, New Terminal)   [done]
Issue: #70
Why: One-click access to common window actions from the sidebar, which is the navigation (principle 6), without making a shortcut the only way in; every button also keeps its menu item and shortcut (principle 1).
Accept: a compact bar of SF Symbol icon buttons sits in the sidebar (header or footer, agent's call per HIG) and matches the corrected top-spacing layout; the Quick Terminal button toggles Ghostty's quick terminal (same action as the menu item/shortcut), verified by screenshot of it opening and closing; the New Terminal button creates and selects a plain-shell row exactly as ⌘T does (after B-057); each button has a tooltip naming its shortcut and an accessibility label; tests plus screenshots from the isolated debug build
Out: any other buttons (settings, new agent, search, etc.) — add later as separate items; user-customizable button sets; restyling the rest of the sidebar
Source: Evan (/feature, 2026-09-29)
Inbox: 20260929T161921499761Z-63fc4dc4#1
Done: 2b4c91a31, 84a74db61, 20f63fa80. A sidebar footer bar with New Terminal and Quick Terminal icon buttons; tooltips name the live shortcut; same actions as the menu items Decisions D-206..D-211.

## B-057 · Plain shells as "Terminals" sidebar rows   [done]
Issue: #62
Why: principle 6 (everything on screen comes from a sidebar row) and principle 1 (every action has a shortcut and a menu item)
Accept: a "Terminals" section lists open plain shells, titled by the terminal title; ⌘T (and File ▸ New Terminal) creates a shell and selects it; closing a shell (⌘W, or exit) removes its row and selects a neighbour; shells take part in the live pool like agents; the section hides when empty; tests plus a screenshot
Out: naming or pinning shells; shells on remote hosts beyond what Ghostty already does
Source: Evan (/vision revision, 2026-09-28)

Done: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c(1700 tests via env-preset runner, lint clean; general + concurrency reviews; implementer-hard, 3 fix rounds). Fixed both prior HIGHs (exit racing a reveal; busy hidden shells now confirm on tab-close/⌘Q). Verified by screenshots B-057-9 (Terminals section, two rows, newest selected), -10 (Close selects neighbour), -11 (section hides when empty). exit, OSC title and pool behaviour: tests only. Follow-ups B-067..B-072.
## B-058 · Splits inside the content area   [idea]
Issue: #63
Why: principle 6 (the layout belongs to the selected row) with splits kept (D-100)
Accept: ⌘D and the editor/file pane still split the content area; a split can show a second agent or shell, picked from the sidebar or palette; every row on screen is highlighted in the sidebar, the focused one distinctly; switching away from a split layout and back restores it intact; tests plus a screenshot of an agent + shell split with both rows highlighted
Out: saved layouts; dragging rows into splits (later polish)
Source: Evan (/vision revision, 2026-09-28)
Note: B-071 verify saw ⌘D / Split Right open the agent palette instead of splitting directly; settle this here.
Question: runner timed out after 3h — build mode, mid fix round: two delta reviews agreed the 4 earlier fixes hold and 1 blocking item remains (the on-screen row reveal only fires once); a verify was in progress. Lane's last commit 36ebe103c. Work kept on autopilot-lane/B-058 (held: shelve refused on untracked build output). Resume it next run?
Answer: punt — not sure we need it; don't resume. Keep the held lane/branch autopilot-lane/B-058 as-is; park the item.
Parked: Evan, 2026-09-30 (D-212). Held lane autopilot-lane/B-058 kept as-is. "/feature B-058" to revive.

## B-175 · Window renders inactive right after Undo New Split   [ready]
Issue: #179
Why: B-108-5: grey traffic lights after Edit ▸ Undo New Split; possible key-window blip
Accept: B-108-5: grey traffic lights after Edit ▸ Undo New Split; possible key-window blip
Source: autopilot polish (B-108)

## B-060 · One sidebar per window, shared by all its tabs   [dropped]
Dropped: superseded before it was built, since tabs are removed (D-098, D-101). Recorded so the queued inbox line is skipped.
Source: Evan (/feature, 2026-09-28)
Inbox: 20260929T012306706070Z-b5d95371#1

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

## B-014 · All hosts at once as sidebar sections   [blocked]
Issue: #239
Question: Blocked per D-008 until several remotes are in daily use. Tell me when that's true. I'd pick keeping it blocked.
Note: Previous answer accepted keeping this out of the ready queue; Evan changed the status to blocked on 2026-10-05.
Answer:

## B-046 · Surfaced files: keep `at` order through a partial /state merge   [done]
Issue: #51
Accept: a partial baseline appends event-only files as newest, so `[t1, t2(live), t3]` becomes `[t1, t3, t2]` and ⌥⌘O picks t2 (`LeoSurfacedFileIndex.swift:64`). Place event-only files by `at` when merging. Also: a full (20-sent) baseline whose entries are all malformed returns early and leaves stale live files (`:59`); treat it as an empty full baseline. Failing tests first.
Source: B-013 third review (dismissed as non-blocking)
Done: a91e50296 a70d51027 (1463 tests). Event-only files placed by `at` in partial merges (shared rule with live events); an all-malformed full baseline clears stale live files; cleared incarnations leave the 64-slot LRU (D-092). Tests: partial-merge order, ⌥⌘O picks t3 after `[t1, t2(live), t3]` (red on pre-B-046 code), malformed full baseline, cleared-incarnation bound. Not visually verified: index-only change, no UI change. 1 fix round (review.concurrency LOW: empty cleared entry held an LRU slot); round 2 clean.


## B-047 · One tab per agent — sidebar and palette focus the existing tab   [done]
Issue: #52
Why: Clicking an agent row, or choosing an agent in the palette (Choose Agent… / ⌘T picker), goes to that agent's open tab instead of attaching a duplicate. Serves "Everything through Leo" (no hunting for an agent's tab) and "Keyboard-first".
Accept: With a tab already attached to agent X, clicking X's row (highlighted or not) selects that tab and focuses its terminal, and the tab count stays the same; the same happens when X is chosen from the palette, including when the tab is in another window (that window comes forward); with no tab open for X, clicking or choosing X attaches a new tab as it does today; ⌘-click on a row and ⌘-Return in the palette force a new tab (Safari convention; shown in the menu or tooltip); the row's tab-count glyph is removed (Evan approved the removal 2026-09-24); tests cover the lookup for each entry point, plus a screenshot from the isolated debug build using autopilot-scratch.
Out: Closing or merging duplicate tabs that already exist (focus the most recently used one); changing Split (⌘D), which still attaches a new split; any per-agent limit enforced by the daemon.
Source: Evan (/feature, 2026-09-24)
Inbox: 20260925T002247437461Z-47b2bf9d#1
Done: d403a2c9a (1477 tests). Row click and palette choice (⌘T, Choose Agent…) focus the agent's open tab via B-006's lookup (host + name, most recent); ⌘-click / ⌘↩ / row menu "Attach in New Tab" force a new tab; tab-count glyph removed (D-020 superseded); decisions D-093. Verified: shots B-047-1 (scratch attached in its own window), B-047-2 (row click from the other window brings that window forward; still one tmux client, no new window). Palette path and ⌘↩ not visually verified (peekaboo dismissed the palette on refocus) → B-048. Review clean, 0 fix rounds.

## B-048 · Verify palette ⌘↩ vs Toggle Full Screen   [done]
Issue: #53
Accept: in the isolated debug build, the agent palette's ⌘↩ opens a new tab for the chosen agent and does not toggle full screen (the main menu's Toggle Full Screen is also ⌘↩; `LeoAgentPalettePanel.swift:120` intercepts in performKeyEquivalent). Also confirm ⌘-click on an already-selected row leaves it selected. Add a test if either is wrong. Screenshot with autopilot-scratch only.
Source: B-047 implementer report (unverified in the GUI)
Done: e13738b88 0604cc27f 5bd615a31 (1497 tests). Palette ⌘↩ was already correct: it opens a new tab, also when the agent has one, and never toggles full screen (shots B-048-2, -3). The sidebar ⌘-click was broken: it deselected the row and opened no tab, because the List toggled the selection and SwiftUI tap gestures don't fire in non-key windows. Fixed with a required selection and `LeoRowClickCatcher`; double-click and the Attach button now act exactly once; decisions D-094. Verified: the double-click attaches once (B-048-1), the row stays selected after a ⌘-click (checked in this run), and the palette ⌘↩ forces a new tab (B-048-3). The ⌘-click attach itself was not visually verified, because peekaboo's synthetic ⌘-clicks don't reliably reach the app; end-to-end tests post real mouse events to a non-key window instead. 2 review fix rounds.

## B-051 · Bug — working agents show "Finished" (suspected subagents)   [ready]
Issue: #54
Why: The status badge has to be trustworthy or the attention model means nothing. Serves "Calm, attention-driven: never invent a state".
Accept: Reproduce on autopilot-scratch with a scripted turn that starts a background subagent, then record the SSE attention events and the row's state over time; name the root cause (app mapping vs daemon hook semantics) with that trace as evidence; if it's app-side, fix it test-first with a failing test that replays the trace; if it's daemon-side, write the contract change (e.g. keep `working` until SubagentStop / background tasks finish) as a spec and block on Evan.
Out: Adding app-side heuristics that override daemon state; Codex/opencode subagent detection.
Source: Evan (/feature, 2026-09-28)
Inbox: 20260928T193703549149Z-2d2188b3#1
Question: Needs Evan to do: send the daemon contract change to the leo agent, and time the leo release/restart. Reply "B-051: done" once it's done.
Answer: done
## B-052 · Attach tabs are titled with the agent's name   [done]
Issue: #55
Why: Tabs should tell you which agent is inside at a glance, so you don't have to click through them. Serves "Everything through Leo" (no hunting for an agent's tab).
Accept: A tab attached to agent X shows "X" as its tab and window title, whatever the terminal inside sets via OSC; with splits, the title follows the focused split's agent; a title the user sets with Ghostty's Change Title… still wins; non-attach tabs (start page, plain shells) keep Ghostty's normal title; the name stays after reattach or an agent restart; tests cover the title source for each case, plus a screenshot from the isolated debug build using autopilot-scratch only (tab bar showing "autopilot-scratch").
Out: Status badges or icons in the tab; showing the terminal's own title alongside the name (autopilot may put it in the tooltip); renaming agents.
Source: Evan (/feature, 2026-09-28)
Inbox: 20260928T193739823707Z-618b4900#1
Done: ee274b7f9 (1513 tests). The focused surface's agent name drives the tab and window title through `LeoTabTitleSource`; OSC titles are ignored for attach tabs; Change Tab Title… and Change Terminal Title… still win; splits follow the focused split's agent; decisions D-095. Verified: shots B-052-1 (tab and window read autopilot-scratch while Claude and tmux set their own titles; the start tab keeps 👻 Ghostty), -2 (Change Tab Title… "my-tab" wins), -3 (clearing it restores the name), -4 (the name persists after an agent restart), -5 (the reattached tab is named). Change Terminal Title… and split focus are covered by tests only. Review clean, 0 fix rounds. Reattach-in-place gap → B-053.

## B-050 · First attach fills the start-page tab   [done]
Issue: #56
Why: Opening your first agent shouldn't leave an empty start-page tab behind. Serves "Mac-native" (Safari fills a blank tab rather than opening a new one) and "Calm".
Accept: With only the start page open in the key window, clicking a sidebar row, choosing from the palette, or Agents ▸ Attach attaches in that tab instead of adding one, so the tab count stays 1; this only happens while the start tab is still untouched (no typing, no editor or browser pane), otherwise a new tab opens as today; ⌘-click / ⌘↩ still force a new tab; tests cover each entry point, plus screenshots from the isolated debug build using autopilot-scratch only (before and after the first attach, one tab).
Out: Reusing start-page tabs in other windows; changing what the start page shows; Split (⌘D).
Source: Evan (/feature, 2026-09-28)
Inbox: 20260928T193703430864Z-eed13c51#1
Done: 6875f2be7 14951a372 (1534 tests, twice). An attach into a lone untouched start tab fills it; if the agent already has a tab, that tab is focused and the start tab closes; decisions D-096. Fixed an existing bug: the untouched check used pane view refs that always exist. Verified: shots B-050-1 → -2 (a double-click in a start-only window attaches in place; one tab, same window), -3 → -4 (a row click from a fresh start window jumps to scratch's window and the start window closes; still one tmux client). ⌘-click, a touched start tab, and Agents ▸ Attach are covered by tests only. 1 fix round: the new integration suite showed real windows that stole key status from GhosttyAttachTabHostFocusTests; it now builds them hidden.

## B-049 · Click a row to open its agent; ask before starting a stopped one   [done]
Issue: #57
Why: One click on any sidebar row takes you into that agent, so there's no hover button to aim for. Serves "Everything through Leo" and "Mac-native" (a row is the target, like Finder or Mail).
Accept: The hover "Attach" button is gone from rows (the context menu keeps Attach, Attach in New Tab and Start); a single click on a running agent with no open tab attaches a new tab, and a click on one with a tab still focuses that tab (B-047), with ⌘-click still forcing a new tab; a click on a stopped agent shows a sheet "Start <name>?" (Start / Cancel), and Start starts it through the daemon then attaches once it reports running, while Cancel leaves the agent and tabs untouched; arrow keys still only select and Return acts like a click; tests cover each click path, plus screenshots from the isolated debug build using autopilot-scratch only (row without the button, the start prompt, the attached tab after Start).
Out: Auto-starting without asking; changes to Split (⌘D) or the palette's behaviour for running agents; restart/stop flows; errored-agent recovery beyond showing the same prompt.
Source: Evan (/feature, 2026-09-28)
Inbox: 20260928T193634323347Z-31fbe8d8#1
Done: a9dbf4e11 11930305f cf5025227 (1566 tests). The hover Attach button is gone. A single click opens a running agent: it focuses the agent's tab, or attaches (filling a lone start tab). A non-running agent gets a "Start <name>?" sheet, and the attach happens only once the daemon reports it running. Return acts like a click, arrows only select, and the row has an "Open" accessibility action; decisions D-097. Verified: shots B-049-1 (no button), -2 (the Start prompt), -3 (a single click on running scratch attaches in place), -4 (Start → attached once running); Cancel via Escape left the agent stopped with no tab. The "Starting…" state wasn't captured, and VoiceOver wasn't exercised. 2 review fix rounds (row identity across a re-sort; accessibility).

## B-053 · Reattach after an agent restart refills the exited tab   [dropped]
Dropped: superseded by the tab-bar removal (D-098, D-101); in-place reattach after a restart is part of B-056.
Issue: #58
Accept: After an attached agent restarts, its tab shows the "No Agent Attached" placeholder but keeps the agent's name (D-095). A sidebar double-click, Return, or palette choice for that agent should refill that placeholder, and focus it, instead of opening a new tab beside it. Today you get two same-named tabs, one of them empty (seen in B-052 verification, shots B-052-4/-5). ⌘-click / ⌘↩ still force a new tab. Test the lookup (an exited placeholder carrying the agent's name counts as that agent's tab). Screenshot with autopilot-scratch only.
Source: B-052 verification

## B-059 · Keyboard switching between rows   [ready]
Issue: #64
Why: principle 1 (keyboard-first; every action has a shortcut and a menu item)
Accept: the old tab shortcuts are remapped to rows (⌘1–⌘9 select the Nth visible row, ⌃Tab/⌃⇧Tab or ⌘⇧]/[ go to the next/previous row, ⌃⌥⌘J still jumps to the next agent that needs you); each has a Window-menu item; the shortcuts skip collapsed sections; tests cover each shortcut
Out: user-configurable bindings beyond Ghostty's keybind config
Source: Evan (/vision revision, 2026-09-28)

## B-178 · Hidden Close checks every pane of the kept tree   [ready]
Issue: #182
Why: B-177 review: hidden-row Close could check needsConfirmQuit on every pane of the kept tree, not just the row's own (cheap guard; a cross-window Move Split via B-110 might yield an all-row tree); also fix the discardKept doc wording
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-177)

## B-179 · Tighten aRowWithABusySplitBesideItIsNeverKeptForCloseToKill   [ready]
Issue: #183
Why: B-177 review: its last two lines check nothing (the row is already gone); drop them or assert there's no sheet; add a LeoLiveSurfaces unit test pinning "a kept tree is only a lone row"
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-177)

## B-180 · Terminals row context menu shows key equivalents   [ready]
Issue: #184
Why: B-177 review: menu items show no ⌘D, ⇧⌘D, ⌘W hints (P1); add display-only ones if SwiftUI's contextMenu supports them
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-177)

## B-181 · Rename Terminal sheet hangs from the title bar   [ready]
Issue: #185
Why: B-177 verify: the Rename sheet appears centred in the window rather than attached as a sheet from the title bar (HIG)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-177)

## B-182 · Clearing a custom name after restore restores the live title   [ready]
Issue: #186
Why: B-177 review: after a restore, clearing a custom name brings back the saved name, not the live title, until the shell sends a new OSC title (decode sets titleFromTerminal = title)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-177)

## B-183 · Clearing a row name can drop a just-arrived OSC title   [ready]
Issue: #187
Why: B-177 review: clearing a name within 75 ms of an OSC title can drop that newer title (upstream race)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-177)

## B-184 · Drive row-menu Split in GUI verification   [ready]
Issue: #188
Why: B-177 verify: menu Split wasn't driven in the GUI (it opens the palette with real agents listed); tests cover it — find a safe GUI path (e.g. filter to autopilot-scratch)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-177)

## B-185 · Keep the "may have been created" warning across a same-host retry   [ready]
Issue: #189
Why: B-176 review: add .removeDuplicates() on the selectedHost stream — retry() re-selects the same host, which clears the warning
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-176)

## B-186 · Late spawn result message wording   [ready]
Issue: #190
Why: B-176 review: reword to "Connection changed; the agent was created on X" (a same-host retry also bumps the generation, and the daemon reported success); prefix late spawn errors with the host's name
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-176)

## B-187 · "Not connected to X yet" after a failed tunnel   [ready]
Issue: #191
Why: B-176 review: drop "yet" when the tunnel has failed for good; pass daemonHost: .local explicitly at LeoRuntime.swift:246
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-176)

## B-188 · LeoAgentActions.spawn enforces the expected host itself   [ready]
Issue: #192
Why: B-176 review: guard hostSelection.selected == expectedHost inside spawn, not only via the disabled Create button
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-176)

## B-189 · Stricter owner/repo and branch validation in the New Agent sheet   [ready]
Issue: #193
Why: B-176 review: ownerRepo per segment ([A-Za-z0-9._-], no leading "-", not "."/"..") — real fix belongs in leo's ValidateRepo (ask the leo agent); catch more invalid branch names inline ("feat/.x", "a.lock/b", bare "@")
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-176)

## B-190 · New Agent in Worktree sheet layout   [ready]
Issue: #194
Why: B-176 verify: Host and Repository rows are tight and the branch hint sits under the label column
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-176)

## B-191 · anEmptyNameRestoresTheLiveTitle flakes under load   [ready]
Issue: #195
Why: B-111 verify: LeoTerminalRowMenuIntegrationTests/anEmptyNameRestoresTheLiveTitle failed once under load (line 161 eventually-timeout on the "  " case); not in verify.md's known-flake list
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-111)

## B-192 · Template-list tests use the shared fakes throughout   [ready]
Issue: #196
Why: B-112 review: LeoTemplateListTests.swift:114 builds its LeoCLI fake by hand (use .recordingForTests(runner:)); GatedTemplateProcess(gated: false) at :110 doubles as a plain remote fake — give LeoRecordingTemplateRunner a status: parameter, or merge the two gated fakes (LeoAgentActionsTests.swift:318, LeoTemplateListTests.swift:136) into the shared support file
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-112)

## B-193 · verify.md: New Agent sheet driving tips   [ready]
Issue: #197
Why: B-112 verify: the Agents > New Agent… menu click never landed; the sidebar "+" button worked, and a sheet popup can be clicked with see --json + click --on <elem> --snapshot <id>
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-112)

## B-194 · Host-selection runner has no real-runner default   [ready]
Issue: #198
Why: B-112 note: LeoRuntime.hostSelectionRunner and LeoHostSelection.init still default to the real runner (host-selection ssh); inject it like the template runner
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-112)

## B-195 · closingAHiddenRowGivesNothingOnScreenItsSlot flakes under load   [ready]
Issue: #199
Why: B-112 verify: LeoTerminalRowsIntegrationTests/closingAHiddenRowGivesNothingOnScreenItsSlot hit its 5 s eventually timeout once at load 120
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-112)

## B-196 · Strengthen aDisplacedStartScreenSurfaceIsFreed   [ready]
Issue: #200
Why: B-113 review: its placeholderSurfaceIDs check is always true (inserted synchronously) and doesn't prove the overlay mounted; assert the start-screen button/hosting view is in the hierarchy, or reword the doc comment
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-113)

## B-197 · Test start-screen per-button wiring   [ready]
Issue: #201
Why: B-113 review: LeoPlaceholderView.swift:61-66 { buttonActions.perform(button) } could regress to a fixed button unnoticed; extract a tiny testable helper. Also fix the leftover "terminal drawer" in LeoStartScreenState.swift:10's doc comment
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-113)

## B-198 · openPicker closure holds the SurfaceView strongly   [ready]
Issue: #202
Why: B-113 review: TerminalView.swift:200 (pre-existing) captures the SurfaceView strongly; capture only its id, per the never-hold-the-surface rule
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-113)

## B-199 · Quick Terminal button re-opens the panel instead of closing it   [ready]
Issue: #203
Why: B-113 verify: clicking a Quick Terminal button while the panel is up re-opens it (resign-key autohide, then toggle); only View > Quick Terminal closes it. Predates B-113
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-113)

## B-200 · Single-instance test hardening (kqueue copy test, LeoTestChild reaping)   [ready]
Issue: #204
Why: B-118 review: waitForExitStillWaitsOnACopyOfThisBundle's asked == pid needs registration within 1 s of spawning /bin/sleep 1 — use sleep 60 + kill from the isCopy stub (QuittingHolderTests.swift:309); LeoTestChild.isRunning marks reaped on waitpid -1/EINTR, which can leak a sleep 60 child — set reaped only on result==pid or ECHILD (TestSupport.swift:174); dedupe the test realPath with LeoSingleInstance's (QuittingHolderTests.swift:491)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-118)

## B-201 · Single-instance Info.plist open hardening   [ready]
Issue: #205
Why: B-118 review: add O_NOCTTY (and optionally O_NOFOLLOW) to the Info.plist open (LeoSingleInstance.swift:285); URL(fileURLWithPath:isDirectory: false) in isMainExecutable to skip a stat (:270)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-118)

## B-202 · Single-instance: close the same-bundle pid-reuse case   [ready]
Issue: #206
Why: B-118 security review: a marked pid reused by another live Leo of this bundle is still waited on; compare pbi_start_tvsec with a timestamp written with the mark
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-118)

## B-203 · Release-retry log: comment wording and total wait   [ready]
Issue: #207
Why: B-119 review: LeoSingleInstance.swift:466-467 "only this line tells the two apart in the field" overstates — say it names the pid so the two can be told apart; optionally include the total wait (N × releasePauseMicroseconds) in the log line
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-119)

## B-204 · LeoTerminalRowsIntegrationTests focus flakes   [ready]
Issue: #208
Why: Recurring under load this run: closingARowsPaneHandsTheRowToTheNextFocusedPane (:748 focusMatchesSelection, B-119 verify), closingAHiddenRowGivesNothingOnScreenItsSlot (B-112 verify), 4 failures in B-118's implementer runs; each passed on rerun. Find the shared timing assumption and make them deterministic
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-119)

## B-205 · Rewrap LeoSingleInstance doc comment line 453   [ready]
Issue: #209
Why: B-120 review: the line is 82 chars where the rest of the block is 76 or fewer; cosmetic
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-120)

## B-206 · LeoTestProcessTests errno capture and gone() doc wording   [ready]
Issue: #210
Why: B-121 review: capture kill() result and errno into locals before #expect at LeoTestProcessTests.swift:29 so the macro can't clobber errno; gone() doc comment (LeoSingleInstanceTestSupport.swift:162) should say "checked at hand-out" (a check-to-use window remains)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-121)

## B-207 · LeoFirstAttachWindowSizeTests tidy-up   [ready]
Issue: #211
Why: B-122 review: use configuredContentSize(of:) in the two existing B-097 tests (LeoFirstAttachWindowSizeTests.swift:176-178, :217-219); note in the suite doc that the contentIntrinsicSize tests assume the host config doesn't set window-maximize; add a disabled-state check after a real Reset Window Size (apply())
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-122)

## B-208 · UpdateDelegateTests StubUpdater downloads can be let   [ready]
Issue: #212
Why: B-123 review: the setter is never used; make it a let with a getter-only override (style)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-123)

## B-209 · closingTheShownRowsPaneHandsTheRowToTheNextFocusedPane flakes   [ready]
Issue: #213
Why: B-123 implementer saw it fail once in a mutation run; passed elsewhere. Same family as the LeoTerminalRowsIntegrationTests focus flakes item
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-123)

## B-210 · testSelectionFocusChange uses a bare XCUIApplication()   [ready]
Issue: #214
Why: B-125 review: it misses -ApplePersistenceIgnoreState and the isolated config/defaults of ghosttyApplication(), and since it now calls launch() it can restore the debug bundle's saved windows (predates B-125); also document that launch() terminates any running debug Leo before relaunching
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-125)

## B-211 · AppDelegate update-order comment overstates the test   [ready]
Issue: #215
Why: B-126 review: AppDelegate.swift:324-326 says the order "is pinned by UpdateLaunchSequenceTests", but the test pins only the order inside the helper; reword to "The order inside UpdateLaunchSequence is pinned by UpdateLaunchSequenceTests; keep these steps routed through it."
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-126)

## B-212 · Appcast refresh note: command for the highest sparkle:version   [ready]
Issue: #216
Why: B-127 verify: the doc says to set newestVersion to the highest <sparkle:version> but gives no grep one-liner to find it
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-127)

## B-213 · Check for Updates… while the permission question is pending: polish   [ready]
Issue: #217
Why: B-128 verify/review: with every terminal window minimized it opens a new window instead of restoring one; it opens the window but not the popover, so a second click on the pill is needed; docs/leo/ci.md's B-128 bullet should mention it opens a window
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-128)

## B-214 · Permission popover says Ghostty, not Leo   [ready]
Issue: #218
Why: B-128 verify: the popover body says "Ghostty can automatically check…"; branding copy
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-128)

## B-215 · Release-side guard for SUAllowsAutomaticUpdates   [ready]
Issue: #219
Why: B-129 review: the new UpdatePolicyTests check returns early outside Debug, so nothing asserts SUAllowsAutomaticUpdates stays absent in Release (a leak would silently disable auto-install for shipping users); add the else branch expecting nil (UpdatePolicyTests.swift:109-115)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-129)

## B-216 · Debug update-found alert shows a live-looking Install Update button   [ready]
Issue: #220
Why: B-129 verify: Sparkle's Debug update alert still shows Install Update (gated to dismiss by B-115); relabel or disable it in Debug
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-129)

## B-217 · About tests: real About-window check and shared menu walker   [ready]
Issue: #221
Why: B-130 review: theAboutWindowNamesLeo only checks AboutView.appName == "Leo" (would pass if the view went back to Text("Ghostty")) — scan or host the view; LeoAboutMenuTests duplicates LeoNoTabBarTests' menuItems walker — share it
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-130)

## B-218 · Leo branding sweep: remaining Ghostty strings   [ready]
Issue: #222
Why: B-130 review: MainMenu.xib Hide Ghostty / Quit Ghostty / Make Ghostty the Default Terminal / Ghostty Help; About window links (ghostty.org, ghostty-org/ghostty, commit link to the wrong repo), tagline and "Ghostty Application Icon" a11y label; AppDelegate.swift:1478/1514 "Quit Ghostty?", :625 "Allow Ghostty to execute…", UntrustedURLAlert.swift:39, UpdatePopoverView.swift:62, TerminalCommandPalette.swift:99 "Update Ghostty and Restart", ErrorView.swift:13, TerminalView.swift:267 debug banner, default "👻 Ghostty" titles in TitlebarTabs{Tahoe,Ventura}TerminalWindow. Decide which upstream strings to rename (keep upstream merges cheap)
Accept: fixed or explicitly dismissed with a reason; suite green
Source: autopilot polish (B-130)

## B-223 · Bundled ghostty CLI test: isolate cwd and profile output   [ready]
Issue: #227
Why: B-220 review: LeoBundledGhosttyCLITests runs its child with LLVM_PROFILE_FILE stripped and an inherited cwd, so a coverage build can drop default.profraw into Contents/MacOS and break the bundle seal — set currentDirectoryURL to a temp dir and/or LLVM_PROFILE_FILE=/dev/null
Accept: B-220 review: LeoBundledGhosttyCLITests runs its child with LLVM_PROFILE_FILE stripped and an inherited cwd, so a coverage build can drop default.profraw into Contents/MacOS and break the bundle seal — set currentDirectoryURL to a temp dir and/or LLVM_PROFILE_FILE=/dev/null
Source: autopilot polish (B-220)

## B-224 · Bundled ghostty CLI test: deadline on the child process   [ready]
Issue: #228
Why: B-220 review: readDataToEndOfFile/waitUntilExit have no deadline, so a hung child hangs the run instead of failing — add a terminate deadline like LeoProcessRunnerTests.timeoutTerminatesProcess
Accept: B-220 review: readDataToEndOfFile/waitUntilExit have no deadline, so a hung child hangs the run instead of failing — add a terminate deadline like LeoProcessRunnerTests.timeoutTerminatesProcess
Source: autopilot polish (B-220)

## B-225 · Check release signing with the Contents/MacOS/ghostty symlink   [ready]
Issue: #229
Why: B-220 verify: release signing and notarization with a symlink in Contents/MacOS are untested (ad-hoc codesign --deep --strict passes); watch the next CI release build or add a CI codesign --verify --strict check
Accept: B-220 verify: release signing and notarization with a symlink in Contents/MacOS are untested (ad-hoc codesign --deep --strict passes); watch the next CI release build or add a CI codesign --verify --strict check
Source: autopilot polish (B-220)

## B-226 · CI script-tests guard: tighten the step match   [ready]
Issue: #230
Why: B-221 review: the guard is satisfied by `run-tests.sh --list` or a DIR argument and ignores job-level continue-on-error — require nothing after run-tests.sh on the matched line and reject job-level continue-on-error (test_ci-runs-script-tests.sh:96)
Accept: B-221 review: the guard is satisfied by `run-tests.sh --list` or a DIR argument and ignores job-level continue-on-error — require nothing after run-tests.sh on the matched line and reject job-level continue-on-error (test_ci-runs-script-tests.sh:96)
Source: autopilot polish (B-221)

## B-227 · Release path runs the CI script tests   [ready]
Issue: #231
Why: B-221 review: leo-release.yml calls only leo-build, so a tag on a commit that skipped main (or while main's leo-ci was red) can release without the script tests — have leo-release call leo-ci (workflow_call) or have leo-build run run-tests.sh first
Accept: B-221 review: leo-release.yml calls only leo-build, so a tag on a commit that skipped main (or while main's leo-ci was red) can release without the script tests — have leo-release call leo-ci (workflow_call) or have leo-build run run-tests.sh first
Source: autopilot polish (B-221)

## B-228 · run-tests.sh pins /bin/bash   [ready]
Issue: #232
Why: B-221 review: run-tests.sh:43 runs `bash "$t"` from PATH, so Homebrew bash 5 could hide bash 3.2 incompatibilities — pin it to /bin/bash
Accept: B-221 review: run-tests.sh:43 runs `bash "$t"` from PATH, so Homebrew bash 5 could hide bash 3.2 incompatibilities — pin it to /bin/bash
Source: autopilot polish (B-221)

## B-229 · sparkle-key-check: missing-key detection without PlistBuddy wording   [ready]
Issue: #233
Why: B-222 review: sparkle-key-check.sh's missing-key detection matches PlistBuddy's English `":SUPublicEDKey", Does Not Exist` text; if macOS changes it the script falls back to the generic "could not read" error (accurate but less specific) — consider `plutil -extract` or an exit-code-based check
Accept: B-222 review: sparkle-key-check.sh's missing-key detection matches PlistBuddy's English `":SUPublicEDKey", Does Not Exist` text; if macOS changes it the script falls back to the generic "could not read" error (accurate but less specific) — consider `plutil -extract` or an exit-code-based check
Source: autopilot polish (B-222)

## B-230 · Focus tests: tear down the palette presentation on failure   [ready]
Issue: #234
Why: B-131 review: in LeoContentFocusTests presentPaletteForRequest (and the older presentPalette), a failure between present and Escape never invalidates the presentation, so the panel stays a key child window until fixture.close(); a defer'd close/invalidate stops one failure leaking into the next test
Accept: B-131 review: in LeoContentFocusTests presentPaletteForRequest (and the older presentPalette), a failure between present and Escape never invalidates the presentation, so the panel stays a key child window until fixture.close(); a defer'd close/invalidate stops one failure leaking into the next test
Source: autopilot polish (B-131)

## B-231 · Focus tests: rename the shadowing sidebar local   [ready]
Issue: #235
Why: B-131 review: `let sidebar = LeoSidebarModel()` in presentPaletteForRequest (~line 148) shadows the fixture's `sidebar: NSView`; rename it to sidebarModel
Accept: B-131 review: `let sidebar = LeoSidebarModel()` in presentPaletteForRequest (~line 148) shadows the fixture's `sidebar: NSView`; rename it to sidebarModel
Source: autopilot polish (B-131)

## B-236 · Upload error filenames in right-to-left text   [ready]
Issue: #241
Why: B-232 final review: isolate RTL filenames in the upload error message.
Accept: Once B-232 is landed, improve this upload-error presentation with verification.
Requires: B-232 done (do not build before the feature lands).
Source: autopilot polish (B-232)

## B-237 · Terminal upload errors truncate after four lines   [ready]
Issue: #242
Why: B-232 final review: terminal failure overlay truncates longer error batches.
Accept: Once B-232 is landed, improve this upload-error presentation with verification.
Requires: B-232 done (do not build before the feature lands).
Source: autopilot polish (B-232)

## B-238 · Verify close-confirmation hints in isolated GUI   [done]
Issue: #243
Done: no code change — existing B-133 source, independent serial suite 2,072/223 + SwiftLint; actual Right/Left dialog window screenshots B-238-3.png/B-238-4.png, freshly inspected by verifier and root. Earlier parent-window B-238-1/2 captures invalidated.
Why: B-133 verifier found two debug instances and could not safely uniquely target the changed confirmation flow.
Accept: When safe unique debug targeting is available, capture the actual duplicate-name left/right confirmation alert; never drive production or unrelated debug sessions.
Source: autopilot polish (B-133)

## B-239 · Verify adaptive start-screen buttons in isolated GUI   [done]
Issue: #244
Done: no code change — B-138 implementation already satisfied; fresh independent exact-lane suite 2,072/223 + SwiftLint; readable horizontal actions at 800pt and vertical fallback at 420pt, screenshots B-239-1.png/B-239-2.png.
Why: B-138 exact-lane tests passed, but the isolated Debug app bundle could not launch (missing executable); narrow/wide layout lacks visual verification.
Accept: Restore a safe isolated debug build and capture readable horizontal buttons at wide width and vertical fallback below 450 pt; preserve all actions/tooltips; never drive production or real agents.
Source: autopilot polish (B-138)

## B-240 · Vacuous-pass guard on the regrow check   [ready]
Issue: #245
Why: in LeoSidebarContentMinimumTests.swift (~:99-101) `regrowShown.isEmpty` can pass vacuously; add the `!widening.isEmpty` guard the narrowing check already has
Accept: the widening/regrow per-step check fails when no widening steps were captured
Source: autopilot polish (B-139)

## B-241 · Absolute per-step content-width floor in the live resize test   [ready]
Issue: #246
Why: the per-step expected width derives from `sidebarMaximumWidth`, the same function production uses, so both could share an error; add an absolute floor `contentWidth >= contentMinimumWidth - 1` when the window is ≥ 651 pt (LeoSidebarContentMinimumTests.swift ~:123-128)
Accept: each captured step asserts content width against the absolute 450 pt minimum (1 pt tolerance), independent of sidebarMaximumWidth
Source: autopilot polish (B-139)

## B-242 · `resize` doc comment wording in LeoSidebarContentMinimumTests   [ready]
Issue: #247
Why: the comment (~:183-185) overstates the capture as what "the display cycle runs before it draws" (it is the earliest layout pass) and uses `--` instead of the file's em dash
Accept: the comment describes the earliest layout pass accurately and uses an em dash
Source: autopilot polish (B-139)

## B-243 · One terminal-room formula for the sidebar restore cap   [ready]
Issue: #248
Why: restoreSidebarWidth's floor cap uses the terminal frame width while sidebarSqueezesTerminal/makeRoom use LeoSidebarSplitMetrics.terminalWidth; they agree after layout, but D-058 now has two formulas
Accept: the restore cap and sidebarSqueezesTerminal/makeRoom share one terminal-room computation; behaviour unchanged, tests still green
Source: autopilot polish (B-140)

## B-244 · Reset with a narrow default and a side pane shouldn't look like it hides the sidebar   [ready]
Issue: #249
Why: when the default size is narrow and a side pane is open, Reset Window Size triggers the transient floor-collapse (D-059), which reads as the command hiding the sidebar
Accept: Reset Window Size with a narrow default and a side pane open leaves the sidebar visible (or the collapse is clearly the floor rule, not the command); covered by a test
Source: autopilot polish (B-140)

## B-245 · Reset Window Size fills the screen with a wide default   [ready]
Issue: #250
Why: a 160-col default plus the 420 pt sidebar caps at the 1680 pt screen width, which looks less like a "default" size
Accept: decide and implement how Reset sizes a window whose default plus sidebar exceeds the screen (e.g. leave a margin); covered by a test
Source: autopilot polish (B-140)

## B-246 · Non-vacuous final check in aWindowNotYetPresentedReadsNotShownWhileTheAppIsHidden   [ready]
Issue: #251
Why: its last `#expect(requested.isLeoWindowShown)` passes whatever the hidden state is, because the settled window is on screen
Accept: the final check orders the window out first (so only the hidden-state branch can make it pass), or is documented as a sanity check
Source: autopilot polish (B-141)

## B-247 · Size-guard late LeoAgentPalettePanels in the stray-window test   [ready]
Issue: #252
Why: LeoFolderOpenStrayWindowTests exempts a late LeoAgentPalettePanel by type alone
Accept: late palettes are also checked against 500x500, and a doc line says unregistered late palettes go unchecked
Source: autopilot polish (B-142)

## B-248 · Split the long line in LeoFolderOpenStrayWindowTests   [ready]
Issue: #253
Why: LeoFolderOpenStrayWindowTests.swift:224 is ~130 chars
Accept: the line is split to the file's usual width; swiftlint clean
Source: autopilot polish (B-142)

## B-249 · Build LeoAgentPalettePanel lazily   [ready]
Issue: #254
Why: the palette panel is built up front (defer:false), so every window carries a hidden 640x140 window-server window at the origin
Accept: the palette panel's window-server window is created only when the palette first opens; palette behaviour and tests unchanged
Source: autopilot polish (B-142)

## B-250 · verify.md note: the 500x500 window at (0,550) is macOS's TUINSWindow   [ready]
Issue: #255
Why: an untitled off-screen 500x500 window at (0,550) is the system caps-lock/input-source indicator (TextInputUIMacHelper), not Leo's; verifiers keep rediscovering it
Accept: verify.md has a one-line note so window listings ignore it
Source: autopilot polish (B-142)

## B-251 · Per-agent turn preview + usage (leo PR #226)   [idea]
Source: Evan (/idea, 2026-10-07)
Note: Show per-agent turn preview + usage (tokens/cost/context %) from Leo /api/v1 agent_turn_completed + Agent.usage (leo PR #226, spec leo docs/specs/2026-10-06-bridge-observe.md; gate on SSE hello features)
Inbox: 20261007T131748905880Z-2eef5846#1

## B-252 · Show attention.reason (permission/question/elicitation + tool detail) in badges and notifications (leo PR #226)   [idea]
Source: Evan (/idea, 2026-10-07)
Inbox: 20261007T131749012401Z-0896fd7f#1

## B-253 · Use attention.outstanding + dispatch tree (leo PR #226)   [idea]
Source: Evan (/idea, 2026-10-07)
Note: Use attention.outstanding + Snapshot.dispatches[] (parent_dispatch_id tree) from leo PR #226 — daemon contract that unblocks B-051 (agent stays working while children run); show dispatch tree
Inbox: 20261007T131749105290Z-fd83296d#1

## B-254 · Live current tool display from current_action kind "tool" (leo PR #226)   [idea]
Source: Evan (/idea, 2026-10-07)
Inbox: 20261007T131749201355Z-00f58ead#1

## B-255 · Compaction indicator from agent_compaction events + context % (leo PR #226)   [idea]
Source: Evan (/idea, 2026-10-07)
Inbox: 20261007T131749300167Z-ace5895b#1

## B-256 · Send-prompt box + interrupt/compact/clear buttons (leo PR #226)   [idea]
Source: Evan (/idea, 2026-10-07)
Note: Send-prompt box + interrupt/compact/clear buttons via operator-only POST /api/v1/agents/{name}/{message,interrupt,compact,clear} (leo PR #226), no tmux typing
Inbox: 20261007T131749391262Z-60e7c4eb#1

## B-263 · Index dispatch children once per tree projection   [idea]
Note: Tree projection is O(n^2) per agent; use a parent→children index built once per projection
Source: autopilot polish (B-257)

## B-264 · Dispatch tombstone cap survives heavy churn   [idea]
Note: the 256 ended-id cap can be evicted by heavy churn, so a stale baseline could briefly bring back an ended id
Source: autopilot polish (B-257)

## B-265 · Tighten fetchCount bound in dispatchAndSeqOnlyEventsLeaveThePendingActivityWindowAlone   [idea]
Note: assert == +1 so a lost metadata refresh is caught
Source: autopilot polish (B-257)

## B-266 · Clicking a dispatch row reveals or jumps to the dispatch   [idea]
Note: clicking a dispatch row currently does nothing
Source: autopilot polish (B-257)

## B-267 · Clearer depth indent for dispatch rows   [idea]
Note: the depth indent and ↳ glyph are low-contrast and subtle; a larger step or guide line would read better
Source: autopilot polish (B-257)

## B-268 · Same-state needs_input with a newer revision re-notifies   [ready (next run)]
Type: bug
Report: Same-state needs_input with a newer revision re-notifies — leo 01be9b40 bumps the attention revision when outstanding subagent/dispatch counts change, so one prompt can notify again and bring back an acknowledged Dock count (acknowledged[agent] keeps the old revision, so a hook→bridge reason refinement can also restore it); violates principle 2 (calm)
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: autopilot bug (B-258)
