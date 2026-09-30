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

## B-085 · Window doesn't always appear on launch   [ready]
Issue: #89
Type: bug
Report: on launch the window doesnt always appear
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-09-29)
Inbox: 20260929T222806706604Z-d192c093#1

## B-086 · Window shrinks to a tiny size on first agent attach after launch   [ready]
Issue: #90
Type: bug
Report: when attaching to the first agent after launching, the app window shrinks to a tiny size
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: Evan (/issue, 2026-09-29)
Inbox: 20260929T222831661985Z-ec1de91b#1

## B-071 · Bug — ⌘Z of a split close after a row switch can silently kill a busy hidden row's shell   [done]
Issue: #75
Why: B-057 concurrency review (MEDIUM, dismissed as pre-existing): ⌘D, ⌘W the split, switch rows, ⌘Z within 5 s replays the old tree, bypassing retire/kept. Suggested fix: undoManager.removeAllActions(withTarget:) in leoReplaceContent/leoShowStartScreen. Also: a keyboard-selected but not shown hidden row that exits leaves the selection nil (LOW)
Accept: a failing test reproduces the undo-replay kill; it passes after the fix; selection falls back to what's shown; nothing else regresses
Source: autopilot polish (B-057)
Done: 3c11d58f5 554d32298 73ccd5035 c32e920d8 1c7b13222 c9ce67411 bc8aae9f1 (1737 tests). After a content swap or the start screen ⌘Z no longer replays the old tree; a selected row that closes hands the selection to what's shown. Decisions D-140..D-143.

## B-072 · Test infra: runtests.sh crashes the test host (libghostty env pointer vs setenv)   [ready]
Issue: #76
Why: canonical scratchpad/runtests.sh crashes at LeoLivePoolIntegrationTests/switchingBackShowsTheSameSurfaceInstance (libghostty holds a pointer into environ; later FAKE_SSH_* setenv invalidates it), also on baseline; B-057 used a wrapper presetting LANG, __CF_USER_TEXT_ENCODING, __LLVM_PROFILE_RT_INIT_ONCE. Also lengthen aNewShellIsASelectedRowTitledByItsTerminal's eventually timeout (flaky under load)
Accept: the canonical suite runs green without the wrapper (fix the setenv use or copy env for libghostty); flaky timeout lengthened; verify.md updated
Note: B-068 moved aNewShellIsASelectedRowTitledByItsTerminal to a /bin/cat stand-in (the flake's cause was a login shell's prompt retitle), so the timeout part may already be moot.
Source: autopilot polish (B-057)

## B-073 · runtests.sh test-host timeout too short under load   [ready]
Issue: #77
Why: the 400 s test-host timeout cut off a full run at this host's load (300–950) during B-063 verify
Accept: timeout configurable/raised so a loaded run completes; flake-free rerun
Source: autopilot polish (B-063)

## B-074 · Sidebar under the traffic lights with macos-titlebar-style=hidden   [ready]
Issue: #78
Why: pre-existing: .ignoresSafeArea(.top) (TerminalView.swift:205) puts the whole sidebar under the traffic lights in the hidden titlebar style (seen in B-064)
Accept: with titlebar-style hidden the sidebar header clears the traffic lights; layout test in the real split-view hierarchy; screenshot
Source: autopilot polish (B-064)

## B-075 · Search field grabs keyboard focus on launch   [ready]
Issue: #79
Why: the sidebar search field shows a focus ring on launch (seen in B-064 verify); a first-party sidebar doesn't take focus from content
Accept: on launch focus goes to the content area, not the search field; test
Source: autopilot polish (B-064)

## B-076 · Tighten LeoNoTabBarTests' xib ⌘T guard   [ready]
Issue: #80
Why: the guard at LeoNoTabBarTests:92-93 can only pass: New Terminal takes ⌘T from the Ghostty config, and an empty `<modifierMask/>` slips past the filter
Accept: the guard fails if any xib item other than New Terminal binds ⌘T (including an empty modifierMask), or its message is reworded to say what it really checks; suite green
Source: autopilot polish (B-066)

## B-077 · verify.md: palette is Choose Agent… (⌘O), not File ▸ New Tab   [ready]
Issue: #81
Why: verify.md still says "the agent palette opens with File ▸ New Tab"; that menu item is now New Terminal (⌘T), and the palette is Choose Agent… (⌘O)
Accept: verify.md's palette instructions name Choose Agent… (⌘O); the B-057 GUI tip is corrected (AX set-value on the search field changes its text but not the filter; use Agents ▸ Find Agent… plus peekaboo type / press delete, per B-067 verify)
Source: autopilot polish (B-066)

## B-078 · Tests for B-067's calm-scroll claims   [ready]
Issue: #82
Why: "a retitle doesn't move the scroll offset" and "re-selecting a row already on screen doesn't scroll" hold only by construction; nothing catches a regression
Accept: tests assert both; reword the misleading doc comment on aNewRowBelowAListedOneIsRevealedWhole's "same turn" case (it passed before the fix)
Source: autopilot polish (B-067)

## B-079 · Terminals row label polish (tooltip, trimmed title, test comments)   [ready]
Issue: #83
Why: B-068 review polish: hovering the "(2)" suffix shows no tooltip (`.help` sits on the title Text only, LeoTerminalRowView.swift:27); labels group by the trimmed title but show the untrimmed one, so " ~ " shows a stray space (LeoTerminalRowLabel.swift:31,36); the "(B-068)" comments at LeoTerminalRowsIntegrationTests.swift:126,267 wrongly imply B-068 caused the prompt-retitle race
Accept: the tooltip covers the whole row label; displayTitle is trimmed; the comments cite the shell-integration prompt retitle; tests for the first two
Source: autopilot polish (B-068)

## B-080 · Start-screen shortcut hints follow the live keybinds   [ready]
Issue: #84
Why: B-069's New Terminal tooltip hardcodes "⌘T", but AppDelegate syncs ⌘T from the user's Ghostty new_tab keybind, so a rebind makes the hint wrong; the menu-item tests look items up by key "t" and would fail on a rebind instead of catching drift
Accept: the start-screen hints are built from the synced menu items (or config.keyboardShortcut(for:)); tests look items up by selector (TerminalController.newTab(_:)); a rebind test shows the hint following
Source: autopilot polish (B-069)

## B-081 · Sidebar scroll and start title after the last shell closes   [ready]
Issue: #85
Why: B-070 verify: after the last shell closes, the sidebar stays scrolled to the bottom where the Terminals section was; leoStartTitle is captured once at windowDidLoad (a config `title` reload doesn't reach an open window's start screen; matches upstream) and has no explicit test with a config `title` set
Accept: after the last Terminals row closes the sidebar keeps a sensible scroll position (the selection or the top), calmly; a comment documents leoStartTitle's capture; a test with a config `title` set
Source: autopilot polish (B-070)

## B-082 · Bug — closing a row's original pane beside a split orphans the other pane   [ready]
Issue: #86
Why: B-071 verify (shot B-071-9): File ▸ Close on the row's original pane while a split is open drops the row but leaves the other pane on screen with no row, and the next New Terminal kills that orphaned shell without asking (breaks principles 2 and 6). Pre-existing; related to D-117 and B-058
Accept: a failing test reproduces it; after the fix the remaining pane stays reachable from a row (or asks before it is replaced); nothing else regresses
Source: autopilot polish (B-071)

## B-083 · B-071 test and undo-manager polish   [ready]
Issue: #87
Why: B-071 review polish: EditorCloseTests:91-93 doc says "S exits" but the test closes S; LeoContentSwapIntegrationTests.swift:126 calls undo() on the shared manager without leoRemoveActionsTestsCanReplay; RowsIntegrationTests:639 should also assert busyView.view?.processExited == false; ExpiringUndoManager.removeAllActions() crashes from re-entrant deinit (latent upstream bug, no production caller: snapshot the set before clearing). Also: Move Split cross-window undo leaves the other window's half after a swap (concurrency review, narrowed by B-071)
Accept: each fixed or explicitly dismissed; suite green
Source: autopilot polish (B-071)

## B-087 · Cursor looks unfocused after a row switch or palette Escape   [ready (next run)]
Why: B-071 verify saw a hollow (unfocused) cursor right after a row switch and after Escape closes the palette; pre-existing
Accept: after a row switch or dismissing the palette, the shown terminal is first responder and its cursor is focused; test
Source: autopilot polish (B-071)

## B-088 · "Close Terminal?" confirm names the pane it closes   [ready (next run)]
Why: B-071 verify: the close confirm doesn't say which pane/row it will close, which is ambiguous beside a split
Accept: the confirm names the row/pane being closed; test
Source: autopilot polish (B-071)

## B-089 · Sidebar width persistence hardening   [ready (next run)]
Why: B-084 review: lastPersistedWidth records the requested width, not the applied one (narrow-then-widen launch could persist a clamped width); the pending branch's programmatic-width flag relies on pendingWidth always clearing via applyProgrammaticWidth; "leo.sidebarWidth" literal repeated 3x
Accept: lastPersistedWidth comes from the sidebar's actual frame after setPosition, with a harness case for narrow-then-widen; the flag is documented or dropped; one key constant; suite green
Source: autopilot polish (B-084)

## B-090 · Bug — a sidebar hidden at launch un-collapses, then re-collapses with animation   [ready (next run)]
Type: bug
Report: B-084 review/implementer: a sidebar that starts hidden is un-collapsed by the pending setPosition at first layout, then re-collapsed with an animation (pre-existing). Breaks P2 calm and "hidden with ⌘⇧L stays hidden"
Accept: A failing test reproduces the report; it passes after the fix; nothing else regresses.
Source: autopilot polish (B-084)

## B-091 · Wide sidebar truncates the content toolbar   [ready (next run)]
Why: B-084 verify: at a 420 pt sidebar in an 800 pt window, "Show Terminal Drawer" truncates
Accept: a content minimum width (or a sidebar maximum tied to window width) keeps content controls untruncated; test + screenshot
Source: autopilot polish (B-084)

## B-054 · Bug — template lists are empty in New Agent and row Set Template   [done]
Issue: #59
Why: with a remote host selected, creating an agent or changing its template shows no templates (principle 3, local = remote; principle 4, everything through Leo)
Accept: with a remote host selected, the New Agent sheet's Template picker lists the remote daemon's templates, not the local CLI's (test with a fake remote fetch); a row's right-click Set Template submenu lists the host's templates on the first open, confirmed by a debug-build screenshot; after a host switch both lists show the new host's templates, never the old host's (test)
Out: no changes to the Agents menu bar ▸ Set Template path (already works); no template editing or creation UI
Note: diagnosis 2026-09-28: (1) SpawnAgentModel.loadTemplates() always calls the local cli.templateList(), ignoring the selected host (the laptop's own leo returns []); LeoAgentActions.templates() already handles remote hosts through LeoTemplateCache plus an ssh exec, verified working from the laptop. (2) LeoAgentRow's Set Template Menu inside .contextMenu fills from row @State through a .task, which likely never runs in the NSMenu-snapshotted context menu (unconfirmed; reproduce first). Suggested fix: one published, host-aware template list on LeoAgentActions, prefetched on host change, read by both.
Source: Evan (/feature, 2026-09-28)
Inbox: 20260929T012753703255Z-9360b771#1
Done: 3a2205a65 (1573 tests, lint clean, review clean). Root causes: SpawnAgentModel used the local CLI regardless of host; the row fetched templates itself after the context menu was built. Verified by screenshot: row Set Template submenu filled on first open (B-054-3), New Agent sheet (B-054-4). The sheet's Template popup and the remote-host path were not visually verified (no AX on the sheet; no autopilot remote host); covered by LeoTemplateListTests with a fake remote.

## B-061 · Tests: inject the template fetch so LeoRuntime tests don't run real ssh   [ready]
Issue: #65
Why: since B-054, selecting the remote host "work" in LeoRuntimeConnectionTests also starts a real `/usr/bin/ssh -o BatchMode=yes evan@work … template list` (tests already open real tunnels there). Hang/isolation risk.
Accept: LeoRuntime takes an injectable template-fetch runner; tests pass a fake; no test spawns ssh for templates (assert via the fake).
Out: the existing tunnel tests' real ssh use.
Source: B-054 implementer + review

## B-055 · One content area per window; sidebar selects what's shown   [done]
Issue: #60
Why: principle 6 (the sidebar is the navigation) and principle 1 (Mac-native: Mail/Finder switch content from the sidebar, no tabs)
Accept: no tab bar appears in any window, including after ⌘N or a restored session; clicking a row, Return, or palette choice shows that agent in the window's content area, replacing what was shown; the sidebar (width, collapse, scroll, search) never changes or redraws on a switch (before/after screenshot pair); one agent is on screen in at most one window, and selecting it elsewhere focuses that window (as B-047); tab-only affordances (Attach in New Tab, ⌘-click/⌘↩ new tab, start-tab fill) are removed or remapped, each logged; tests plus screenshots with autopilot-scratch only
Out: the live pool (B-056), plain-shell rows (B-057), splits (B-058); multi-window layouts beyond ⌘N
Source: Evan (/vision revision, 2026-09-28)
Done: 4134ce4f4 6fb5c8c8d (1593 tests, lint clean; general + lifecycle reviews: no blockers). Verified by screenshots: B-055-1 → -2 (start screen → autopilot-scratch in the content area; no tab bar; sidebar geometry unchanged; window titled with the agent; one tmux client), -3 (⌘N window, no tab bar, on-screen row highlighted), -4 (clicking scratch from the new window focused the existing one and closed the untouched start window; still one client).

## B-062 · Rename tab-era internals (AttachTabHost, tabCount, LeoTabTitleSource)   [ready]
Issue: #66
Why: after B-055 there are no tabs; internal names still say "tab" (kept to shrink B-055's diff).
Accept: mechanical rename to content/window vocabulary; unify the two "is this an agent" predicates (attachment.isAttach vs leoAgentName, B-056 review) into one source; prune contentVersion on window close; fix LeoLivePoolIntegrationTests' `hiddenSurfaces(in: fixture.origin)` assertions, which check a test-local session id and so pass vacuously; no behaviour change; suite green.
Out: behaviour changes.
Source: B-055 implementer

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

## B-065 · Sidebar convenience button bar (Quick Terminal, New Terminal)   [ready]
Issue: #70
Why: One-click access to common window actions from the sidebar, which is the navigation (principle 6), without making a shortcut the only way in; every button also keeps its menu item and shortcut (principle 1).
Accept: a compact bar of SF Symbol icon buttons sits in the sidebar (header or footer, agent's call per HIG) and matches the corrected top-spacing layout; the Quick Terminal button toggles Ghostty's quick terminal (same action as the menu item/shortcut), verified by screenshot of it opening and closing; the New Terminal button creates and selects a plain-shell row exactly as ⌘T does (after B-057); each button has a tooltip naming its shortcut and an accessibility label; tests plus screenshots from the isolated debug build
Out: any other buttons (settings, new agent, search, etc.) — add later as separate items; user-customizable button sets; restyling the rest of the sidebar
Source: Evan (/feature, 2026-09-29)
Inbox: 20260929T161921499761Z-63fc4dc4#1

## B-057 · Plain shells as "Terminals" sidebar rows   [done]
Issue: #62
Why: principle 6 (everything on screen comes from a sidebar row) and principle 1 (every action has a shortcut and a menu item)
Accept: a "Terminals" section lists open plain shells, titled by the terminal title; ⌘T (and File ▸ New Terminal) creates a shell and selects it; closing a shell (⌘W, or exit) removes its row and selects a neighbour; shells take part in the live pool like agents; the section hides when empty; tests plus a screenshot
Out: naming or pinning shells; shells on remote hosts beyond what Ghostty already does
Source: Evan (/vision revision, 2026-09-28)

Done: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c(1700 tests via env-preset runner, lint clean; general + concurrency reviews; implementer-hard, 3 fix rounds). Fixed both prior HIGHs (exit racing a reveal; busy hidden shells now confirm on tab-close/⌘Q). Verified by screenshots B-057-9 (Terminals section, two rows, newest selected), -10 (Close selects neighbour), -11 (section hides when empty). exit, OSC title and pool behaviour: tests only. Follow-ups B-067..B-072.
## B-058 · Splits inside the content area   [ready]
Issue: #63
Why: principle 6 (the layout belongs to the selected row) with splits kept (D-100)
Accept: ⌘D and the editor/file pane still split the content area; a split can show a second agent or shell, picked from the sidebar or palette; every row on screen is highlighted in the sidebar, the focused one distinctly; switching away from a split layout and back restores it intact; tests plus a screenshot of an agent + shell split with both rows highlighted
Out: saved layouts; dragging rows into splits (later polish)
Source: Evan (/vision revision, 2026-09-28)
Note: B-071 verify saw ⌘D / Split Right open the agent palette instead of splitting directly; settle this here.

## B-059 · Keyboard switching between rows   [ready]
Issue: #64
Why: principle 1 (keyboard-first; every action has a shortcut and a menu item)
Accept: the old tab shortcuts are remapped to rows (⌘1–⌘9 select the Nth visible row, ⌃Tab/⌃⇧Tab or ⌘⇧]/[ go to the next/previous row, ⌃⌥⌘J still jumps to the next agent that needs you); each has a Window-menu item; the shortcuts skip collapsed sections; tests cover each shortcut
Out: user-configurable bindings beyond Ghostty's keybind config
Source: Evan (/vision revision, 2026-09-28)

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

## B-014 · All hosts at once as sidebar sections   [deferred]
Question: deferred by D-008 until several remotes are in daily use. Tell me
when that's true. — I'd pick keeping it deferred.
Answer: accept your recommendation (keeping it deferred)

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

## B-051 · Bug — working agents show "Finished" (suspected subagents)   [blocked]
Issue: #54
Why: The status badge has to be trustworthy or the attention model means nothing. Serves "Calm, attention-driven: never invent a state".
Accept: Reproduce on autopilot-scratch with a scripted turn that starts a background subagent, then record the SSE attention events and the row's state over time; name the root cause (app mapping vs daemon hook semantics) with that trace as evidence; if it's app-side, fix it test-first with a failing test that replays the trace; if it's daemon-side, write the contract change (e.g. keep `working` until SubagentStop / background tasks finish) as a spec and block on Evan.
Out: Adding app-side heuristics that override daemon state; Codex/opencode subagent detection.
Source: Evan (/feature, 2026-09-28)
Inbox: 20260928T193703549149Z-2d2188b3#1
Question: Needs Evan to do: send the daemon contract change to the leo agent, and time the leo release/restart. Reply "B-051: done" once it's done.
Answer:

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

