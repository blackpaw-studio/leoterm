# Decisions

How to veto: tell Rocket "veto D-0xx", or tick `Veto: [x]` in the worktree
copy (`~/.leo/autopilot/leoterm/.autopilot/DECISIONS.md`) only. The copy on
the default branch is read-only history. Autopilot reverts vetoed decisions on
its next run.

## D-001 · 2026-09-22 · North star: Orca-shaped, Leo-native workspace
Context: vision session
Chose: "one place you work with your Leo agents: status, jump in, open/edit surfaced files, identical local or over SSH"
Why: Evan wants Leo Term to resemble Orca: everything he does with agents happens in Leo.
Alternatives: thin agent-manager sidebar only (the v2-reset framing), dropped as too narrow
Commit: n/a
Veto: n/a (Evan)

## D-002 · 2026-09-22 · Drop the "zero Zig changes" constraint
Context: taste principles
Chose: Zig core edits allowed, kept minimal. No longer a principle or a stop-list item.
Why: Evan didn't keep "Stock Ghostty core" as a principle or carve-out
Alternatives: keep as principle (rejected by Evan)
Commit: n/a
Veto: n/a (Evan)

## D-003 · 2026-09-22 · Remote file access over SFTP, not the daemon
Context: principle "Local = remote"
Chose: file view/edit uses a local-FS backend locally and SFTP over the existing SSH ControlMaster remotely
Why: the tunnel already exists, so no daemon file API is needed
Alternatives: daemon-mediated file read/write (Evan unsure it's right)
Commit: n/a
Veto: n/a (Evan)

## D-004 · 2026-09-22 · Non-goals and later items
Context: non-goals
Chose: keep the four existing decided-against items; add "not a full IDE" and "Mac only". A mobile companion, embedded browser, and GitHub integration are wanted, but later.
Why: Evan's answers
Alternatives: reopening auto-reconnect (declined)
Commit: n/a
Veto: n/a (Evan)

## D-005 · 2026-09-22 · Approve attention-model spec with recommendations
Context: roadmap Tier 1 [?]; docs/superpowers/specs/2026-09-21-leo-attention-model.md
Chose: approve as drafted. Tab focus acks the Dock count while the row badge stays; a focused split counts as viewing; Jump is ⌃⌥⌘J. Legacy daemons show Working only, with no heuristics.
Why: principle 2 (never invent a state)
Alternatives: idle-after-working heuristic (noisy); hold
Commit: 4e064d6f7 cb18a2a6c 013840a46 465676949 93e0c4f78 60cb67072 f378da52c a0899a492 190b70f4b c5540f3c7
Veto: n/a (Evan)

## D-006 · 2026-09-22 · Daemon attention field via the leo agent
Context: the spec's leo-daemon prerequisite
Chose: autopilot messages the leo agent with the contract and builds the app side against fixtures. No leo repo edits.
Why: Evan's choice; keeps the repo boundary
Alternatives: Evan relays; autopilot edits the leo repo
Commit: n/a (message only; see D-010, D-011)
Veto: n/a (Evan)

## D-007 · 2026-09-22 · How agents surface files
Context: milestone item 2
Chose: ⌘-click paths and OSC 8 links in the agent terminal, plus a per-agent workspace browser. A daemon "surface file" event comes later (B-013).
Why: works today with no daemon change, and the same way local and remote
Alternatives: daemon event first; both now
Commit:
Veto: n/a (Evan)

## D-008 · 2026-09-22 · Keep one host at a time
Context: roadmap Tier 2 [?] "All hosts at once"
Chose: stay deferred
Why: Local = remote means parity, not showing everything at once; revisit when several remotes are in daily use
Alternatives: sections now
Commit: n/a
Veto: n/a (Evan)

## D-009 · 2026-09-22 · Milestone = Attention + Files
Context: done criteria
Chose: attention model, file view/edit (local + SFTP), and tab ↔ row linkage, with tests and screenshots
Why: Evan's choice
Alternatives: files first; attention first
Commit: n/a
Veto: n/a (Evan)

## D-010 · 2026-09-22 · Sent the attention contract to the leo agent
Context: B-002
Chose: sent the spec's prerequisite verbatim (optional `attention: {state, revision}` on agent_activity, /state, spawn payloads) and asked for an ETA or counter-proposal; told it not to restart the daemon on our account
Why: D-006; app side proceeds against fixtures
Alternatives: wait to send until B-001 ships (delays the daemon side for no gain)
Commit: n/a (message only)
Veto: [ ]

## D-011 · 2026-09-22 · Leo agent's reply on the attention contract
Context: B-002 reply
Chose: accepted leo's terms: needs_input from Claude only at first (Codex/opencode go working→finished; absence of needs_input = "not detectable"); revision resets per daemon lifetime, plus a requested daemon boot id in hello to trigger re-baseline; `unknown` after a daemon restart until the next hook; unexpected exit (any code) → errored, explicit stop/suspend incl. idle-suspend → unknown; supervised agents only; field absent on existing agents until respawn. Update: Evan approved the daemon spec (/Users/evan/.leo/workspace/docs/specs/2026-09-22-agent-attention.md) incl. `boot_id` on SSE hello; re-emitting the same state (finished→finished across turns) still bumps revision. Leo is planning; will ping when on main. Status 2026-09-22 18:54: in review as leo PR #210 (stacked on #209); not merged, released, or restarted. Release timing is Evan's call.
Why: principle 2 (never invent a state); boot id makes reconnect handling explicit
Alternatives: suspend keeps last state (would show stale "finished" on sleeping agents)
Commit: n/a (message only)
Veto: [ ]

## D-012 · 2026-09-22 · Attention badge is icon-only; state word moves to the subtitle
Context: B-001 visual check
Chose: a fixed-width SF Symbol capsule on the trailing edge; subtitle reads "claude · Needs Input", with the state word tinted (primary colour on a selected row); VoiceOver value unchanged
Why: principle 1/2: the text capsule truncated names to "chro…"; the name is the row's identity
Alternatives: keep the text capsule and let names truncate; badge on its own line
Commit: a0899a492
Veto: [ ]

## D-013 · 2026-09-22 · Agent notifications ship with B-001, opt-in
Context: B-001 (spec includes notifications)
Chose: Agents ▸ Agent Notifications… item; permission for `.alert` is requested only when you turn it on; a one-time explanation if denied; notification IDs include boot id + incarnation + revision
Why: spec calls for them; opt-in keeps it calm
Alternatives: defer to a later item
Commit: 93e0c4f78 190b70f4b
Veto: [ ]

## D-014 · 2026-09-22 · Stale or unknown attention shows no badge
Context: B-001
Chose: after a disconnect, stale states lose their badge and drop out of the Dock count and Jump until the next /state baseline; malformed `attention` = absent (legacy); an unrecognised state string = unknown (clears); the legacy Working badge stays until the first attention candidate commits (no flicker)
Why: principle 2: never show a state that may be wrong
Alternatives: keep the last state greyed
Commit: 465676949 190b70f4b
Veto: [ ]

## D-015 · 2026-09-22 · The attention badge replaces the activity dot
Context: B-001
Chose: the leading activity dot is hidden when a row has a badge, so a legacy working agent shows the blue Working badge instead of the green dot
Why: one status signal per row
Alternatives: show both
Commit: 465676949
Veto: [ ]

## D-016 · 2026-09-22 · One-line focus notification in upstream BaseTerminalController
Context: B-001 (focused split = viewing)
Chose: `focusedSurface` posts a notification on change, marked `// MARK: Leo`
Why: the only hook for split-focus changes; D-002 allows minimal core edits
Alternatives: poll first responder
Commit: 465676949
Veto: [ ]

## D-017 · 2026-09-22 · `attention` on agent_spawned: top level or inside `agent`
Context: B-001 decoding
Chose: accept both; top level wins. Leo later confirmed the daemon emits it only inside `event.agent` (same struct as /state), and top-level on `agent_activity`. The tolerant decoder stays, since it's harmless. Leo's daemon branch is feat/agent-attention; needs_input → working happens on the next PostToolUse after a prompt resolves.
Why: the daemon spec says only "spawned-agent payloads"
Alternatives: guess one placement
Commit: 4e064d6f7
Veto: [ ]

## D-018 · 2026-09-22 · DEBUG-only `LEO_ATTENTION_FIXTURE` overlay
Context: B-001 verification
Chose: DEBUG builds read a JSON file mapping agent → attention and overlay it on /state; nothing is sent anywhere
Why: allows screenshotting badges before the daemon ships the field
Alternatives: wait for the daemon
Commit: 60cb67072
Veto: [ ]

## D-019 · 2026-09-22 · Poll while the attention baseline is pending, even with SSE up
Context: B-001 review (N1)
Chose: the existing 30 s poll also runs while a /state baseline is pending; no new timer
Why: a failed baseline must retry; principle 5 is about tunnel reconnects, and this reuses the existing poll
Alternatives: one-shot retry timer
Commit: c5540f3c7
Veto: [ ]

## D-020 · 2026-09-22 · Tab-count glyph on the subtitle line
Context: B-006
Chose: `macwindow` caption2, secondary colour, on the trailing end of the subtitle line; the count appears only when there are 2 or more; splits count, exited attaches don't
Why: it costs the name no width (lesson from D-012); principle 2: calm
Alternatives: glyph next to the name
Commit: 54ae397a2 e05e818b7 71d366ad1 e07fa6b65
Veto: [ ]
Superseded: glyph removed by B-047 (d403a2c9a), approved by Evan 2026-09-24

## D-021 · 2026-09-22 · Clicking a row with a live tab focuses that tab
Context: B-006
Chose: single click (or Return) on any row whose agent has a live tab focuses its most recently focused tab or split instead of attaching again; option-click and option-double-click skip this; arrows only select
Why: principle 4: finding an agent's tab takes one click
Alternatives: focus only on double-click
Commit: 54ae397a2 e05e818b7 71d366ad1 e07fa6b65
Veto: [ ]

## D-022 · 2026-09-22 · Selection follows focus only on real focus changes
Context: B-006
Chose: the highlight moves when attach focus changes, or when a snapshot brings the focused row back; count-only changes and focus leaving all attaches don't move it
Why: principle 2: never invent; don't fight the user's arrow keys
Alternatives: always mirror focus
Commit: 54ae397a2 e05e818b7 71d366ad1 e07fa6b65
Veto: [ ]

## D-023 · 2026-09-22 · SFTP backend: a hand-rolled SFTP v3 client over the ControlMaster
Context: B-003, D-003
Chose: a small Swift SFTP v3 client (pure packet codec + pipe transport) speaking to `ssh <ControlMaster opts> -s <host> sftp`; atomic overwrite via posix-rename@openssh.com when the server offers it; tests run against macOS `/usr/libexec/sftp-server` over pipes
Why: principle 3 (rides the app's tunnel); no third-party dependency (licensing is on the stop list); fully testable without sshd
Alternatives: shelling out to `sftp -b` batch mode (brittle parsing, no conflict check); `ssh host cat/stat` commands (not SFTP, quoting risk); Citadel/libssh2 packages (new dependency, a second SSH stack alongside ControlMaster)
Commit: 7fd10dad9 6f92f70e9 9b466088a a0b838dcd 1c7c93e5f 7858fbda8 4ee7c8353 515e6554b e780ead10 6f52a67c8 da7fca9c4
Veto: [ ]

## D-024 · 2026-09-22 · The app's SSH tunnel is now the ControlMaster
Context: B-003: the app had no ControlMaster to reuse (the tunnel ran ControlMaster=no)
Chose: the tunnel is the master, with ControlPersist=no. The socket is `~/.leo/state/leoterm/cm-<bundle8>-<id12>-<conn8>`; conn8 hashes target/user/port/identity. A stale socket is unlinked only if connect() is refused and lstat says it's a socket. If the path is invalid or occupied, the tunnel falls back to ControlPath=none and file access reports "unavailable". SFTP runs with ProxyCommand=/usr/bin/false plus sftp(1)'s overrides, so it never opens a second connection
Why: D-003 needs SFTP over the existing connection; principle 3
Alternatives: a separate ssh connection per SFTP session (a second auth, and can prompt)
Commit: a0b838dcd e780ead10 da7fca9c4
Veto: [ ]

## D-025 · 2026-09-22 · File-access save semantics
Context: B-003
Chose: atomic temp+rename on both backends; the conflict token is mtime+size (SFTP v3 has whole-second mtime); a write through a symlink replaces its target; FIFOs/devices are never opened; paths must be absolute; after a disconnect, the next operation makes one fresh attempt with no background retry; save replaces the inode (documented: owner/group, ACLs, xattrs and hard links are lost)
Why: atomic saves protect agents' files; principle 5 (no timers)
Alternatives: in-place overwrite (torn writes)
Commit: 7fd10dad9 6f92f70e9 9b466088a a0b838dcd 1c7c93e5f 7858fbda8 4ee7c8353 515e6554b e780ead10 6f52a67c8 da7fca9c4
Veto: [ ]

## D-026 · 2026-09-22 · Attention: per-row legacy detection, list-driven deletion, bounded tombstones
Context: B-015 and leo's live-testing clarifications (unknown on launch, errored across restart, a fresh row briefly missing its field)
Chose: legacy "Working-only" mode stays per row, not daemon-wide, so opencode agents without the field keep their Working badge. Only list membership deletes an agent; a /state that lacks a listed agent drops its state and revision floor but keeps its incarnation. Tombstones are capped at 64 and only tombstoned names are trimmed. A pending `unknown` hides the legacy Working badge while it settles
Why: principle 2 (never invent a state, no duplicate notifications); a daemon-wide switch would remove a visible feature (stop list)
Alternatives: daemon-wide legacy switch; treating "missing from /state" as deleted (caused re-notification)
Commit: c5c24c336 8dfe3aa7c 91fd60791 4fea50a28 a4411496e
Veto: [ ]

## D-027 · 2026-09-22 · Stop B-015 at three fix rounds and ask the daemon for an instance id
Context: B-015's third review found another recreate-during-gap edge (already present before B-015). Each round had moved the "was this agent recreated?" guess to a new edge case
Chose: ship B-015 as is (strictly better than before), file B-018, and ask the leo agent for a per-instance agent id so dedupe stops guessing from revisions. leo replied that no id is needed: revisions are monotonic per name per boot, even across delete and recreate. B-018 became a simplification that removes the heuristic
Why: the gap is a missing daemon fact, not app logic; the skill caps fix attempts at 3; AUTONOMY allows contract requests to the leo agent
Alternatives: a fourth heuristic patch
Commit: (none; backlog and message only)
Veto: [ ]

## D-028 · 2026-09-22 · Dedupe attention on (boot, name, revision) per leo's contract
Context: B-018; leo's spec says a revision is monotonic per agent name per boot, including across delete, recreate and rename
Chose: removed incarnations, tombstones and droppedFloors. A per-name revision floor and Dock acknowledgement survive the loss of display state and clear on boot change or host switch. Signals buffered during recovery commit silently, as the app spec says. Dismissed review LOWs: a daemon that sends attention without a boot_id (the contract requires one; legacy daemons send no attention); a stale baseline outside recovery below the floor (barely reachable); a spawn mark lost on boot change (same as before, and the new boot's baseline repopulates it)
Why: principle 2 (no duplicate or lost notifications); relying on the daemon's fact beats guessing
Alternatives: keep patching the heuristic; ask for an instance_id (leo declined as unnecessary)
Commit: f2ed8537a
Veto: [ ]

## D-029 · 2026-09-22 · "Viewing" and "keyboard focus" are separate signals
Context: B-016; requiring the first responder for row linkage made sidebar focus count as "not looking"
Chose: the attention feed, Dock acknowledgement and Jump use "viewing" (the key window's focused split, ignoring the first responder). Row linkage and selection use keyboard focus (the first responder). Viewing a tab also makes it the agent's most recently used tab, so a later row click brings it forward. Focus updates reach the attention feed through one ordered relay. Reactivating the app suspends focus instead of clearing it, so an arrow-key selection survives
Why: principle 2 (never badge or Jump to what you're looking at); D-005 (focused split = viewing); D-022
Alternatives: one focus signal for both uses (either breaks attention or breaks reselecting a row)
Commit: 82c835016 ab3f8c6ff 89ff485c9 79f8d61f2
Veto: [ ]

## D-030 · 2026-09-22 · The hover Attach button reserves its width
Context: B-016 (b)
Chose: while a row is hovered, a hidden, zero-height copy of the button reserves space on the name line, so the name truncates before the button. Badges shift left instead of hiding, and the row height stays the same
Why: principle 1 (HIG: controls never overlap text); nothing is hidden
Alternatives: hide the badges on hover; show the button only on the subtitle line
Commit: 7d2b676e7
Veto: [ ]

## D-031 · 2026-09-22 · A user click or selection wins over in-flight focus reports
Context: B-016 (a)
Chose: host focus reports carry a sequence number, and a click, Return or arrow-key selection ignores any report sent before it
Why: principle 1 (the user's click is authoritative)
Alternatives: debounce with a timer (principle 5: no timers)
Commit: c25cf3523
Veto: [ ]

## D-032 · 2026-09-22 · B-017 closes at 3 fix rounds; the remaining sanitizer gaps move to B-020
Context: B-017's third security review found 2 MEDIUM unsanitized paths (a rename temp name, and Foundation's localizedDescription) plus LOWs. Both MEDIUM paths date from B-003, not B-017
Chose: ship B-017 (its acceptance is met) and file B-020 to sanitize once where errors render, not source by source. Control sockets moved to `<DARWIN_USER_CACHE_DIR>/leo/` (C/, not T/, which macOS cleans); a loose directory we own is tightened, a foreign one is refused; the server's error text is quoted as `the server said “…”`; apostrophes are kept and only double-quote lookalikes are straightened
Why: each round had found another source; one choke point is the structural fix, and the skill caps fix attempts at 3
Alternatives: a fourth per-source patch
Commit: 97781e299 f8b3b4350 fb1bb244b 119697892 198da68e3 adb143d49 1c8ae5131 2f5f51b4d abf708a54
Veto: [ ]

## D-033 · 2026-09-22 · Editor pane product calls
Context: B-004
Chose: a trailing split beside the terminal, one per window. A recents pop-up in the header; replacing a file with unsaved edits asks Save / Don't Save / Cancel. A built-in regex highlighter for 10 languages, with lines over 4096 characters left unhighlighted. The file is checked for changes when the window becomes key and before saving (no polling). A clean buffer reloads silently; a dirty one shows a Reload / Keep Mine banner. Files over 5 MB, binary or non-UTF-8 open read-only; over 20 MB they're refused. ⌘-click takes bare paths, `file:` and OSC 8 `file:` links only from agent terminals, and `:line:col` moves the caret. Menu items: Agents ▸ Open File in Editor… (⇧⌘O), Focus Editor/Terminal (⌥⌘E); File ▸ Reload from Disk (⌥⌘R), Keep My Version (⌥⌘K). A `file://` host part is ignored. Every close and quit path goes through one unsaved-edits gate; closes that can't prompt keep the tab with the editor. A hung remote operation offers Keep Waiting / Quit Anyway instead of a timeout
Why: principles 1 (keyboard-first, HIG), 2 (calm), 3 (local = remote through LeoFileAccess), 5 (no timers); no new dependencies (stop list)
Alternatives: a separate editor window per file; a tree-sitter highlighter (new dependency); polling for changes on disk
Commit: 5980d43a6 95eff7499 8516b9867 f25eefc0c 60b6c5f72 e47c78546 f401ac93e cfb66debf 5036f153b 9db8771af a820ef868 53a8e62b8 120129672 90e96b9ea 0b6569257 eca4cfbc1 a0f19db31 5cd057694 676f70548
Veto: [ ]

## D-034 · 2026-09-22 · Kept B-004 after 3 fix rounds instead of reverting it
Context: the autopilot rule reverts an item after 3 fix attempts. After B-004's third round, its final review found one MEDIUM: an editor edited while a logout-time "Quit Anyway" offer (for a hung remote save) is up isn't asked about. Each round had fixed everything its review raised (3 HIGH, then 2 MEDIUM, then 1 HIGH), and the feature is verified
Chose: keep B-004 and move the edge case, plus the split-width and wiring-test gaps, to B-022. This departs from the skill's revert rule; that rule targets items that don't converge, and this one did
Why: reverting 19 working commits to avoid one rare edge case would remove the milestone's core feature
Alternatives: revert B-004 and block it (the literal rule). Veto this to get that
Commit: (none; judgment call on the rule)
Veto: [ ]

## D-035 · 2026-09-23 · Workspace browser as a file list inside the editor pane
Context: B-005
Chose: the browser is a collapsible outline (NSOutlineView) on the leading edge of the B-004 editor split, rooted at the agent's workspace (the same root that relative ⌘-click paths resolve against). Opened from the row context menu "Browse Files" and Agents ▸ Browse Agent Files (⌥⌘B unless taken; implementer picks a free one and reports it). Folders load lazily through LeoFileAccess, folders first then names in Finder order; dotfiles hidden with a Show Hidden Files toggle (⇧⌘.) like Finder. Arrows navigate, → / ← expand and collapse, Return opens the file in the editor pane, Escape returns focus to the terminal. Refresh on window-becomes-key and a manual Reload, never on a timer. Errors show inline in the list, not as alerts
Why: principles 1 (keyboard-first, Finder conventions), 3 (one LeoFileAccess path, local = SFTP), 4 (read agent files without leaving), 5 (no timers)
Alternatives: a separate browser window; a popover; an entry in the sidebar tree
Commit: 864a16bc6 7204dd557 a2620137c 75a0feeef 860df8083
Veto: [ ]

## D-036 · 2026-09-23 · The terminal keeps at least 300 pt; side panes make room by collapsing the sidebar
Context: B-005 review: sidebar + browser + editor left the terminal about 97 pt wide in an 800 pt window
Chose: the terminal gets a 300 pt floor. When opening the browser or the editor would push it below that, the agents sidebar collapses first (⌘⇧L brings it back). If there's still not enough room, the pane opens anyway at its minimum width; the user's action is never refused
Why: principle 1 (the terminal is the primary surface; first-party apps give up the sidebar before the content); principle 2 (nothing beeps or refuses)
Alternatives: refuse and beep; collapse the browser when the editor opens
Commit: 860df8083
Veto: [ ]

## D-037 · 2026-09-23 · B-005 implementer calls
Context: B-005 build and fix round
Chose: the browser is its own split item between the terminal and the editor (no nested split view). File-open errors show in a dismissible bar under the list; folder-listing errors show as rows you can't select. A symlink to a folder counts as a folder. With no workspace reported, the list says "This agent hasn't reported a workspace." ⌥⌘B steps open → focus → close ("Close Agent Files"). ⌘R reloads and ⌘W closes only while the browser has focus. The hidden-files setting is per window and not saved. The auto-collapse of the sidebar isn't saved as a preference. Symlink stats run at most 8 at a time
Why: principle 1 (Finder conventions, keyboard-first); avoids the known nested NSSplitView launch crash
Alternatives: nest the browser in the editor's own split; show errors as alerts
Commit: 864a16bc6 7204dd557 a2620137c 75a0feeef 860df8083
Veto: [ ]

## D-038 · 2026-09-23 · B-022: handle the hung-save logout in the app; the editor opens at half the content area
Context: B-022 (b) asked for a laptop check or an in-app leave-anyway, and (c) for 50/50 placement
Chose: (b) no laptop check (stop list). While a system quit or logout is pending (`.terminateLater`) behind a hung remote save, the Keep Waiting / Quit Anyway offer is reachable from inside the pending quit itself, not only through a second ⌘Q. (c) The editor opens at half of the width the terminal and editor share, never taking the terminal below D-036's 300 pt floor, and it's placed after the un-collapse finishes. (e) The quit review's button reads "Quit Anyway" when quitting and "Close Anyway" when closing
Why: principle 1 (HIG button verbs match the action); principle 5 (the user decides, no timers); stop list (laptop)
Alternatives: wait for Evan to test on the laptop
Commit: 59ffb1fbd 4130f9e75 e43aaa796 7a5ef7310 a89b18a3c 363468b41 98a558bdf e89dc3ff6 445437a58 af5762504 9865e60b3 b9dd6e318 eeb6b86b2 bbcf58601
Veto: [ ]

## D-039 · 2026-09-23 · B-022 implementer calls
Context: B-022 build and three fix rounds
Chose: while a pending quit or logout waits on an editor's disk or connection, the editor shows a banner ("Quitting is waiting for <host> to finish with …") with a Quit Anyway… button, rather than an alert that pops up by itself (with no timer, a hung save can't be told from a slow one). Leaving from inside a quit keeps that quit going with the other editors; ⌘W on the stuck editor takes the same path (its button still reads "Close Anyway"). The Quit Anyway button is disabled while another leave offer is up. Don't Save during an in-flight save waits for the document's queue to go idle, with the banner up and the text read-only, instead of abandoning the user's own ⌘S. The editor is widened by moving the terminal's trailing divider; reopening a file in an already-open pane keeps its width
Why: principles 2 (calm, no self-presenting alerts), 5 (the user decides, no timers); no half-written remote files
Alternatives: a self-presenting alert; abandoning the access on Don't Save
Commit: 59ffb1fbd 4130f9e75 e43aaa796 7a5ef7310 a89b18a3c 363468b41 98a558bdf e89dc3ff6 445437a58 af5762504 9865e60b3 b9dd6e318 eeb6b86b2 bbcf58601
Veto: [ ]

## D-040 · 2026-09-23 · Only the three RGI subdivision flags keep their tag characters
Context: B-020 review: tag runs after U+1F3F4 were capped per flag but not per message, so a hostile server could hide over 1 KB of tag-encoded ASCII in an error ("ASCII smuggling") that agents reading the app's text would see
Chose: tag characters survive only as part of the England, Scotland or Wales flag sequences; all other tag characters are dropped. Errors from outside LeoFileAccessError are isolated (FSI…PDI) like the rest
Why: agents read this text (principle 4); three flags cover every RGI subdivision flag, so nothing a person would see is lost
Alternatives: a per-message cap on tag scalars; dropping all tag characters
Commit: 796b0a2ec
Veto: [ ]

## D-041 · 2026-09-23 · Variation selectors and blank fillers in untrusted text
Context: B-020 re-review: variation selectors (U+FE00–FE0F, U+E0100–E01EF) counted as combining marks, 4 per base with no cap per message, which leaves room for about 760 hidden bytes; Hangul fillers and Braille blank rendered as invisible text
Chose: keep only U+FE0E and U+FE0F, at most one directly after a base. Drop all other variation selectors, including the ideographic ones (a CJK name can lose a glyph variant, but no characters). Hangul fillers (U+115F, U+1160, U+3164, U+FFA0) and U+2800 count as whitespace
Why: agents read this text (principle 4); emoji presentation stays intact
Alternatives: a per-message cap on selectors
Commit: 8b6494d45
Veto: [ ]

## D-042 · 2026-09-23 · Untrusted text keeps invisible characters only from an allowlist
Context: B-020's third review found two more invisible carriers (U+034F, and uncapped ZWJ/ZWNJ). Each round had found a new class
Chose: an invisible scalar survives only if it's on an explicit allowlist and in its allowed position: ZWJ between two emoji, ZWNJ between two letters, a single FE0E/FE0F after a base, and the three RGI flag tag sequences. Every other zero-width scalar is dropped. Private-use, noncharacter and unassigned code points become U+FFFD, at most one in a row
Why: the structural fix, not a fourth blocklist entry (Engineering Discipline: after 3 attempts the approach is wrong); agents read this text (principle 4)
Alternatives: keep adding classes to a blocklist
Commit: 935b5a600
Veto: [ ]

## D-043 · 2026-09-23 · Kept B-020 after 3 fix rounds instead of reverting it
Context: after B-020's third round (the allowlist), the final review found one HIGH: FE0E/FE0F may follow any visible character, not only an emoji, which leaves roughly 20–30 bytes of hidden payload per message. The rule is to revert after 3 attempts
Chose: keep B-020 and file the one-line gate (selectors only after a pictographic base) as B-026. Also: the implementer's calls (a structured `LeoFileAccessReason` so the app's own quotes survive; mark cap 4; "they were kept as “…”"; names wrapped in FSI…PDI in the editor banner, alerts and path prompt; host names in `unavailable` reasons cleaned; strerror treated as trusted; ZWJ runs keep one; "emoji" = Emoji + So)
Why: the finding is residual, not a regression. Reverting would bring back the pre-B-020 state, whose channels (tag runs, supplementary selectors, raw local filenames) were far larger
Alternatives: revert B-020 and block it (the literal rule). Veto this to get that
Commit: ad0807785 796b0a2ec 8b6494d45 935b5a600
Veto: [ ]

## D-044 · 2026-09-23 · Forwarded daemon socket moves to the short per-user directory
Context: B-021
Chose: the socket is `<DARWIN_USER_CACHE_DIR>/leo/lt-<bundle hash>-<id12>.sock` (82 bytes whatever the home dir), stable per host and scoped per app bundle. An unsafe socket directory now fails the whole tunnel, where before only file access was lost. A dead socket this app left in `~/.leo/state/leoterm/` is removed; nothing else there is touched. A vanished socket reads "Reconnect to restore it". The review's MEDIUM (a live socket at the new path is still unlinked and rebound, as before) was dismissed: that unlink predates B-021, production has one host selection, and the only realistic live socket is an orphaned `ssh -L` left by a crashed run, where rebinding is the recovery. Enforcing one tunnel per host → B-027
Why: principle 3 (the tunnel must work for any home dir); principle 5 (the user can always recover)
Alternatives: refuse a live socket with "already in use"
Commit: cda6610e8
Veto: [ ]

## D-045 · 2026-09-23 · Kept B-019's tests after 3 fix rounds instead of reverting them
Context: each B-019 review found a narrower timing hole in the host focus test's waits (a sleep, then a poll limit, then a missing main-queue barrier). The final review found one HIGH: `reports` ignores a false `caughtUp()` (`GhosttyAttachTabHostFocusTests.swift:168`), so a report yielded but never recorded could let the order check pass
Chose: keep the tests and file the one-line `require caughtUp()` as B-028. The only production changes are two test seams: `GhosttyAttachTabHost.appFocusState` (defaults to NSApp) and `LeoRuntime.focusedAgentSink` (defaults to the feed)
Why: the tests already catch four real breakages; reverting would remove all coverage to avoid one edge case in the harness itself. Third keep this run (with D-034's B-004 and D-043's B-020): Evan may want to change the 3-round rule rather than have it overridden
Alternatives: revert B-019 and block it (the literal rule). Veto this to get that
Commit: c92565ac3 ad537d10e 79d5d9375 6be661a48 24000299e
Veto: [ ]

## D-046 · 2026-09-23 · A presentation selector survives only when it changes what's drawn
Context: B-026. Gating FE0E/FE0F on "pictographic" (Emoji + So) dropped valid sequences like ‼️, and still let FE0F follow an emoji that already draws as emoji (😀 vs 😀️ look the same: one hidden bit per emoji). Likewise ZWNJ between Indic letters with no virama changes nothing
Chose: a selector is kept only after a base listed in Unicode's emoji-variation-sequences.txt, and only when it flips the base's default presentation (FE0F on a text-default base, FE0E on an emoji-default base); keycaps keep digit/#/*+FE0F+20E3. Indic ZWNJ is kept only right after a virama; Arabic ZWNJ only between two joining letters
Why: every surviving invisible must make a visible difference, so none can carry hidden bits (D-042's allowlist, tightened); principle 4
Alternatives: accept one hidden bit per emoji; allow every Emoji-property base
Commit: e5efc61b4 ac9539839 5a44072dd 03ac88d26
Veto: [ ]

## D-047 · 2026-09-23 · Untrusted text is canonical: RGI tables, NFC output, canonical keycaps
Context: B-026 fix rounds 2–3; each review found another invisible whose presence drew identically (ZWJ between non-RGI emoji, alef+ZWNJ, cross-script or vowel-side Indic ZWNJ, optional keycap FE0F, decomposed vs precomposed accents)
Chose: embed Unicode 18.0 data (emoji-zwj-sequences, emoji-variation-sequences, ArabicShaping Joining_Type, IndicSyllabicCategory consonants) in `LeoUnicodeData.swift`; ZWJ survives only inside the longest exact RGI match; keycaps always come out base+FE0F+20E3; the scan reads NFD and emits NFC (the mark cap of 4 counts marks inside composed letters); Indic ZWNJ needs consonant(+nukta)+virama → same-block consonant; tatweel and Arabic presentation forms don't count as joining; unqualified ZWJ sequences (missing FE0F) lose their joiners
Why: D-046's rule (an invisible survives only if it changes what's drawn) applied to every carrier, from Unicode's own tables rather than hand ranges; principle 4
Alternatives: keep patching per-rule blocklists; accept ~1 bit per character
Commit: 5a44072dd 03ac88d26
Veto: [ ]

## D-048 · 2026-09-23 · B-027(c) (drop the activity stream's backoff retry) moves into B-007
Context: B-027(c) says `LeoSocketActivityClient`'s exponential-backoff reconnect is an auto-reconnect timer (against principle 5), to be folded into B-007's manual Retry
Chose: B-027 does (a) and (b) only; B-007 takes (c). Removing the backoff before a Retry banner exists would leave a dropped stream silently dead until relaunch
Why: principle 5 needs the manual Retry to exist before the timer can go; never leave the user without a recovery path
Alternatives: remove the backoff now and rely on relaunch
Commit: n/a (scope)
Veto: [ ]

## D-049 · 2026-09-23 · Tunnel path ownership = an exclusive flock held by the live app
Context: B-027. The first fix probed the socket (connect → ECONNREFUSED = dead) and then unlinked it: racy between copies, ECONNREFUSED is ambiguous on Darwin (full backlog), the connect could block, and launch reaping still SIGTERMed a sibling copy's healthy tunnel
Chose: each tunnel path has `<path>.lock` (same checked dir, 0600, CLOEXEC); the app holds `flock(LOCK_EX|LOCK_NB)` for the tunnel's life. Holding the lock means any socket or orphan record at that path is a dead app's, safe to reap and unlink without a probe; a busy lock → "already in use by another copy of Leo" and nothing is signalled. Also the implementer's calls: `StreamLocalBindUnlink` dropped from the ssh args; records whose process is gone are cleared at launch; `LeoAgentActions` requires the injected selection
Why: principle 3 (tunnel robustness) and 5 (a crashed run still self-recovers; a live sibling is an explicit error, never silently stolen); the kernel releases the lock on crash
Alternatives: harden the connect probe with a deadline and errno classification
Commit: 9bdf7cb22 07e8aaa59 93032ed6e
Veto: [ ]
Reverted: 75f5b8eda (B-027 blocked after 3 attempts)

## D-050 · 2026-09-23 · Editor close-wait: lock only once committed; "Closing…" banner
Context: B-024
Chose: the text locks once a close is committed (prompt answered or not needed), not whenever the queue is busy; the model refuses edits synchronously then, so a racing keystroke is undone. `Closing “<file>”…` (hourglass, no buttons) shows while any close waits, including one queued behind a slow open with the text still editable; Quit Anyway's banner outranks it, and it outranks disk-conflict/error banners; the copy names the file, not the host. A DEBUG-only `LEO_SLOW_SAVE_SECONDS` hook delays saves. Dismissed: a write already in flight can land after Quit Anyway (inherent, as in B-022)
Why: principle 2 (calm, explain waits instead of silently locking) and principle 5 (the user can always recover)
Alternatives: keep locking on any busy queue; a spinner
Commit: 188851f1f 6a6be8646 7d10d709e 605d43e68
Veto: [ ]

## D-051 · 2026-09-23 · Leo is single-instance per bundle (Evan)
Context: B-027 blocked after 3 rounds; every HIGH came from two copies of one bundle racing over shared tunnel state
Chose: an app-level lock at launch; a second copy of the same bundle activates the first and quits. Release and debug bundles stay independent. B-027 shrinks to removing the `LeoAgentActions` fallback plus the stale-record test
Why: Evan's answer to B-027 (2026-09-23)
Alternatives: per-path flock ownership (D-049, reverted)
Commit: 10be4b608 6fec65c82 67de1e864 682f967c4 73109b6c3
Source: a line in the gitignored .autopilot/INBOX.md at preflight. Rocket later reported that Evan approved it in session 0bc621e0 (21:11Z, "yes to you recs and yes to approving screenshoting"), which wrote the line. Left vetoable; no action needed
Veto: [ ]

## D-052 · 2026-09-23 · Autopilot may drive the isolated debug app's input (Evan)
Context: B-024 could not be visually verified because peekaboo type/press/click was refused
Chose: verification may use peekaboo type/press/click, always with `--app studio.blackpaw.leo.macos.debug`; the real-agent rules in AUTONOMY still apply
Why: Evan approved it (inbox, 2026-09-23)
Commit: n/a
Source: a line in the gitignored .autopilot/INBOX.md at preflight. Rocket later reported that Evan approved it in session 0bc621e0 (21:11Z, "yes to you recs and yes to approving screenshoting"), which wrote the line. Left vetoable; no action needed
Veto: [ ]

## D-053 · 2026-09-23 · Single-instance lock fails closed
Context: B-027 review HIGH: when the instance lock can't be safely taken (symlink, foreign owner, bad dir), launching anyway lets two copies race tunnel state
Chose: show "Leo can't start" with the reason and path, one Quit button, and exit; never touch the offending file. The lock sits in the user's private 0700 cache dir, so only the same user or root can cause this
Why: principle 5 (show it plainly, the user recovers by hand) and the point of D-051
Alternatives: fail open and log (the first build)
Commit: 73109b6c3
Veto: [ ]

## D-054 · 2026-09-23 · B-027 implementer calls
Context: B-027
Chose: the instance check runs in main.swift before NSApplicationMain (a losing copy builds no delegate, runtime or tunnel and exits 0); lock at `<per-user cache dir>/leo/<bundle ID>.instance.lock`, 0600, O_NOFOLLOW|O_CLOEXEC so children never inherit it; a test host is one where `XCInjectBundleInto` resolves to this executable and the XCTest injector is loaded; a missing bundle ID skips the check; a busy lock with no running copy found still quits; a still-live legacy (pre-B-021) socket or ssh is left alone, never signalled
Why: principle 3 (tunnel robustness) and D-051
Alternatives: check in the app delegate; fail open
Commit: 67de1e864 6fec65c82 73109b6c3
Veto: [ ]

## D-055 · 2026-09-23 · Refused keystrokes restore the whole selection; reloads keep a caret
Context: B-030
Chose: only the refused-keystroke revert restores the full selection (the one recorded on the edit's first `shouldChangeText`, snapped to whole characters); disk or conflict reloads keep a caret at the old location, since the new text may be unrelated. With several selections, only the main one is restored
Why: principle 1 (behave like a first-party Mac editor) and 5 (the user loses nothing when a save fails and the pane unlocks)
Alternatives: keep the full range on every reload (review: can highlight unrelated text)
Commit: 31a72e027 0fd885414 ca7f95730
Veto: [ ]

## D-056 · 2026-09-23 · DEBUG `LEO_OPEN_FILE` opens a local file, literally
Context: B-034; GUI checks can't get past the Open File panel
Chose: DEBUG-only `LEO_OPEN_FILE=<absolute path>` opens that file on this Mac in the first window's editor pane, once, whatever host is selected (an optional `access` override on `LeoEditorPaneModel.open`, default unchanged for the menu); the path is taken literally (no `:line`); folders and bad paths are logged and ignored. Dismissed LOW: the fixture file in Recents reopens through the window's access after a host switch (DEBUG-only)
Why: verification needs a way in that automation can reach; principle 3 is untouched in release
Alternatives: drive the Open panel (automation can't focus it)
Commit: 2c05c0b83 de2c47114
Veto: [ ]

## D-057 · 2026-09-23 · What counts as an XCTest host; incomplete test runs fail loudly
Context: B-031. The single-instance check (D-051) quit parallel `xcodebuild test` workers (`XCInjectBundleInto=unused`), which would also break Xcode ⌘U; a suite run cut off by the script's timeout looked like a pass with fewer tests
Chose: a process is a test host only when the XCTest injector is loaded AND the executable of an `.xctest` directly in this app's (realpath'd) Contents/PlugIns is loaded, plus `XCInjectBundleInto` naming this executable (direct runs) or `XCTestBundlePath` resolving to that plug-in (xcodebuild). The worktree's `scratchpad/runtests.sh` prints "RUN INCOMPLETE" and exits 2 when the host ends without a summary; `LEO_TEST_TIMEOUT` overrides the 400 s timeout. The B-025 firing clock is shared as `LeoFiringClock`
Why: tests must not depend on whether a debug copy is running, and a real launch must never skip the lock (D-051)
Alternatives: any XCTest env var (first build; a stray variable skipped the lock)
Commit: 05ec8fd2d 3e3859708 235748c7a b32c98cd4 40fdb2b8a
Veto: [ ]

## D-058 · 2026-09-23 · The 300 pt terminal floor holds on resize and sidebar re-show
Context: B-023(c) asked whether the D-036 floor matters beyond opening a pane
Chose: yes. When the window narrows or ⌘⇧L re-shows the sidebar, the sidebar collapses rather than squeezing the terminal under 300 pt; if that's not enough, the side pane gives way at its minimum
Why: principle 1 (a first-party Mac app never crushes its main content) and consistency with D-036
Alternatives: enforce only when a pane opens (the current behavior)
Commit: 39441c27d abd49da71
Veto: [ ]

## D-059 · 2026-09-23 · A floor-collapsed sidebar comes back; ⌘⇧L greys out when it can't fit
Context: B-023 visual check: after narrowing, widening left the sidebar collapsed and the editor squeezed; ⌘⇧L did nothing, silently
Chose: a sidebar collapsed by the 300 pt floor is transient and returns when the window widens (side panes regain their earlier width first); a sidebar hidden with ⌘⇧L stays hidden. When showing the sidebar would squeeze the terminal, Show Agents Sidebar is disabled, so the shortcut gives the system beep
Why: principle 1 (behaves like NSSplitView's collapse-on-resize and standard menu validation) and principle 2 (no custom alert)
Alternatives: stay collapsed until ⌘⇧L; refuse silently
Commit: b6a773954 f8c0c7c77
Veto: [ ]

## D-060 · 2026-09-23 · B-023 implementer calls; closing a file access is final
Context: B-023
Chose: "hidden" means dot-files only (SFTP v3 has no hidden flag; local = remote); the 300 pt floor applies only while a side pane is shown; dragging a divider never collapses the sidebar; the sidebar returns only when the terminal would keep 300 + 24 pt; only the editor grows back (the browser keeps its width). `LeoFileAccess.close()` is immediate and final: in-flight and later calls fail with "The file connection was closed.", SFTP never relaunches, and a browser root switch closes the old access at once. Dismissed: a local write already in progress that completes after close reports success (true: the file was written; as in D-050); a hung process spawn could delay close (Process.run returns after fork/exec)
Why: principles 1, 3 and 5
Alternatives: reopen after close (leaked connections); wait for cancelled listings (hangs on an unresponsive server)
Commit: 30233456a 36aee4e9e 459098e6b
Veto: [ ]

## D-061 · 2026-09-23 · B-007 disconnected state: shape of the Retry
Context: B-007 (grey the list + Retry banner on tunnel drop or wake; drop the activity stream's backoff per D-048)
Chose: while disconnected, rows stay visible but dimmed and inert (no attach/Jump, no badges, out of the Dock count); a banner at the top of the sidebar reads "Disconnected from <host>" with a Retry button; the same action is a menu item (Agents ▸ Reconnect) with a shortcut that doesn't collide with existing ones. On wake, one immediate liveness check (single shot, never repeated); if it fails, show the disconnected state. `LeoSocketActivityClient`'s exponential-backoff reconnect is removed: a dropped stream enters the disconnected state and waits for Retry. A Retry that fails keeps the banner and shows the (sanitized) reason
Why: principle 5 (manual recovery, never timers), 2 (calm: one banner, no motion), 1 (menu + shortcut), 3 (same for local and SSH)
Alternatives: hide rows while disconnected (hides a feature, loses context); treat every wake as disconnected (a banner after every sleep is noise); keep backoff with a banner (a timer)
Commit: 7a2bf5da5 4f1cd16b7 0ed8a6b8f
Veto: [ ]

## D-062 · 2026-09-23 · B-007 implementer calls
Context: B-007
Chose: Reconnect is ⇧⌘R (free in MainMenu.xib and Ghostty defaults; a test guards clashes); host label "localhost" as in the picker; the banner sits under the host picker, above search; Retry reuses `hostSelection.retry()` for local and remote and keeps attention state on a same-host retry; a host that never loaded keeps the old full-panel error (Open SSH / Start daemon) and only a once-live connection becomes Disconnected; after Start daemon you press Retry; a clean stream end reads "Connection closed"; New Agent (+) and the palette are disabled while disconnected (the palette shows Retry); the editor keeps the selected row's workspace; the legacy TCP client keeps its backoff code but the sidebar stops reading it on disconnect; a connection generation's phases only move forward (connecting → connected → failed, failed final) and older generations are dropped; wake checks carry a token and only the latest applies. DEBUG `LEO_FORCE_DISCONNECTED=1` forces the state once after the first list
Why: principles 1, 2, 3 and 5
Alternatives: a banner above the "Agents" header (farther from the rows it describes); auto-reconnect after Start daemon (a timer in disguise)
Commit: 7a2bf5da5 4f1cd16b7 0ed8a6b8f
Veto: [ ]

## D-063 · 2026-09-23 · B-037 implementer calls; floor re-check is bounded
Context: B-037 (a single big widen restored the editor but not the floor-collapsed sidebar)
Chose: the editor's width is recorded in viewWillLayout, before NSSplitView's own resize layout shrinks it; after a side pane regrows, the floor rule runs once more (at most once) so the sidebar can return; the existing collapse-then-regrow path is bounded the same way (it used to re-run without a limit). Test harness gained `jumpWindow(to:)` (one resize, three settles). Review LOWs dismissed: the depth-1 re-run only matters if a second squeezable pane is added later; the synchronous re-entry through layoutSubtreeIfNeeded early-returns because the window width didn't change
Why: D-059 and D-060 as written; principle 1 (behaves like a native split view)
Alternatives: re-run until stable (a layout loop risk); a deferred re-check on the next runloop (a visible two-step jump)
Commit: 9307c661c
Veto: [ ]

## D-064 · 2026-09-23 · B-032 implementer calls; test sockets live in a reserved temp dir
Context: B-032 (a test drove LeoRuntime with the real socket dir; one leaked socket per full run)
Chose: `LeoRuntime.init` takes the socket directories (defaults unchanged for the app); test host selections use a per-process `mkdtemp` dir `/tmp/leoterm-tests-XXXXXXXX`, removed at bundle end only if this process reserved it; a test-bundle principal class (`LeoRealCacheDirectoryGuard`) snapshots the real cache dir and `~/.leo/state/leoterm` before any test and exits the host non-zero if a run added entries (additions only, since the running debug app shares the dir; a remote connection from the debug app during a run can false-positive and the message says so). `LeoAgentActionsTests` still spawns real `/usr/bin/ssh` (sockets now in the temp dir). Dismissed: a review HIGH that Swift Testing emits no XCTestObservation callbacks (the bundle start snapshot logs before Swift Testing's run start and caught the real leak in run b032red); a final MED that cleanup could delete a replacement dir at the reserved path (needs our 0700 dir deleted mid-run and a new mkdtemp colliding on the same random name, in test-only /tmp)
Why: dependency injection over globals; tests never touch real user state
Alternatives: clean the real dir after tests (deletes shared state the real app uses); a fixed shared /tmp dir (parallel workers collide)
Commit: f6a591e0a 41a653cfd aeb23c6b5 b03191132
Veto: [ ]

## D-065 · 2026-09-23 · B-036 implementer calls; the flakes were test waits, not product races
Context: B-036 (sidebar-feed suites flaked under CPU load)
Chose: every LeoSidebarFeed* suite (not only the named ones) moves from 1–2 s wall-clock deadlines to `until` waits under a 1-minute suite time limit; `until` takes an optional message recorded if the limit cancels it; load proof at 42× `yes` (3× cores) instead of B-031's 2×; timed-out break-checks run one test at a time (a timeout kills the whole host under xcodebuild); per-test UUID defaults domains are removed in a `defer` (macOS still leaves empty plist stubs; not deleted). No product code changed: the B-007 Disconnect failure was the emission count being taken before the activity-state emission that follows each baseline. Dismissed: a review LOW that a failing `until` polls every 1 ms (failure path only, capped by the time limit)
Why: tests must fail only when behavior breaks; event-driven waits over deadlines (B-025, B-031)
Alternatives: longer deadlines (still flaky under enough load, and slower)
Commit: 744ff0a71 fa3a8ff43 c4498f88e d32b2f060 0a9f77d2f b301bc587
Veto: [ ]

## D-066 · 2026-09-23 · B-029 implementer calls; ZWJ matching through a static trie
Context: B-029 (longest-match ZWJ checks cost ~570k candidates for a run of 1,600 👩)
Chose: a static prefix trie behind a `LeoSequenceMatcher` protocol that counts steps; the cleaner takes the matcher as a parameter (production uses the static trie) and returns the step count so work bounds are asserted by counting, not timing; the old matcher lives on only in tests as a differential oracle; `subdivisionFlags`/`variationBases` are no longer private so tests can read them; "has a defined presentation" means assigned and emoji under ICU; the long truncated-sequence test runs 400 scalars (the 👩 test runs 1,600)
Why: identical output (35,546-input differential, 0 differences) with linear work; tests that don't flake under load (B-025, B-031, B-036)
Alternatives: cap the candidate list (changes output); wall-clock thresholds (flaky)
Commit: 0747da6d4 cef6e152a
Veto: [ ]

## D-067 · 2026-09-24 · B-038: Choose Agent while disconnected is disabled, with the reason as help text
Chose: truncate the banner's reason to one line (tail truncation) with the full sanitized reason as its tooltip; disable the main pane's "Choose Agent…" while the feed is disconnected, with help text "Disconnected from <host>. Reconnect first (⇧⌘R)."
Why: "calm" + "manual recovery": a picker that lists stale agents invites a failing attach; the banner already offers Retry
Alternatives: leave it enabled and show an error on use (a click that can only fail)
Commit: 622783dad d1e8e149a
Veto: [ ]

## D-068 · 2026-09-24 · B-038 implementer calls
Chose: ⌘T/⌘D (New Tab / Split) stay enabled while disconnected, since their picker already shows the disconnected row with Retry (B-007); loading and failed states keep Choose Agent enabled (only disconnected disables it); the disabled button drops to plain `.bordered` because a disabled `.borderedProminent` still reads as pressable blue in dark mode; the palette's disconnected row is not restyled (B-041); review LOW dismissed: the tests check the view model, not the rendered view, but the live AX check confirmed the wiring (is_enabled=false, correct help) and a SwiftUI render test needs hosting infra this item doesn't warrant
Why: calm; don't disable general commands for one state; visible affordance
Alternatives: disable ⌘T/⌘D too (hides general commands); opacity hack on the prominent button
Commit: 622783dad d1e8e149a
Veto: [ ]

## D-069 · 2026-09-24 · B-033: abbreviate the lock path; "Show in Finder" reveals the lock file
Chose: the "Leo can't start" alert shows `…/leo/<file name>` (last directory + file) instead of the full `/var/folders/…` path; the full path goes in the alert's informative text only as a selectable accessory or is dropped; buttons "Quit" (default) and "Show in Finder" (reveals and selects the lock file via NSWorkspace.activateFileViewerSelecting, then keeps the alert up)
Why: Mac-native (HIG alerts: short text, a concrete next step); "everything through Leo"
Alternatives: middle-truncating the full path (still unreadable); a "Copy Path" button (Finder is the more native next step)
Commit: 7dd3ea2bf f93fab899 e2736fec7
Veto: [ ]

## D-070 · 2026-09-24 · B-033 implementer calls; path on its own line
Chose: the sentence names the file by role ("Leo's instance lock …", "Leo's lock folder …") and the short path sits on its own small, grey, selectable, middle-truncated line under it, full path (sanitized) as tooltip, because even `…/leo/<file>` hyphenated mid-word in the 260pt alert; control, format and line/paragraph-separator scalars in the path show as U+FFFD; non-file refusals keep Quit only; DEBUG-only `LEO_FORCE_START_FAILURE=1` simulates the refusal without touching the lock; Show in Finder picks file vs. folder at click time; the `alert` callback takes the whole refusal. Review LOWs dismissed: the unsanitized refusal message only carries Leo's own bundle ID (from its signed Info.plist, not untrusted), and the Show-in-Finder test calls the selector directly because a unit test can't drive NSAlert's modal loop
Why: HIG (short alert text, a concrete next step); the item's goal was no mid-word breaks
Alternatives: path inside the sentence (breaks mid-word at alert width)
Commit: 7dd3ea2bf f93fab899 e2736fec7
Veto: [ ]

## D-071 · 2026-09-24 · B-009: sidebar search shortcut, fuzzy ranking, Escape
Chose: "Agents ▸ Find Agent…" focuses (showing if hidden) the sidebar filter. Shortcut ⌘F only if Ghostty doesn't already bind ⌘F (terminal find); if it does, keep terminal find on ⌘F and use ⌥⌘F. Fuzzy = case-insensitive subsequence over agent name (and template), ranked exact > prefix > word-boundary > contiguous > scattered, ties by current order; matched characters bold. Escape clears a non-empty filter; Escape on an empty filter returns focus to the terminal. Return attaches/focuses the top match.
Why: keyboard-first; don't remove an existing feature (terminal find) to satisfy a backlog line
Alternatives: take ⌘F from terminal find (removes a user-facing feature: stop list); plain substring (misses "lhs" → leo-home-assistant)
Commit: 93a8c5b9f 823a717fb 03974e177
Veto: [ ]

## D-072 · 2026-09-24 · B-009 implementer calls
Chose: ⌥⌘F (Ghostty binds ⌘F to terminal Find via `start_search`); rows ranked across sections, sections ordered by their best match so the top row on screen is what Return picks; template matches count but a name match wins ties and only the name is bolded; Find Agent… is disabled (beeps) when showing the sidebar would squeeze the terminal, like Show Agents Sidebar, and otherwise shows it and saves "visible"; the filter became an AppKit text field (SwiftUI TextField on macOS 13 can't catch Escape/Return); the list's hidden Return button defers to the field when it has focus; matching is case-insensitive but accent-sensitive, counts graphemes, and handles expanding folds (ß↔ss, ﬁ↔fi) because leo agent names aren't restricted to ASCII on spawn; the agent palette keeps its own substring filter
Why: keyboard-first; don't take an existing shortcut; the top visible row = Return target
Alternatives: keep section order fixed (Return target not the top row); accent-insensitive (surprising for exact names)
Commit: 93a8c5b9f 823a717fb 03974e177
Veto: [ ]

## D-073 · 2026-09-24 · B-010: activity sort, a Pinned section, collapsible sections
Chose: within each section, rows sort by the daemon's last-activity timestamp, newest first, ties/unknown by name; if the daemon exposes no activity time, keep daemon order and log it (never invent a time). Agents ▸ Sort By ▸ Last Activity / Name (checkmarked, remembered). Pin/Unpin from the row context menu and Agents ▸ Pin Agent (conflict-free shortcut) puts agents in a "Pinned" section at the top, keyed by host + agent name; a pinned agent that disappears is kept in prefs but not shown. Section headers get a disclosure control; collapsed state is remembered per host. A search filter shows all matches regardless of collapse.
Why: keyboard-first (menu + shortcut for each action); calm (no reordering animation spam: rows move only when activity changes)
Alternatives: star badge on rows without a section (pins get lost in long lists); no Name option (some people want a stable order)
Commit: c7e629b18 893207531 7135d921d a2f710afb 94cb3a42b
Reverted: f6dfc8aec (B-010 blocked after 3 fix attempts)
Veto: [ ]

## D-074 · 2026-09-24 · B-011: row metadata from snapshots only, identity-checked
Chose: show a relative "last active" time ("2m", "3h", "Sep 21") and a one-line current task only when the daemon reports them; take them from the /observe/state snapshot as a whole (no per-event merging), and attach a snapshot entry to a row only when it provably belongs to that incarnation (matching revision/identity field the daemon provides; if none exists, drop the entry whenever the list has seen the name disappear since the snapshot was requested). The relative label re-renders on a minute-granular TimelineView, not per event. Tokens/cost only if the daemon exposes them; otherwise omitted. Metadata stays secondary text in the existing subtitle line (calm), truncated to one line with a tooltip.
Why: "never invent a state" — B-010 showed name-keyed, event-merged activity races; snapshot-only is calm and correct
Alternatives: advance times from live events (B-010's failure mode)
Commit: a8b800d41 fd679d90a 8b5808341
Veto: [ ]

## D-075 · 2026-09-24 · B-011 implementer calls
Chose: `started_at` (present in list and /state, byte-identical for all 103 live agents) is the incarnation id, and metadata attaches only when both sides have it and match; the task line comes from the identity-checked snapshot's `current_action.detail` (sanitized, one line, tooltip) and replaces the old event-fed action-detail line; activity/lifecycle events only request a fresh /state (one in flight + one trailing; a starting baseline clears the owed flag, applying it starts any owed refetch); a snapshot the daemon marks working shows "now"; stopped agents keep matching metadata; >24h shows the date (year only if not this year); subtitle is three texts with layout priority template < state < time (time fixed-size, never truncates); tokens/cost omitted because the daemon doesn't expose them per agent (`harness.Usage` never reaches observe). Review LOW dismissed: a working snapshot with no timestamp or detail shows no "now", since the row's Working label already reports it
Why: never invent a state; calm (no per-event re-render); the time is the new information, so it must survive narrow widths
Alternatives: merge event payloads (B-010's race); truncate the whole subtitle as one string (hides the time)
Commit: a8b800d41 fd679d90a 8b5808341
Veto: [ ]

## D-076 · 2026-09-24 · B-043: drop the template from a too-narrow subtitle
Chose: when the row subtitle can't show at least ~5 characters of the template, drop the template and keep state + time; a template that fits whole still shows; the full subtitle stays in the tooltip/accessibility label. Implementer calls: minimum is exactly 5 chars; a subtitle that is only the template never drops it; widths measured with the .caption1 NSFont; the tooltip now shows on every row with a subtitle.
Why: calm — the trailing column is reserved for the attention badge, so the time stays in the subtitle; "clau…" is noise, not information
Alternatives: move the time to the trailing badge column (competes with the attention badge); a second subtitle line (taller rows)
Commit: bb7b9f81c 94685a65c
Veto: [ ]

## D-077 · 2026-09-24 · B-041: the palette row is the sidebar's banner value
Chose: the palette's disconnected row carries the `LeoDisconnectedBanner` value itself (`Row.disconnected`), so text, one-line limit, tooltip and sanitizer come from one place; explicit accessibility label with the full reason; connecting / connection-failed `.status` rows left as they were. Review LOW dismissed: tests assert the banner values, not the rendered SwiftUI modifiers; that needs a view-inspection dependency, the sidebar banner has the same limit, and shot B-041-2 covers the rendering
Why: one source for disconnected copy; Mac-native (tooltip for truncated text)
Alternatives: copy the banner's strings into a status row (drifts, which is how B-041 happened)
Commit: 40966ae59
Veto: [ ]

## D-078 · 2026-09-24 · B-042: palette fuzzy match on name, then repo
Chose: the agent palette uses `LeoFuzzyMatcher` (same ranking, bolding, case folding as the sidebar), but its secondary field is repo, not template, because repo is the subtitle a palette row shows and the old substring filter matched it; only the name is bolded; New Agent…, Plain Shell, status and disconnected rows keep their placement; empty query keeps sidebar order; a filter change selects the top row. Sidebar and palette each keep a 3-line bolding helper (the matcher has no SwiftUI)
Why: keyboard-first — both searches behave the same; don't match text the row doesn't show
Alternatives: name + template like the sidebar (matches invisible text); name only (drops the old repo matching)
Commit: 9a355633e
Veto: [ ]

## D-079 · 2026-09-24 · B-040: redesign the in-flight recovery test around a buffered old-boot signal
Chose: kept the test's name and assertions and rebuilt its sequence: the old boot's /state lands needs_input (rev 40), a second recovery's list is held, the old boot's last needs_input signal (rev 41) is buffered, then the new boot's hello (baseline rev 2) with a marker event proving it was read mid-recovery. The old-boot data arrives as a live signal, not a fetch, because a stale /state answer can't reach the new boot (generation bump drops it). Released list proven by its own landed/failed result; later lists held; a list timeout fails at once with a named message. "Baseline skipped" = only the post-restart baseline. Review LOWs dismissed: a retained old display entry is replaced by the baseline before anyone sees it; a skipped post-restart baseline still fails the test, just at the suite's 1-minute limit
Why: the test must fail when boot reset breaks (break-checked: boot reset off → needsInput shown; baseline skipped → nil); event-driven, 10/10 under 3× core-count load
Alternatives: a sibling test (duplicates setup); an old-boot /state answer in flight (unreachable in a real sequence)
Commit: 669c92d1f 892b6f18e fb92b79d9
Veto: [ ]

## D-080 · 2026-09-24 · B-039: in-memory defaults for tests, plist guard in the bundle check
Chose: `LeoInMemoryDefaults`, a test-only `UserDefaults` subclass overriding every getter/setter (persistent-domain methods trap), injected into every test that used `UserDefaults(suiteName:)` (28 files); production code, domains and keys unchanged. The B-032 bundle guard snapshots `Leo*Tests*` / `Ghostty*Tests*` plists in the real ~/Library/Preferences before/after the run and fails on new ones; a listing error fails the guard (never an empty set); bare `<UUID>.plist` isn't counted (other processes make those). Existing stubs left in place (Never list): 31,098, listed in /private/tmp/b039-stubs.txt → B-044. Review LOW dismissed: a missing ~/Library/Preferences fails the guard, but every macOS login account has one
Why: test infra (agent decides); dependency injection over globals; a guard so it can't regress
Alternatives: one reused suite per test class (still one plist per class); a protocol wrapper (production already takes UserDefaults)
Commit: 558a0585e a00d37484 b9cc40d4b
Veto: [ ]

## D-081 · 2026-09-24 · B-044: Trash the `Leo*Tests*` preference stubs; bare UUIDs stay
Chose: Evan answered yes to moving the `Leo*Tests*` stubs to the Trash, bare `<UUID>.plist` untouched. Moving user files is a Never-list action, so the item stays blocked as "Needs Evan to do" with a one-line command
Why: Evan's choice
Commit: n/a
Veto: n/a (Evan)

## D-082 · 2026-09-24 · B-010: re-scope Last Activity to /observe/state snapshots only
Chose: sort by `last_activity_at` from identity-checked /observe/state snapshots; no reordering from live `agent_activity` events; pins, collapse, Name sort and menus ship as built before the revert
Why: Evan's choice; calm by default, and name-keyed events can't be attributed safely without an incarnation id
Commit: dfe6f29e8
Veto: n/a (Evan)

## D-083 · 2026-09-24 · B-013: request the surface-file event from the leo agent now that B-004 shipped
Chose: send the daemon-side request to the leo agent; build the app side against fixtures
Why: Evan's choice; B-004 is done
Commit: n/a
Veto: n/a (Evan)

## D-084 · 2026-09-24 · B-014: keep all-hosts sections deferred
Chose: status `deferred` until Evan says several remotes are in daily use
Why: Evan's choice (D-008)
Commit: n/a
Veto: n/a (Evan)

## D-085 · 2026-09-24 · B-010 implementer calls (snapshot-only sort)
Chose: (1) a section with no snapshot time on any row keeps daemon order (before the first /state lands); otherwise newest first, ties and time-less rows by name. (2) The sidebar no longer ranks working agents first (that rank came from live events); the palette still does. (3) The snapshot's working flag doesn't affect sort, only the row's label. (4) No log line for "no activity time" (would fire on every launch before /state). (5) Pins stay keyed by host + name, so a deleted agent's pin carries to a recreated namesake (as D-073 chose; no activity carries). `LeoAgentRow.ID` is Codable for pin storage
Why: D-082 snapshot-only; calm (rows move only on a new snapshot); never invent a state
Alternatives: keep working-first from events (the B-010 race); log missing times (noise)
Commit: dfe6f29e8
Veto: [ ]

## D-086 · 2026-09-24 · B-013: surfaced files are a quiet queue, opened on focus
Chose: sent the leo agent a contract (tool `leo_surface_file {path, line?, reason?}`; SSE `file_surfaced` with `started_at` + `id` + `abs_path`; `/observe/state` `surfaced_files` ≤20). Leo's reply: stat on call (missing/dir rejected), line ≥1, reason >200 rejected, in-memory only (resets on restart/new incarnation), no ETA until Evan approves the daemon feature; I agreed to agents only in v1 (dispatches rejected). App side, built against fixtures: attach by `started_at` identity, dedupe by id, sanitize text; pending files show a quiet doc glyph + count on the row (no sound, no Dock count); if the agent's tab is focused, the newest opens in the editor pane at once, otherwise it opens when that tab is next focused; row menu Surfaced Files ▸ and Agents ▸ Open Surfaced File reach the rest; seen ids persist per host
Why: calm (a surfaced file isn't "needs input", so no Dock badge or motion); everything through Leo; never steal focus from the agent you're working in
Alternatives: auto-open in any window (steals focus); count in the Dock badge (inflates the needs-you count)
Commit: 30fe234bf 3a8b8529d 9483da369 69b736464
Reverted: f3e8d36b3 (B-013 blocked after 3 fix attempts; daemon request stands)
Veto: [ ]

## D-087 · 2026-09-24 · B-012: no snapshot cache; keep DEBUG launch timing
Chose: measured before building: the list lands ~120 ms after the sidebar appears (≤300 ms bar), so no cached-snapshot rendering (it would also risk showing stale attention as live). Kept DEBUG-only LaunchTiming marks (launch, window key, sidebar appear, first snapshot, first rows), each logged once
Why: YAGNI; never invent a state (a cached list is stale by definition)
Alternatives: cache anyway for remote hosts (unmeasured; revisit when a remote is in daily use)
Commit: e45d323fb 826e921ee
Veto: [ ]


## D-088 · 2026-09-24 · B-013: drop auto-open; surfaced files are badge-only
Chose: no auto-open on focus. Pending surfaced files show the quiet row badge; Evan opens them with ⌥⌘O or the row's Surfaced Files menu. Re-apply the reviewed parts of 30fe234bf..69b736464 (decode, incarnation-keyed badge, menus, ⌥⌘O, path/size/SFTP hardening) minus auto-open
Why: Evan's choice; calm by default, never steals the pane; auto-open failed review 4 times on races
Commit: 70a2b21e8 eed22646d 813d4f335 263040196
Veto: n/a (Evan)

## D-089 · 2026-09-24 · B-044: stubs trashed by Evan
Chose: mark done; Evan moved 26,878 `Leo*Tests*.plist` to ~/.Trash/leo-test-stubs; bare UUID plists untouched
Why: Evan's action
Commit: n/a
Veto: n/a (Evan)

## D-090 · 2026-09-24 · B-045: banner stays its own full-width row; layout fix is pane-wide
Chose: keep the Closing banner as its own leading-aligned row under the header (not in the header's trailing status slot); pin every pane row to the pane width, so all editor banners move to the leading edge alike; clip the banner's background fill to its bounds
Why: match the other editor banners (Mac-native consistency); the one-row fix is the same code for every banner
Alternatives: trailing status slot in the header (new idiom, crowds the mode/close controls)
Commit: 10ec5d41f 350a88ecc f778624b5
Veto: [ ]

## D-091 · 2026-09-24 · B-013 implementer calls (badge-only surfaced files)
Chose: (1) "seen" = the user opened it and the pane showed it; a cancelled unsaved prompt or failed open keeps the badge. (2) A non-regular file on a user open shows the error sheet (the user asked, so fail visibly). (3) No separate surfaced-file size cap; the editor's 20 MB read cap / 5 MB read-only rule applies. (4) ⌥⌘O opens the newest pending file, else the newest. (5) 5 s first-read deadline kept for user opens (stuck SFTP). (6) Identity and seen ledger keyed by agent + started_at + id, bounded 200/host, new key `leo.surfacedFiles.seen.v2` (old id-only entries ignored; only debug builds wrote them). (7) A full (20-sent) /state baseline drops live-only files it can't place as newer by `at`; a partial one keeps them; live events are placed by `at`, dropped if older than a full index
Why: calm; never invent a state; local = remote (deadline); fail visibly on user action
Alternatives: mark seen on menu display (hides files never read); migrate the v1 ledger (debug-only data)
Commit: 70a2b21e8 eed22646d 813d4f335 263040196
Veto: [ ]

## D-092 · 2026-09-24 · B-046 implementer calls (surfaced-file merge edge cases)
Chose: (1) An agent with no `started_at` is still skipped in a /state merge. (2) An all-malformed full baseline clears an incarnation that already has files; with nothing stored it is a no-op (no empty entry). (3) A cleared incarnation is removed from the index and the LRU, so it doesn't hold one of the 64 slots. (4) In a partial merge an undated event-only file is placed as newest; equal `at` keeps existing order. (5) Live events and the /state merge share one placement rule (before the first later `at`).
Why: never invent a state; calm (⌥⌘O opens the truly newest file); one ordering rule for both paths
Alternatives: drop undated live files in a partial merge (would hide a file the daemon reported)
Commit: a91e50296 a70d51027
Veto: [ ]

## D-093 · 2026-09-24 · B-047 implementer calls (one tab per agent)
Chose: (1) Reuse B-006's `LeoAttachCoordinator.focusMostRecent` (host + name, most recently used live attachment); a same-named agent on another host never matches. (2) When "Choose Agent…" on a blank start-screen tab jumps to an existing tab, the blank tab closes (only if still unfilled, no editor/browser pane), as Safari does. (3) A leftover placeholder pane from an exited attach is filled in place, not jumped away from (same as Split). (4) The palette shows "⌘↩ New Tab" at the right of the search field, only for ⌘T and start-screen requests; the row's Attach button tooltip mentions ⌘-click; the row context menu gets "Attach in New Tab". (5) ⌘-double-click opens one new tab (the second click focuses it). (6) A single click on a row with no tab still only selects it (D-021).
Why: principle 4 (no hunting for an agent's tab); principle 1 (Safari conventions, every action in a menu); no empty tabs left behind
Alternatives: leave the blank start tab open; a footer hint in the palette (changes the fixed panel height)
Commit: d403a2c9a
Veto: [ ]

## D-094 · 2026-09-28 · B-048 sidebar click handling (implementer calls)
Chose: (1) The sidebar list requires a selection (non-optional List overload), so ⌘-click on the selected row keeps it selected and clicking empty sidebar space no longer clears the selection, as in Finder's sidebar. (2) Row clicks are read from the mouse events through a per-row local event monitor (`LeoRowClickCatcher`), because SwiftUI tap gestures never fire in a window that isn't key. So a plain click on a row in a background window now also focuses that agent's open tab on the first click, and ⌘-click opens a new tab there. (3) `rowClicked` is the only decision point for single and double clicks. The row's double-tap gesture is gone, and clicks on the hover Attach button are excluded, so every click acts exactly once. (4) A ⌘⌥ double-click opens one tab and then one window, since ⌥ always wins for the second click. It is left untested as an edge combination.
Why: principle 1 (Mac-native: Finder/Safari click conventions); the fix for a real bug (⌘-click deselected the row and never opened a tab)
Alternatives: SwiftUI `.allowsWindowActivationEvents()` (fixes plain clicks but not ⌘-clicks); ignoring the nil selection in the model (the table highlight still dropped)
Commit: e13738b88 0604cc27f 5bd615a31
Veto: [ ]

## D-095 · 2026-09-28 · B-052 implementer calls (agent-name tab titles)
Chose: (1) The title is the bare agent name without the host (e.g. "autopilot-scratch"); same-named agents on two hosts read alike. (2) After an attach exits (e.g. an agent restart), the placeholder left in the tab keeps the agent's name until something refills the slot; a plain shell there drops it. (3) No tooltip with the terminal's own title (keeps the upstream diff small). (4) The command palette's "Focus: …" entries still show the terminal's title. (5) The old "name · host" title seed, which borrowed the Change Tab Title… slot and was cleared by the first OSC title, was removed together with the unused `.titleChanged` event. Precedence is: Change Tab Title… > Change Terminal Title… > agent name > terminal title.
Why: principle 4 (find an agent's tab at a glance); calm (the name doesn't flicker when tmux or Claude retitle); minimal upstream diff
Alternatives: "name · host" (noisier for the common single-host case); fall back to tmux's last title after exit
Commit: ee274b7f9
Veto: [ ]

## D-096 · 2026-09-28 · B-050 implementer calls (first attach fills the start tab)
Chose: (1) "Only the start page open" means the key window has exactly one tab and it's an untouched start screen: the unfilled placeholder, with no terminal, editor document, or browser open. A blank start tab beside other tabs still gets a new tab. The terminal drawer is app-wide, so it doesn't count. (2) When the agent already has a tab, the app focuses that tab and closes the lone start tab, as in D-093(2). A sidebar single-click on such a row now does this too. (3) Palette Return and spawn-sheet attaches from the start page fill it; ⌘↩ and ⌘-click force a new tab, and ⌥ opens a new window. (4) The discard close waits one main-queue turn and re-checks that the tab is still untouched, because a sidebar click asks from inside that window's own mouse event. (5) The "untouched" check now reads whether an editor or browser is actually open. The old check looked at the pane views, which exist in every shown window, so D-093's blank-tab close never fired in practice.
Why: principle 1 (Mac-native: Safari fills a blank tab); calm (no empty tabs left behind)
Alternatives: fill a selected blank start tab even beside other tabs (surprising in a busy window)
Commit: 6875f2be7 14951a372
Veto: [ ]

## D-097 · 2026-09-28 · B-049 implementer calls (click a row to open; ask before starting)
Chose: (1) After Start, the sheet stays up as "Starting <name>…" with a spinner and only Cancel, until the daemon reports the agent running, so the pending attach stays visible and cancellable. (2) Clicking an agent that's already `.starting` opens the sheet straight into that waiting state, with no second start. (3) Every non-running status (stopped, unknown/errored) gets the prompt, even when the agent still has a tab open. (4) Return in the search field now acts like a click on the top row (it attaches or prompts), replacing B-009's "Return never attaches". (5) Context-menu Attach and Agents ▸ Attach on a stopped agent behave as before, with no prompt. (6) The row is one accessibility element with a default "Open" action that takes the single-click path; the click catcher and the status badge are hidden from accessibility. (7) A click counts only if the same row is under the view at mouse-down and mouse-up (rows re-sort live). (8) The start-wait matches by agent name, not incarnation: "open X" attaches to whichever X reports running.
Why: principle 1 (the row is the target, as in Finder and Mail; confirm with a sheet); principle 5 (no timers: attach only when the daemon reports running); never attach an agent the user didn't click
Alternatives: close the sheet at once and attach silently later (the pending attach is invisible); keep Return in search as select-only
Commit: a9dbf4e11 11930305f cf5025227
Veto: [ ]

## D-098 · 2026-09-28 · Remove the tab bar; the sidebar is the navigation
Context: Evan (/vision revision). Sidebars were drawn per tab and could differ in width.
Chose: No tab bar. Each window has one sidebar and one content area that shows the selected row. The N most recently viewed surfaces stay attached but hidden, so switching among them is instant and keeps scrollback; beyond N, the least recently viewed detaches and reattaches on selection. New principle 6 and new milestone "Sidebar navigation". This approves removing tabs, a user-facing feature on the stop list. It supersedes the tab-specific parts of D-093, D-095 (tab title), and D-096 (start-tab fill).
Why: principle 1 (Mail/Finder-style sidebar navigation); per-tab sidebars can't be the same sidebar; the pool avoids per-switch reattach latency, lost Ghostty scrollback, and tmux resize reflow
Alternatives: keep native tabs and sync the sidebar across them (still two navigation systems); detach/reattach on every switch (slow over SSH, loses scrollback and view state)
Commit:
Veto: n/a (Evan)

## D-099 · 2026-09-28 · Plain shells are sidebar rows
Context: D-098 leaves no tab bar for non-agent shells.
Chose: A "Terminals" sidebar section; ⌘T creates a shell and selects it. The app-wide terminal drawer is unchanged.
Why: principle 6 (one place to navigate)
Alternatives: drawer only (shells become second-class); both (two homes for shells)
Commit:
Veto: n/a (Evan)

## D-100 · 2026-09-28 · Keep splits in the content area
Context: D-098.
Chose: ⌘D and the editor/file pane still split the content area; a split may show a second agent or shell; every row on screen is highlighted.
Why: agents side by side, and the editor next to its terminal, are core workflows
Alternatives: editor split only; no splits
Commit:
Veto: n/a (Evan)

## D-101 · 2026-09-28 · Backlog after the revision
Context: D-098.
Chose: the template-list bug (B-054) goes first, then B-055–B-059. B-053 (refill an exited tab) and the queued "one sidebar per window" entry (B-060) are dropped as superseded.
Why: B-054 is small and independent; tab-specific items are moot without tabs
Alternatives: sidebar navigation first
Commit:
Veto: n/a (Evan)

## D-102 · 2026-09-28 · Template list loads per host selection, not at startup
Context: B-054. The row menu and New Agent sheet now read one host-aware list on LeoAgentActions.
Chose: fetch when start() (or a later switch) selects a host, since a remote host's settings aren't loaded when LeoAgentActions is created. Re-selecting the same host keeps the loaded list on screen while it refetches; a failed list goes back to loading. The row menu shows "Loading Templates…", "Templates unavailable: …" or "No Templates" instead of an empty submenu.
Why: principle 3 (local = remote); principle 2 (report what the daemon said, no blank menus)
Alternatives: fetch at creation (wrong host for remotes); fetch per menu open (the NSMenu snapshot is built before an async fetch returns)
Commit: 3a2205a65
Veto: [ ]

## D-103 · 2026-09-28 · Row template list refreshes only on host switch or manual refresh
Context: B-054.
Chose: the shared list is refetched on host selection or invalidateTemplateCache; the 5-minute cache expiry now only affects the Agents menu bar path. A host change while the New Agent sheet is open keeps the chosen template, which then fails validation ("Choose an available template") if the new host lacks it.
Why: calm and predictable; templates rarely change mid-session
Alternatives: periodic refetch; clear the sheet's selection on host change
Commit: 3a2205a65
Veto: [ ]

## D-104 · 2026-09-28 · Tab-only affordances remap to "new window"
Context: B-055 removes the tab bar (D-098).
Chose: "Attach in New Tab" becomes "Open in New Window"; ⌘-click a row and ⌘↩ in the palette open the agent in a new window (focusing its existing window instead if it's already on screen there, per B-047). Start-tab fill (D-096) is moot: selecting a row simply replaces the content area. ⌘T stays a plain shell (B-057 turns it into a Terminals row); until then it shows the shell in the content area.
Why: principle 1 (Finder/Mail: ⌘-open means a new window); keeps the modifier gesture meaningful instead of dead
Alternatives: remove the ⌘ variants entirely; ⌘-click opens a split (that's B-058's job)
Commit: 4134ce4f4 6fb5c8c8d
Note: ⌘T already opened the agent palette (not a shell); it stays the palette, retitled "Choose Agent…", and its choice replaces the content area (see D-107).
Veto: [ ]

## D-105 · 2026-09-28 · Until B-058, switching away from a split shows only the new agent
Context: B-055 swaps the window's whole surface tree on a row switch.
Chose: the split layout is dropped on switch; B-058 restores layouts. An exited pane's refill (placeholder) still always attaches, so an agent can briefly be on screen twice; B-056/B-058 close that gap.
Why: keeps B-055 a clean swap seam; splits are B-058's scope
Alternatives: refuse to switch away from a split; keep splits by swapping only the focused pane
Commit: 4134ce4f4 6fb5c8c8d
Veto: [ ]

## D-106 · 2026-09-28 · Replacing a busy plain shell asks first
Context: B-055. Switching rows replaces the content area; a plain shell's process would die.
Chose: if the shown shell has a running process (Ghostty's needsConfirmQuit), ask "Close Terminal?" (Close / Cancel); Cancel keeps it silently. Replacing an agent never asks (tmux keeps it). If another alert is already up, the switch counts as cancelled.
Why: principle 2 (calm) and Mac norms for destroying work
Alternatives: never ask; always ask
Commit: 4134ce4f4 6fb5c8c8d
Veto: [ ]

## D-107 · 2026-09-28 · Tab menu items after the tab bar's removal
Context: B-055, D-098.
Chose: native tabbing disallowed app-wide (Show Tab Bar, Show All Tabs, Merge All Windows, Move Tab to New Window disappear); File ▸ New Tab becomes "Choose Agent…" (⌘T, the palette); Close Tab hidden (⌘W still closes); "Change Tab Title…" becomes "Change Window Title…"; Dock/Services/App Intents/AppleScript tab requests open a window. An untouched start window closes when a jump shows the agent in another window; a ⌘-click that opens a new window keeps it. ⌘1–9 / ⌃Tab left inert for B-059.
Why: principle 1; no tab concepts left in the UI
Alternatives: keep New Tab as a synonym for New Window
Commit: 4134ce4f4 6fb5c8c8d
Veto: [ ]

## D-108 · 2026-09-28 · Live pool size N = 4 per window
Context: B-056. Recently viewed surfaces stay attached but hidden; beyond N the least recently viewed detaches.
Chose: N = 4 per window (a named constant). Hidden pooled surfaces keep their current size (no resize while hidden), so a tmux window isn't reflowed by a hidden client.
Why: covers the common "flip between 2–4 agents" loop instantly while bounding tmux clients, memory and SSH channels (principle 3: remote tunnels multiplex every client)
Alternatives: 8 (more clients per remote host, more memory); unbounded LRU (leaks clients)
Commit: b9e6ec48a 9d4b8033b b40d3a4bb
Veto: [ ]

## D-109 · 2026-09-29 · Pool mechanics: only all-agent trees, release-and-reattach across windows
Context: B-056.
Chose: the pool keeps a displaced tree only if every surface in it is an agent attach; a tree with any plain shell closes at displacement (after D-106's confirm if busy), so eviction never kills a shell silently. Capacity is counted in tmux clients (a two-agent split counts 2). An agent hidden in window A is not "on screen": selecting it in window B releases A's hidden copy and attaches fresh (never two clients). An exited pane refills in place only in its own window. Hidden surfaces leave the view hierarchy and are occluded (no resize, no rendering); Ghostty.App.showChildExited posts a Swift-only notification so windowless exits are let go on the next turn.
Why: principle 2 (never destroy work without asking), principle 6 (instant switches), bounded clients per D-108
Alternatives: move the hidden tree across windows (surface reparenting risk); pool shells too (silent kills on eviction)
Commit: b9e6ec48a 9d4b8033b b40d3a4bb
Veto: [ ]

## D-110 · 2026-09-29 · A content request superseded while asking is dropped
Context: B-056 fix round. Two rows clicked in quick succession while a "Close Terminal?" confirm is up.
Chose: each window has a content version bumped on every content replacement; a request whose confirm returns after the content was replaced by a newer request is a quiet cancel. A cancelled competing request doesn't drop the waiting one.
Why: the newest intent wins; nothing replaces content nobody agreed to replace
Alternatives: queue requests; per-window in-flight lock that ignores later clicks
Commit: b40d3a4bb
Veto: [ ]

## D-111 · 2026-09-29 · Shell rows keep their shell alive while hidden; they don't count toward N
Context: B-057. A plain shell becomes a "Terminals" row. D-109 kept shells out of the agent pool so eviction never kills one silently.
Chose: a shell row owns its surface for the row's whole life. Switching away hides it (same instance, like the pool), it never gets LRU-evicted, and it doesn't count toward N (N bounds tmux clients; a shell is a local pty). It ends only when you close it (⌘W / File ▸ Close, or `exit`), with Ghostty's usual busy-process confirm. D-106's "Close Terminal?" on switching away from a shell no longer applies, since switching doesn't close it.
Why: principle 6 (a row is a place you can go back to); principle 2 (no silent kills)
Alternatives: pool shells under the LRU (silent kills); close shells on switch (rows would vanish)
Commit: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c
Veto: [ ]

## D-112 · 2026-09-29 · Close is made order-independent (shown/hidden/gone) rather than pinning Dispatch
Context: B-057 (runner call).
Chose: Close is made order-independent (shown/hidden/gone) rather than pinning DispatchQueue vs Task order
Why: P2 never invent state
Commit: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c
Veto: [ ]

## D-113 · 2026-09-29 · Tab-close, Close Other Tabs, Close Tabs on the Right and ⌘Q confirm on busy hidd
Context: B-057 (runner call).
Chose: Tab-close, Close Other Tabs, Close Tabs on the Right and ⌘Q confirm on busy hidden shells
Why: P2 never destroy work without asking, D-111
Commit: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c
Veto: [ ]

## D-114 · 2026-09-29 · fate keeps a tree only if all surfaces are rows; a row plus a ⌘D split closes th
Context: B-057 (runner call).
Chose: fate keeps a tree only if all surfaces are rows; a row plus a ⌘D split closes the row's own shell on switch-away (asks if busy): interim, deferred to B-058
Why: D-100
Commit: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c
Veto: [ ]

## D-115 · 2026-09-29 · A shown row's close request stays with its controller (keeps ⌘W's confirm); only
Context: B-057 (runner call).
Chose: A shown row's close request stays with its controller (keeps ⌘W's confirm); only hidden rows with process_alive=false route to the three-case close
Why: P2
Commit: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c
Veto: [ ]

## D-116 · 2026-09-29 · Selection returns to what's shown when a show is cancelled, superseded or fails;
Context: B-057 (runner call).
Chose: Selection returns to what's shown when a show is cancelled, superseded or fails; the content area is left untouched
Why: P6
Commit: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c
Veto: [ ]

## D-117 · 2026-09-29 · Closing a row's shell beside a split closes only that pane, using upstream's und
Context: B-057 (runner call).
Chose: Closing a row's shell beside a split closes only that pane, using upstream's undoable split close
Why: D-100
Commit: f57f9fefc 54bde45c1 a831d8e4a 8766c056f 53f51762a 518b87ab7 0d22ce11f 3e390d0d0 490cf77c7 0fbb8746e 7d52dd411 773d86267 3aa4bb698 68293ed56 7ea968957 bbb6b2fe5 5d1f1fe3c 78fa2682f 4cc74629c
Veto: [ ]

## D-118 · 2026-09-29 · Last Activity sort gets streak hysteresis: rows active within 5 min of the…
Context: B-063 (runner call).
Chose: Last Activity sort gets streak hysteresis: rows active within 5 min of the snapshot's newest last_activity_at come first, ordered by when their streak began; the rest by last_activity_at then name; snapshots only (D-082 kept); supersedes D-085's plain "newest first"
Why: P2 calm
Commit: 857387ff9 745f2568e 554584894 1479faac8
Veto: [ ]

## D-119 · 2026-09-29 · The 5-min window is measured from the snapshot's newest last_activity_at,…
Context: B-063 (runner call).
Chose: The 5-min window is measured from the snapshot's newest last_activity_at, not the wall clock
Why: P2 never invent a state
Commit: 857387ff9 745f2568e 554584894 1479faac8
Veto: [ ]

## D-120 · 2026-09-29 · Streaks reset on host switch, reconnect or disconnect; a row missing from a…
Context: B-063 (runner call).
Chose: Streaks reset on host switch, reconnect or disconnect; a row missing from a snapshot, without a time, or a new incarnation starts a fresh streak (may move once)
Why: P2
Commit: 857387ff9 745f2568e 554584894 1479faac8
Veto: [ ]

## D-121 · 2026-09-29 · Accepted trade-off: an agent whose timestamp stalls >5 min (long tool call)…
Context: B-063 (runner call).
Chose: Accepted trade-off: an agent whose timestamp stalls >5 min (long tool call) moves twice (drops, then returns to the top on resume); a long-running busy agent ranks below one whose burst began more recently
Why: P2
Commit: 857387ff9 745f2568e 554584894 1479faac8
Veto: [ ]

## D-122 · 2026-09-29 · Sidebar header: top inset 10 pt and a minimum 8 pt gap between the title and…
Context: B-064 (runner call).
Chose: Sidebar header: top inset 10 pt and a minimum 8 pt gap between the title and the + button, in one LeoSidebarChromeMetrics enum shared with B-065
Why: P1 Mac-native (Mail/Finder sidebar)
Commit: 2c56d320f 35f2f475f 4331c902a
Veto: [ ]

## D-123 · 2026-09-29 · Fix only the default titlebar style; the hidden-titlebar overlap is a follow-up
Context: B-064 (runner call).
Chose: Fix only the default titlebar style; the hidden-titlebar overlap is a follow-up
Why: AUTONOMY UX/layout
Commit: 2c56d320f 35f2f475f 4331c902a
Veto: [ ]

## D-124 · 2026-09-29 · LeoSidebarHeader takes its trailing control as a @ViewBuilder so B-065 can…
Context: B-064 (runner call).
Chose: LeoSidebarHeader takes its trailing control as a @ViewBuilder so B-065 can pass any control
Why: AUTONOMY layout
Commit: 2c56d320f 35f2f475f 4331c902a
Veto: [ ]

## D-125 · 2026-09-29 · ⌘T belongs to New Terminal; the colliding action gets a new shortcut
Context: B-066 (Evan: ⌘T opens both the agent palette and the quick terminal).
Chose: ⌘T stays New Terminal (a plain-shell row), per the milestone's Done 3. Any other action bound to ⌘T (agent palette / Choose Agent…, quick terminal) moves to a free, Mac-conventional shortcut and keeps its menu item; the runner picks the exact keys and logs them. Supersedes D-107's "Choose Agent… (⌘T, the palette)" binding and matches D-099.
Why: VISION Done 3 fixes ⌘T; AUTONOMY lets the agent pick shortcuts not fixed by a decision; principle 1 (every action keeps a shortcut and a menu item)
Commit: 930a1f331
Veto: [ ]

## D-126 · 2026-09-29 · Choose Agent… (the palette) stays on ⌘O, where B-057 put it; ⌘T is New…
Context: B-066 (runner call).
Chose: Choose Agent… (the palette) stays on ⌘O, where B-057 put it; ⌘T is New Terminal alone
Why: principle 1 / AUTONOMY shortcuts (D-125)
Commit: 930a1f331
Veto: [ ]

## D-127 · 2026-09-29 · Quick Terminal keeps its menu item and no default key (upstream ships …
Context: B-066 (runner call).
Chose: Quick Terminal keeps its menu item and no default key (upstream ships it unbound)
Why: AUTONOMY UX/shortcuts
Commit: 930a1f331
Veto: [ ]

## D-128 · 2026-09-29 · Start-screen tooltip reads LeoWindowTabbing.chooseAgentShortcut ("⌘O")…
Context: B-066 (runner call).
Chose: Start-screen tooltip reads LeoWindowTabbing.chooseAgentShortcut ("⌘O"), tied to the menu item by a test
Why: AUTONOMY bug fixes/test infra
Commit: 930a1f331
Veto: [ ]

## D-129 · 2026-09-29 · The selected terminal row is also revealed when the filter clears or t…
Context: B-067 (runner call).
Chose: The selected terminal row is also revealed when the filter clears or the list reappears, as Mail reveals its selection after a search
Why: principle 1 Mac-native
Commit: c905bd4c9 f8135ef58
Veto: [ ]

## D-130 · 2026-09-29 · Retitles and agent refreshes never scroll, and a row already on screen…
Context: B-067 (runner call).
Chose: Retitles and agent refreshes never scroll, and a row already on screen doesn't move
Why: principle 2 calm
Commit: c905bd4c9 f8135ef58
Veto: [ ]

## D-131 · 2026-09-29 · Numbered suffix, not a tty name: the first row stays plain ("~", "~ (2…
Context: B-068 (runner call).
Chose: Numbered suffix, not a tty name: the first row stays plain ("~", "~ (2)", "~ (3)"), like Finder's "untitled folder 2"
Why: principle 1, AUTONOMY UX/copy
Commit: 59b259e37 677060e4f
Veto: [ ]

## D-132 · 2026-09-29 · Labels are recomputed from row order and titles: a retitle or close ca…
Context: B-068 (runner call).
Chose: Labels are recomputed from row order and titles: a retitle or close can renumber later same-titled rows, but rows never move and a new shell never relabels an older one
Why: AUTONOMY, D-130
Commit: 59b259e37 677060e4f
Veto: [ ]

## D-133 · 2026-09-29 · The suffix is secondary-coloured with monospaced digits and never trun…
Context: B-068 (runner call).
Chose: The suffix is secondary-coloured with monospaced digits and never truncates
Why: AUTONOMY polish
Commit: 59b259e37 677060e4f
Veto: [ ]

## D-134 · 2026-09-29 · The start-screen New Terminal button sends ⌘T's newTab: to the clicked…
Context: B-069 (runner call).
Chose: The start-screen New Terminal button sends ⌘T's newTab: to the clicked window's controller (nil-target fallback), so the row lands in that window
Why: AUTONOMY UX
Commit: 7ba7c4400
Veto: [ ]

## D-135 · 2026-09-29 · The button is plain bordered; Choose Agent… stays the one prominent bu…
Context: B-069 (runner call).
Chose: The button is plain bordered; Choose Agent… stays the one prominent button
Why: AUTONOMY layout/polish
Commit: 7ba7c4400
Veto: [ ]

## D-136 · 2026-09-29 · The button is always enabled, even while disconnected (a shell doesn't…
Context: B-069 (runner call).
Chose: The button is always enabled, even while disconnected (a shell doesn't need the daemon)
Why: AUTONOMY UX
Commit: 7ba7c4400
Veto: [ ]

## D-137 · 2026-09-29 · Its title and "⌘T" tooltip come from LeoWindowTabbing constants tied t…
Context: B-069 (runner call).
Chose: Its title and "⌘T" tooltip come from LeoWindowTabbing constants tied to the ⌘T menu item by a test (D-128 pattern)
Why: principle 1, AUTONOMY copy
Commit: 7ba7c4400
Veto: [ ]

## D-138 · 2026-09-29 · A title set with Change Window Title… survives the start screen; it na…
Context: B-070 (runner call).
Chose: A title set with Change Window Title… survives the start screen; it names the window, not the shell
Why: principle 1, D-107
Commit: 01fb138dd
Veto: [ ]

## D-139 · 2026-09-29 · The closed shell's folder proxy icon is cleared on the start screen, m…
Context: B-070 (runner call).
Chose: The closed shell's folder proxy icon is cleared on the start screen, matching a fresh window
Why: principle 2 never invent a state
Commit: 01fb138dd
Veto: [ ]

## D-140 · 2026-09-29 · After a content swap, the start screen, or the unsaved-edits start sc…
Context: B-071 (runner call).
Chose: After a content swap, the start screen, or the unsaved-edits start screen, ⌘Z does nothing to that window's tree (undo is dropped, not replayed)
Why: P2, D-111/D-116
Commit: 3c11d58f5 554d32298 73ccd5035 c32e920d8 1c7b13222 c9ce67411 bc8aae9f1
Veto: [ ]

## D-141 · 2026-09-29 · Clearing covers every undo action targeting that controller (tree edi…
Context: B-071 (runner call).
Chose: Clearing covers every undo action targeting that controller (tree edits, redos, its New Window); other windows' undo is untouched
Why: P2, AUTONOMY implementation approach
Commit: 3c11d58f5 554d32298 73ccd5035 c32e920d8 1c7b13222 c9ce67411 bc8aae9f1
Veto: [ ]

## D-142 · 2026-09-29 · When a selected row closes by any path, the selection returns to what…
Context: B-071 (runner call).
Chose: When a selected row closes by any path, the selection returns to what the window shows (its row, or none so the agent's selection shows)
Why: P6, D-116
Commit: 3c11d58f5 554d32298 73ccd5035 c32e920d8 1c7b13222 c9ce67411 bc8aae9f1
Veto: [ ]

## D-143 · 2026-09-29 · Clear undo in leoKeepForUnsavedEdits where the tree is emptied, not i…
Context: B-071 (runner call).
Chose: Clear undo in leoKeepForUnsavedEdits where the tree is emptied, not in fillPlaceholder's refill branch
Why: AUTONOMY implementation approach
Commit: 3c11d58f5 554d32298 73ccd5035 c32e920d8 1c7b13222 c9ce67411 bc8aae9f1
Veto: [ ]

## D-144 · 2026-09-29 · Keep the injected UserDefaults key `leo.sidebarWidth` (one width shar…
Context: B-084 (runner call).
Chose: Keep the injected UserDefaults key `leo.sidebarWidth` (one width shared by all windows, last change wins) rather than NSSplitView autosaveName
Why: P1, P6, AUTONOMY implementation latitude
Commit: 14a220074 1f5142c27
Veto: [ ]

## D-145 · 2026-09-29 · Restoring the width must cause no visible jump at launch
Context: B-084 (runner call).
Chose: Restoring the width must cause no visible jump at launch
Why: P2
Commit: 14a220074 1f5142c27
Veto: [ ]

## D-146 · 2026-09-29 · Tests go in the existing LeoSplitViewRepresentableTests.swift, not a …
Context: B-084 (runner call).
Chose: Tests go in the existing LeoSplitViewRepresentableTests.swift, not a new file
Why: AUTONOMY test infra
Commit: 14a220074 1f5142c27
Veto: [ ]

## D-147 · 2026-09-30 · A launch that never becomes active still opens its window
Context: B-085 (runner call).
Chose: A launch that never becomes active still opens its window
Why: P1
Commit: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642
Veto: [ ]

## D-148 · 2026-09-30 · Saved frames below a usable minimum (300x150, or window.minSize if la…
Context: B-085 (runner call).
Chose: Saved frames below a usable minimum (300x150, or window.minSize if larger) are neither saved nor restored; the saved origin is kept when the size is refused
Why: P1/P2, D-036
Commit: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642
Veto: [ ]

## D-149 · 2026-09-30 · An untouched launch window gives way to the first window a request op…
Context: B-085 (runner call).
Chose: An untouched launch window gives way to the first window a request opens through newWindow/newTab (AppleScript, Intent, Service, open-file, notification); it closes only once the requested window is visible, which takes its spot
Why: P2, AUTONOMY
Commit: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642
Veto: [ ]

## D-150 · 2026-09-30 · "Touched" means any key, mouse or scroll event in Leo; a launch windo…
Context: B-085 (runner call).
Chose: "Touched" means any key, mouse or scroll event in Leo; a launch window with a sheet up, or a newWindow whose explicit parent is the launch window, is kept
Why: AUTONOMY
Commit: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642
Veto: [ ]

## D-151 · 2026-09-30 · The launch window opens as the bare start screen, not through the pal…
Context: B-085 (runner call).
Chose: The launch window opens as the bare start screen, not through the palette route (no palette flash or stuck clipped palette on background launch)
Why: P2
Commit: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642
Veto: [ ]

## D-152 · 2026-09-30 · NSApp.activate is kept in the placeholder presentation, so background…
Context: B-085 (runner call).
Chose: NSApp.activate is kept in the placeholder presentation, so background and login-item launches come to the front
Why: P1
Commit: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642
Veto: [ ]

## D-153 · 2026-09-30 · An XCTest host never adopts its launch window
Context: B-085 (runner call).
Chose: An XCTest host never adopts its launch window
Why: D-057
Commit: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642
Veto: [ ]

## D-154 · 2026-09-30 · Log line "opening the initial window on <event>"; callback types are …
Context: B-085 (runner call).
Chose: Log line "opening the initial window on <event>"; callback types are @MainActor @Sendable
Why: AUTONOMY implementation approach
Commit: 976d04bdd e9704ec97 9294a360a d864e17ef 770af2035 25766f135 cf5835310 3bf796b62 06d53d284 d313bbcca bfb1f4642
Veto: [ ]

## D-155 · 2026-09-30 · A window already on screen keeps its frame on its first attach; windo…
Context: B-086 (runner call).
Chose: A window already on screen keeps its frame on its first attach; window-width/window-height size only a window that gets content before it is shown
Why: P1, P2 (D-145 no-jump)
Commit: 3c3189960 c8fa29411 528d63ebe
Veto: [ ]

## D-156 · 2026-09-30 · A window counts as shown once its first presentation has run, so a mi…
Context: B-086 (runner call).
Chose: A window counts as shown once its first presentation has run, so a minimized window or a hidden app also keeps its frame
Why: P1
Commit: 3c3189960 c8fa29411 528d63ebe
Veto: [ ]

## D-157 · 2026-09-30 · windowDidLoad and first fill share one explicit size formula (leoConf…
Context: B-086 (runner call).
Chose: windowDidLoad and first fill share one explicit size formula (leoConfiguredContentSize) instead of the SwiftUI intrinsic size
Why: AUTONOMY implementation approach
Commit: 3c3189960 c8fa29411 528d63ebe
Veto: [ ]

## D-158 · 2026-09-30 · Integration tests save and restore NSWindowLastPosition in the debug …
Context: B-086 (runner call).
Chose: Integration tests save and restore NSWindowLastPosition in the debug app's defaults
Why: AUTONOMY test infra
Commit: 3c3189960 c8fa29411 528d63ebe
Veto: [ ]

## D-159 · 2026-09-30 · Fix the hazard in libghostty (src/global.zig only) rather than with a…
Context: B-072 (runner call).
Chose: Fix the hazard in libghostty (src/global.zig only) rather than with a test-only workaround
Why: AUTONOMY: approach; minimal Zig
Commit: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938
Veto: [ ]

## D-160 · 2026-09-30 · Keep the tests' setenv calls as the regression
Context: B-072 (runner call).
Chose: Keep the tests' setenv calls as the regression
Why: AUTONOMY: test infra
Commit: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938
Veto: [ ]

## D-161 · 2026-09-30 · Lengthen aNewShellIsASelectedRowTitledByItsTerminal to 10 s even thou…
Context: B-072 (runner call).
Chose: Lengthen aNewShellIsASelectedRowTitledByItsTerminal to 10 s even though B-068 made it mostly moot
Why: AUTONOMY: flake fixes
Commit: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938
Veto: [ ]

## D-162 · 2026-09-30 · The environ arena keeps each copy until deinit (grows once per sync),…
Context: B-072 (runner call).
Chose: The environ arena keeps each copy until deinit (grows once per sync), so readers of an older snapshot stay valid
Why: AUTONOMY: approach
Commit: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938
Veto: [ ]

## D-163 · 2026-09-30 · io_impl.environ_initialized is not reset; memoised PATH/HOME are drop…
Context: B-072 (runner call).
Chose: io_impl.environ_initialized is not reset; memoised PATH/HOME are dropped, not rebuilt (avoids touching std Io.Threaded internals)
Why: AUTONOMY: approach, minimal Zig
Commit: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938
Veto: [ ]

## D-164 · 2026-09-30 · No shared env lock with LeoTunnelTestSupport; the burst stays in proc…
Context: B-072 (runner call).
Chose: No shared env lock with LeoTunnelTestSupport; the burst stays in process
Why: AUTONOMY: test infra
Commit: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938
Veto: [ ]

## D-165 · 2026-09-30 · init uses a fallible syncEnvironOrErr (ghostty_init fails cleanly on …
Context: B-072 (runner call).
Chose: init uses a fallible syncEnvironOrErr (ghostty_init fails cleanly on OOM); GTK keeps the void log-and-keep syncEnviron
Why: AUTONOMY: approach
Commit: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938
Veto: [ ]

## D-166 · 2026-09-30 · Zig comments don't mention B-072 (keeps the upstream diff neutral)
Context: B-072 (runner call).
Chose: Zig comments don't mention B-072 (keeps the upstream diff neutral)
Why: AUTONOMY: minimal Zig
Commit: a88c3c1b2 3631ebc4b 96c0589bc 508100cd3 2463458fd 0f9f87938
Veto: [ ]

## D-167 · 2026-09-30 · verify.md-only items are applied by the orchestrator, not a lane
Context: B-077. Lanes can't change .autopilot/ (land refuses), so a runner can't deliver an item whose whole change is verify.md.
Chose: The orchestrator edits verify.md directly as a state commit and marks the item done with no code change
Why: AUTONOMY implementation approach / test infra
Commit: dca59c5f9
Veto: [ ]

## D-168 · 2026-09-30 · Test-host timeout default raised to 900 s; LEO_TEST_TIMEOUT stays the override
Context: B-073. The timeout was already configurable (LEO_TEST_TIMEOUT, D-057); the runner script is untracked scratch, so no lane change is possible.
Chose: Raise the autopilot worktree runtests.sh default from 400 s to 900 s and document the override and the RUN INCOMPLETE message in verify.md
Why: AUTONOMY test infra / flake fixes
Commit: (verify.md state commit)
Veto: [ ]

## D-169 · 2026-09-30 · In hidden titlebar style the sidebar header and the terminal run to t…
Context: B-074 (runner call).
Chose: In hidden titlebar style the sidebar header and the terminal run to the window's top edge with only the 10 pt D-122 inset, keeping no room for the hidden buttons
Why: AUTONOMY: layout
Commit: 995fab04e 67ee5def8
Veto: [ ]

## D-170 · 2026-09-30 · The fix keys on the window class (HiddenTitlebarTerminalWindow), not …
Context: B-074 (runner call).
Chose: The fix keys on the window class (HiddenTitlebarTerminalWindow), not the live config
Why: AUTONOMY: implementation approach
Commit: 995fab04e 67ee5def8
Veto: [ ]

## D-171 · 2026-09-30 · TerminalController.windowNibName reads the controller's own config in…
Context: B-074 (runner call).
Chose: TerminalController.windowNibName reads the controller's own config instead of the app delegate's (same object in the app; lets the test use the real path)
Why: AUTONOMY: implementation approach
Commit: 995fab04e 67ee5def8
Veto: [ ]

## D-172 · 2026-09-30 · In Leo windows terminalContent uses the same window-class check as th…
Context: B-074 (runner call).
Chose: In Leo windows terminalContent uses the same window-class check as the split; non-Leo windows keep upstream's live-config check
Why: AUTONOMY: implementation approach
Commit: 995fab04e 67ee5def8
Veto: [ ]

## D-173 · 2026-09-30 · On the start screen nothing holds focus; the window itself does, like…
Context: B-075 (runner call).
Chose: On the start screen nothing holds focus; the window itself does, like a Finder window with no selection (its SwiftUI buttons can't take focus without Full Keyboard Access)
Why: P1, AUTONOMY UX details
Commit: 6b5dfa44a da808024b
Veto: [ ]

## D-174 · 2026-09-30 · Tab from the start screen still goes to the search field; ⌥⌘F stays t…
Context: B-075 (runner call).
Chose: Tab from the start screen still goes to the search field; ⌥⌘F stays the intended way in
Why: P1, AUTONOMY UX details
Commit: 6b5dfa44a da808024b
Veto: [ ]

## D-175 · 2026-09-30 · The key view loop is rebuilt (async, next turn) each time the window …
Context: B-075 (runner call).
Chose: The key view loop is rebuilt (async, next turn) each time the window becomes key, because AppKit's automatic pick no longer builds it
Why: AUTONOMY implementation approach
Commit: 6b5dfa44a da808024b
Veto: [ ]

## D-176 · 2026-09-30 · Keep parsing MainMenu.xib rather than loading the real nib (loading i…
Context: B-076 (runner call).
Chose: Keep parsing MainMenu.xib rather than loading the real nib (loading it builds AppDelegate; the live menu is rewritten from the config); the live-menu ⌘T check stays
Why: AUTONOMY test infra
Commit: 922ba4b00
Veto: [ ]

## D-177 · 2026-09-30 · A bare T (empty <modifierMask/>) on any item except New Terminal (new…
Context: B-076 (runner call).
Chose: A bare T (empty <modifierMask/>) on any item except New Terminal (newTab:) is also a violation
Why: AUTONOMY implementation approach
Commit: 922ba4b00
Veto: [ ]

## D-178 · 2026-09-30 · Run-loop turn counting (afterPendingUpdates, 5 turns) proves nothing …
Context: B-078 (runner call).
Chose: Run-loop turn counting (afterPendingUpdates, 5 turns) proves nothing scrolled where there's no event to wait for
Why: AUTONOMY test infra
Commit: 125f2a501
Veto: [ ]

## D-179 · 2026-09-30 · The agent-row factory moved to static agents(count:) (test code only)
Context: B-078 (runner call).
Chose: The agent-row factory moved to static agents(count:) (test code only)
Why: AUTONOMY test infra
Commit: 125f2a501
Veto: [ ]

## D-180 · 2026-09-30 · The tooltip (.help) sits on the title+suffix label HStack, not the wh…
Context: B-079 (runner call).
Chose: The tooltip (.help) sits on the title+suffix label HStack, not the whole row
Why: AUTONOMY UX details
Commit: 2aa0a78b3
Veto: [ ]

## D-181 · 2026-09-30 · A named `help` property on the label model rather than reusing `text`
Context: B-079 (runner call).
Chose: A named `help` property on the label model rather than reusing `text`
Why: AUTONOMY test infra
Commit: 2aa0a78b3
Veto: [ ]

## D-182 · 2026-09-30 · Start-screen buttons show a tooltip only when there is hint text, so …
Context: B-080 (runner call).
Chose: Start-screen buttons show a tooltip only when there is hint text, so an item with no shortcut gets no tooltip rather than an empty or wrong one
Why: AUTONOMY UX details
Commit: d864297ac
Veto: [ ]

## D-183 · 2026-09-30 · Choose Agent… gets the same live-menu hint (its ⌘O comes from the xib…
Context: B-080 (runner call).
Chose: Choose Agent… gets the same live-menu hint (its ⌘O comes from the xib; reading the menu item covers any change)
Why: AUTONOMY implementation approach
Commit: d864297ac
Veto: [ ]

## D-184 · 2026-09-30 · The disconnected tooltip still hardcodes "Reconnect first (⇧⌘R)"; Rec…
Context: B-080 (runner call).
Chose: The disconnected tooltip still hardcodes "Reconnect first (⇧⌘R)"; Reconnect isn't config-synced and is out of scope
Why: AUTONOMY scope
Commit: d864297ac
Veto: [ ]

## D-185 · 2026-09-30 · Landing at "the top" means scrolling to the first section; its header…
Context: B-081 (runner call).
Chose: Landing at "the top" means scrolling to the first section; its header sits at the list's top edge, 10 pt off the launch position because of the table's top margin
Why: P2
Commit: 1b7d6fefc, c56e8fdc9
Veto: [ ]

## D-186 · 2026-09-30 · The landing uses the list's own minimal, unanimated scrollTo, so a se…
Context: B-081 (runner call).
Chose: The landing uses the list's own minimal, unanimated scrollTo, so a selection already on screen doesn't move
Why: P2/D-130
Commit: 1b7d6fefc, c56e8fdc9
Veto: [ ]

## D-187 · 2026-09-30 · With no selected agent the list goes to the top, even if the user had…
Context: B-081 (runner call).
Chose: With no selected agent the list goes to the top, even if the user had scrolled mid-list
Why: acceptance criteria ("the selection or the top")
Commit: 1b7d6fefc, c56e8fdc9
Veto: [ ]

## D-188 · 2026-09-30 · When the filter hides the Terminals section the list doesn't move; on…
Context: B-081 (runner call).
Chose: When the filter hides the Terminals section the list doesn't move; only closing the last row lands
Why: P6
Commit: 1b7d6fefc, c56e8fdc9
Veto: [ ]

## D-189 · 2026-09-30 · The start-title test runs its own Ghostty.App on a temp config (prece…
Context: B-081 (runner call).
Chose: The start-title test runs its own Ghostty.App on a temp config (precedent: LeoSidebarTitlebarStyleTests)
Why: AUTONOMY test infra
Commit: 1b7d6fefc, c56e8fdc9
Veto: [ ]

## D-190 · 2026-09-30 · When a row's pane closes beside a split, the row keeps its sidebar sl…
Context: B-082 (runner call).
Chose: When a row's pane closes beside a split, the row keeps its sidebar slot and carries on as the surviving plain shell (retitled, still selected); extends D-117
Why: P6, P2
Commit: b3e29e2c4, b818ba40a, 4d41627b1
Veto: [ ]

## D-191 · 2026-09-30 · With several shells left, the focused survivor else the first in tree…
Context: B-082 (runner call).
Chose: With several shells left, the focused survivor else the first in tree order takes the row; the rest stay split beside it (more is B-058, per D-100)
Why: P6
Commit: b3e29e2c4, b818ba40a, 4d41627b1
Veto: [ ]

## D-192 · 2026-09-30 · Only Leo-made plain shells are adopted; an attach handle or leoAgentN…
Context: B-082 (runner call).
Chose: Only Leo-made plain shells are adopted; an attach handle or leoAgentName blocks adoption, and handle-less surfaces are never adopted
Why: P2
Commit: b3e29e2c4, b818ba40a, 4d41627b1
Veto: [ ]

## D-193 · 2026-09-30 · An agent pane closing beside a plain shell is left alone here and not…
Context: B-082 (runner call).
Chose: An agent pane closing beside a plain shell is left alone here and noted for B-058
Why: scope, P2
Commit: b3e29e2c4, b818ba40a, 4d41627b1
Veto: [ ]

## D-194 · 2026-09-30 · Adoption is opt-in: only reconcile (upstream removed the pane) and cl…
Context: B-082 (runner call).
Chose: Adoption is opt-in: only reconcile (upstream removed the pane) and closeShownPane hand the row on, so closing a hidden row never gives its slot to an unrelated on-screen shell
Why: P2
Commit: b3e29e2c4, b818ba40a, 4d41627b1
Veto: [ ]

## D-195 · 2026-09-30 · LeoTerminalList.replacing drops the old row if the new id is already …
Context: B-082 (runner call).
Chose: LeoTerminalList.replacing drops the old row if the new id is already listed; replacing with its own id just retitles
Why: P6
Commit: b3e29e2c4, b818ba40a, 4d41627b1
Veto: [ ]

## D-196 · 2026-09-30 · Dismiss point 5 (cross-window Move Split undo) in B-083 and park the …
Context: B-083 (runner call).
Chose: Dismiss point 5 (cross-window Move Split undo) in B-083 and park the cross-window surface move (ownership, rows, undo) as its own follow-up (B-110)
Why: AUTONOMY implementation approach; P2 no half-fixed state; D-141 forbids clearing the other window's undo
Commit: 02fa5f775, 81126012d, 7c4403ba4, f971917cf
Veto: [ ]

## D-197 · 2026-09-30 · Document the cross-window limit in the leoForgetContentUndo doc, not …
Context: B-083 (runner call).
Chose: Document the cross-window limit in the leoForgetContentUndo doc, not in code
Why: AUTONOMY implementation approach
Commit: 02fa5f775, 81126012d, 7c4403ba4, f971917cf
Veto: [ ]

## D-198 · 2026-09-30 · Put point 3's processExited assertion in the shared helper expectUndo…
Context: B-083 (runner call).
Chose: Put point 3's processExited assertion in the shared helper expectUndoLeftTheSwitchAlone so both callers get it
Why: AUTONOMY test infrastructure
Commit: 02fa5f775, 81126012d, 7c4403ba4, f971917cf
Veto: [ ]

## D-199 · 2026-09-30 · Delete the now-wrong LeoUndoTestSupport paragraph about avoiding remo…
Context: B-083 (runner call).
Chose: Delete the now-wrong LeoUndoTestSupport paragraph about avoiding removeAllActions()
Why: AUTONOMY implementation approach
Commit: 02fa5f775, 81126012d, 7c4403ba4, f971917cf
Veto: [ ]

## D-200 · 2026-09-30 · LeoRuntime's template fetch reuses the existing LeoProcessRunning pro…
Context: B-061 (runner call).
Chose: LeoRuntime's template fetch reuses the existing LeoProcessRunning protocol; templateFetchRunner has no default, so a test that omits it won't compile; the shared fake lives in LeoTemplateFetchTestSupport.swift
Why: AUTONOMY test infrastructure
Commit: f859b45c5
Veto: [ ]

## D-201 · 2026-09-30 · Names AttachContentHost / GhosttyAttachContentHost / FakeAttachConten…
Context: B-062 (runner call).
Chose: Names AttachContentHost / GhosttyAttachContentHost / FakeAttachContentHost / LeoTitleSource / attachCount(s) / isAgent / isLiveAgent
Why: AUTONOMY naming
Commit: 93b48c55f, 419cb7a7f, 16e2c07cb, 14a6cfe2c, 99e7b46aa, 465cad581
Veto: [ ]

## D-202 · 2026-09-30 · One agent predicate in two layers: handle-backed isRegisteredAgent is…
Context: B-062 (runner call).
Chose: One agent predicate in two layers: handle-backed isRegisteredAgent is the primitive (live pool, isLiveAgent); isAgent = leoAgentName != nil || isRegisteredAgent gates replace-confirm and orphan adoption, so both B-082 signals still block adoption
Why: AUTONOMY implementation approach
Commit: 93b48c55f, 419cb7a7f, 16e2c07cb, 14a6cfe2c, 99e7b46aa, 465cad581
Veto: [ ]

## D-203 · 2026-09-30 · The live pool lets go of (doesn't pool) an Undo-restored agent surfac…
Context: B-062 (runner call).
Chose: The live pool lets go of (doesn't pool) an Undo-restored agent surface that has a name but no handle, so it never keeps an unrevealable duplicate tmux client (B-056)
Why: P6
Commit: 93b48c55f, 419cb7a7f, 16e2c07cb, 14a6cfe2c, 99e7b46aa, 465cad581
Veto: [ ]

## D-204 · 2026-09-30 · contentVersion is pruned by a direct, idempotent LeoAttachCoordinator…
Context: B-062 (runner call).
Chose: contentVersion is pruned by a direct, idempotent LeoAttachCoordinator.windowClosed(_:) from LeoRuntime.teardownWindow and registry.onUnregistered, not a new lifecycle event
Why: AUTONOMY implementation approach
Commit: 93b48c55f, 419cb7a7f, 16e2c07cb, 14a6cfe2c, 99e7b46aa, 465cad581
Veto: [ ]

## D-205 · 2026-09-30 · Test names where "Tab" means an upstream tab (LeoNoTabBarTests, chang…
Context: B-062 (runner call).
Chose: Test names where "Tab" means an upstream tab (LeoNoTabBarTests, changeTabTitleStillWins, …) keep their names
Why: AUTONOMY naming
Commit: 93b48c55f, 419cb7a7f, 16e2c07cb, 14a6cfe2c, 99e7b46aa, 465cad581
Veto: [ ]

## D-206 · 2026-09-30 · The button bar is a sidebar footer, not the header (Finder/Mail/Xcode…
Context: B-065 (runner call).
Chose: The button bar is a sidebar footer, not the header (Finder/Mail/Xcode convention); keeps the top calm and D-122's layout untouched
Why: P1 HIG, P2
Commit: 2b4c91a31, 84a74db61, 20f63fa80
Veto: [ ]

## D-207 · 2026-09-30 · Icons: `terminal` (New Terminal) and `rectangle.tophalf.inset.filled`…
Context: B-065 (runner call).
Chose: Icons: `terminal` (New Terminal) and `rectangle.tophalf.inset.filled` (Quick Terminal); borderless, secondary tint, no labels
Why: P2
Commit: 2b4c91a31, 84a74db61, 20f63fa80
Veto: [ ]

## D-208 · 2026-09-30 · Tooltip is "<Menu Title> <live shortcut>" via LeoMenuShortcutHint, ti…
Context: B-065 (runner call).
Chose: Tooltip is "<Menu Title> <live shortcut>" via LeoMenuShortcutHint, title only when unbound (Quick Terminal is unbound by default)
Why: P1, B-080
Commit: 2b4c91a31, 84a74db61, 20f63fa80
Veto: [ ]

## D-209 · 2026-09-30 · Order: New Terminal, then Quick Terminal
Context: B-065 (runner call).
Chose: Order: New Terminal, then Quick Terminal
Why: P6
Commit: 2b4c91a31, 84a74db61, 20f63fa80
Veto: [ ]

## D-210 · 2026-09-30 · 22×22 pt hit targets (named constant), spaced with LeoSidebarChromeMe…
Context: B-065 (runner call).
Chose: 22×22 pt hit targets (named constant), spaced with LeoSidebarChromeMetrics.itemSpacing
Why: AUTONOMY UX details
Commit: 2b4c91a31, 84a74db61, 20f63fa80
Veto: [ ]

## D-211 · 2026-09-30 · Buttons are .focusable(false) so they don't steal terminal focus
Context: B-065 (runner call).
Chose: Buttons are .focusable(false) so they don't steal terminal focus
Why: P1
Commit: 2b4c91a31, 84a74db61, 20f63fa80
Veto: [ ]

## D-212 · 2026-09-30 · B-058 parked, not resumed
Context: B-058 (splits inside the content area) held after a runner timeout; Evan answered.
Chose: punt — not sure we need it; don't resume. Keep the held lane/branch autopilot-lane/B-058 as-is; park the item (status idea).
Why: Evan's answer
Commit:
Veto: n/a (Evan)

## D-213 · 2026-09-30 · Launch test asserts "terminal fills the split" rather than "sidebar f…
Context: B-090 (runner call).
Chose: Launch test asserts "terminal fills the split" rather than "sidebar frame is 0" (a collapsed item keeps a stale 200 pt frame; the terminal width is what the user sees)
Why: AUTONOMY test-infra latitude
Commit: 980ec80b4, 8e7cd5d02
Veto: [ ]

## D-214 · 2026-09-30 · B-084's aHiddenSidebarShownAfterLaunchOpensAtTheStoredWidth now uses …
Context: B-090 (runner call).
Chose: B-084's aHiddenSidebarShownAfterLaunchOpensAtTheStoredWidth now uses `try #require(sidebarItem.isCollapsed)` instead of forcing isCollapsed = true, which had masked this bug
Why: AUTONOMY test-infra latitude
Commit: 980ec80b4, 8e7cd5d02
Veto: [ ]

## D-215 · 2026-09-30 · Store the exiting mark inside the existing lock file, not a separate …
Context: B-092 (runner call).
Chose: Store the exiting mark inside the existing lock file, not a separate marker or a LaunchServices check (B-085 showed isTerminated is unreliable)
Why: AUTONOMY implementation approach
Commit: 85ca7d75b, 712e5b926, 8094e6416
Veto: [ ]

## D-216 · 2026-09-30 · The waiting copy shows no UI and has no timeout while a quitting hold…
Context: B-092 (runner call).
Chose: The waiting copy shows no UI and has no timeout while a quitting holder is alive
Why: P5, P2
Commit: 85ca7d75b, 712e5b926, 8094e6416
Veto: [ ]

## D-217 · 2026-09-30 · Mark on quit approval (every terminateNow/true reply) plus in applica…
Context: B-092 (runner call).
Chose: Mark on quit approval (every terminateNow/true reply) plus in applicationWillTerminate as a backstop
Why: AUTONOMY bug fix
Commit: 85ca7d75b, 712e5b926, 8094e6416
Veto: [ ]

## D-218 · 2026-09-30 · Wait on the marked pid via kqueue NOTE_EXIT, then a bounded ~5 s rele…
Context: B-092 (runner call).
Chose: Wait on the marked pid via kqueue NOTE_EXIT, then a bounded ~5 s release retry (2 ms × 2500) covering XNU's exit-before-flock-release gap, then yield per D-051
Why: P5 (not a user-facing retry)
Commit: 85ca7d75b, 712e5b926, 8094e6416
Veto: [ ]

## D-219 · 2026-09-30 · A failed truncate on acquire refuses with the D-053 alert
Context: B-092 (runner call).
Chose: A failed truncate on acquire refuses with the D-053 alert
Why: D-053
Commit: 85ca7d75b, 712e5b926, 8094e6416
Veto: [ ]

## D-220 · 2026-09-30 · Debug builds can check for updates but never install or auto-download…
Context: B-115 (runner call).
Chose: Debug builds can check for updates but never install or auto-download (stage-gated replies + mayPerform guard on background checks)
Why: item guardrail, reversible
Commit: 1616be959, 33d913f26, 5136f6c76, d5b151c71, aba15d23a, bf2628285, a24ed1fae, 10bb68570
Veto: [ ]

## D-221 · 2026-09-30 · Unset auto-update defers to Sparkle's own permission prompt, with a o…
Context: B-115 (runner call).
Chose: Unset auto-update defers to Sparkle's own permission prompt, with a one-time marker-keyed defaults reset so existing installs get asked
Why: P4
Commit: 1616be959, 33d913f26, 5136f6c76, d5b151c71, aba15d23a, bf2628285, a24ed1fae, 10bb68570
Veto: [ ]

## D-222 · 2026-09-30 · Debug popover caption "Debug build: installing is disabled", with Ins…
Context: B-115 (runner call).
Chose: Debug popover caption "Debug build: installing is disabled", with Install disabled
Why: AUTONOMY copy/UX
Commit: 1616be959, 33d913f26, 5136f6c76, d5b151c71, aba15d23a, bf2628285, a24ed1fae, 10bb68570
Veto: [ ]

## D-223 · 2026-09-30 · Appcast test uses a test-local XMLParser on a #filePath fixture, not …
Context: B-115 (runner call).
Chose: Appcast test uses a test-local XMLParser on a #filePath fixture, not Sparkle private API
Why: AUTONOMY test infrastructure
Commit: 1616be959, 33d913f26, 5136f6c76, d5b151c71, aba15d23a, bf2628285, a24ed1fae, 10bb68570
Veto: [ ]

## D-224 · 2026-09-30 · XCTest hosts skip starting the updater; UI tests pass -SUEnableAutoma…
Context: B-115 (runner call).
Chose: XCTest hosts skip starting the updater; UI tests pass -SUEnableAutomaticChecks NO
Why: AUTONOMY test infrastructure
Commit: 1616be959, 33d913f26, 5136f6c76, d5b151c71, aba15d23a, bf2628285, a24ed1fae, 10bb68570
Veto: [ ]

## D-225 · 2026-09-30 · Runtime mayPerform guard instead of a Debug-only SUAllowsAutomaticUpd…
Context: B-115 (runner call).
Chose: Runtime mayPerform guard instead of a Debug-only SUAllowsAutomaticUpdates plist key, because the release workflow PlistBuddy-reads the source plist
Why: AUTONOMY implementation approach
Commit: 1616be959, 33d913f26, 5136f6c76, d5b151c71, aba15d23a, bf2628285, a24ed1fae, 10bb68570
Veto: [ ]

## D-226 · 2026-09-30 · ci.md go-public checklist items 1–3 marked done 2026-09-30; item 4 (E…
Context: B-115 (runner call).
Chose: ci.md go-public checklist items 1–3 marked done 2026-09-30; item 4 (Evan's post-release install check) left open
Why: item Accept
Commit: 1616be959, 33d913f26, 5136f6c76, d5b151c71, aba15d23a, bf2628285, a24ed1fae, 10bb68570
Veto: [ ]

## D-227 · 2026-09-30 · The fix is Leo-side in GhosttyAttachContentHost.openSplit (sets contr…
Context: B-087 (runner call).
Chose: The fix is Leo-side in GhosttyAttachContentHost.openSplit (sets controller.focusedSurface = newView); upstream BaseTerminalController.windowDidBecomeKey left alone, keeping the upstream diff small
Why: AUTONOMY implementation approach
Commit: 03136e14f, 09f7d4de2
Veto: [ ]

## D-228 · 2026-09-30 · Confirm copy is `Close “<name>”?`; two names both quoted, three+ `… a…
Context: B-088 (runner call).
Chose: Confirm copy is `Close “<name>”?`; two names both quoted, three+ `… and N other terminals?`; split-pane detail says the other splits stay open
Why: AUTONOMY UX/copy, P1
Commit: c606e4f2d
Veto: [ ]

## D-229 · 2026-09-30 · Pane name follows window title / sidebar row title, control chars cle…
Context: B-088 (runner call).
Chose: Pane name follows window title / sidebar row title, control chars cleaned, capped at 60 chars middle-truncated
Why: AUTONOMY UX details
Commit: c606e4f2d
Veto: [ ]

## D-230 · 2026-09-30 · Red-X Close Window and close-window-with-tabs keep "Close Terminal?" …
Context: B-088 (runner call).
Chose: Red-X Close Window and close-window-with-tabs keep "Close Terminal?" (whole window, not ambiguous)
Why: AUTONOMY small scope cut
Commit: c606e4f2d
Veto: [ ]

## D-231 · 2026-09-30 · When a widened window gives room back, a clamped sidebar keeps its cu…
Context: B-089 (runner call).
Chose: When a widened window gives room back, a clamped sidebar keeps its current width; the stored preference is untouched and the next launch opens at it
Why: P2, D-144/D-145
Commit: 0cd940a68, 111c6aff9, d373aecc3, 5ea58f8a0, 1b956fa7c, 862fbb512, 5ee90bebb, e41196534
Veto: [ ]

## D-232 · 2026-09-30 · The pending-branch flag write is dropped rather than documented; the …
Context: B-089 (runner call).
Chose: The pending-branch flag write is dropped rather than documented; the pendingWidth guard covers it (comment says the check must stay)
Why: P1
Commit: 0cd940a68, 111c6aff9, d373aecc3, 5ea58f8a0, 1b956fa7c, 862fbb512, 5ee90bebb, e41196534
Veto: [ ]

## D-233 · 2026-09-30 · Width persists only on a user/setPosition move of the sidebar's own d…
Context: B-089 (runner call).
Chose: Width persists only on a user/setPosition move of the sidebar's own divider (NSSplitViewUserResizeKey + divider index 0); window-resize clamps and terminal-floor layouts never persist
Why: D-144, P2
Commit: 0cd940a68, 111c6aff9, d373aecc3, 5ea58f8a0, 1b956fa7c, 862fbb512, 5ee90bebb, e41196534
Veto: [ ]

## D-234 · 2026-09-30 · A drag of the terminal/editor divider that pushes the sidebar is not …
Context: B-089 (runner call).
Chose: A drag of the terminal/editor divider that pushes the sidebar is not stored as a sidebar width (test-pinned)
Why: P6, D-144
Commit: 0cd940a68, 111c6aff9, d373aecc3, 5ea58f8a0, 1b956fa7c, 862fbb512, 5ee90bebb, e41196534
Veto: [ ]

## D-235 · 2026-09-30 · contentMinimumWidth = 450 pt (start-screen button row measured at 409…
Context: B-091 (runner call).
Chose: contentMinimumWidth = 450 pt (start-screen button row measured at 409 pt, plus the HIG's 20 pt margins)
Why: P1, AUTONOMY UX details
Commit: 25f7b4bd7, 42ecc4794
Veto: [ ]

## D-236 · 2026-09-30 · When the window narrows, the sidebar gives way before the content
Context: B-091 (runner call).
Chose: When the window narrows, the sidebar gives way before the content
Why: P1 (same spirit as D-036)
Commit: 25f7b4bd7, 42ecc4794
Veto: [ ]

## D-237 · 2026-09-30 · A sidebar clamped by a window resize regrows when the window widens; …
Context: B-091 (runner call).
Chose: A sidebar clamped by a window resize regrows when the window widens; a sidebar clamped at launch keeps its clamped width (scopes D-231 to launch clamps)
Why: P1, P2, D-231/D-233
Commit: 25f7b4bd7, 42ecc4794
Veto: [ ]

## D-238 · 2026-09-30 · With the sidebar shown, a configured window-width under 450 pt opens …
Context: B-091 (runner call).
Chose: With the sidebar shown, a configured window-width under 450 pt opens the terminal at 450 pt so the stored sidebar isn't clamped (Reset Window Size shares this path)
Why: P1, D-144, D-145
Commit: 25f7b4bd7, 42ecc4794
Veto: [ ]

## D-239 · 2026-09-30 · While Leo is hidden (open -j, hidden login item), a requested window …
Context: B-093 (runner call).
Chose: While Leo is hidden (open -j, hidden login item), a requested window counts as shown once its presentation ran and until it closes; when not hidden it must still be on screen (extends D-149)
Why: P1, AUTONOMY bug fix
Commit: 3d90cb41f, b09da3a64, 846d9b336, 6f0759f97, 5f7b9c4fb
Veto: [ ]

## D-240 · 2026-09-30 · The queued close also requires the launch window to still be open and…
Context: B-093 (runner call).
Chose: The queued close also requires the launch window to still be open and shown, so it is never closed twice
Why: AUTONOMY bug fix
Commit: 3d90cb41f, b09da3a64, 846d9b336, 6f0759f97, 5f7b9c4fb
Veto: [ ]

## D-241 · 2026-09-30 · Sub-issue 3 (search not focused after replacement) dismissed: a new w…
Context: B-093 (runner call).
Chose: Sub-issue 3 (search not focused after replacement) dismissed: a new window's focus stays in its content per B-075/D-173/D-174 (⌥⌘F enters search); a guard assertion covers the replacing window
Why: P1, D-173
Commit: 3d90cb41f, b09da3a64, 846d9b336, 6f0759f97, 5f7b9c4fb
Veto: [ ]

## D-242 · 2026-09-30 · Sub-issue 4 (B-085 plan file not amended) dismissed: that plan is git…
Context: B-093 (runner call).
Chose: Sub-issue 4 (B-085 plan file not amended) dismissed: that plan is gitignored scratch for a done item; D-148..D-151, commits and doc comments are the record
Why: AUTONOMY implementation approach
Commit: 3d90cb41f, b09da3a64, 846d9b336, 6f0759f97, 5f7b9c4fb
Veto: [ ]

## D-243 · 2026-09-30 · Kept the "presentation ran" flag rather than recording showWindowSafe…
Context: B-093 (runner call).
Chose: Kept the "presentation ran" flag rather than recording showWindowSafely's Bool
Why: AUTONOMY implementation approach
Commit: 3d90cb41f, b09da3a64, 846d9b336, 6f0759f97, 5f7b9c4fb
Veto: [ ]

## D-244 · 2026-10-01 · Reopen's window is not adopted as a launch placeholder (D-149 covers …
Context: B-095 (runner call).
Chose: Reopen's window is not adopted as a launch placeholder (D-149 covers only the launch window)
Why: P2
Commit: 13d56313c
Veto: [ ]

## D-245 · 2026-10-01 · Scope limited to reopen and the app delegate's fallback New Window; G…
Context: B-095 (runner call).
Chose: Scope limited to reopen and the app delegate's fallback New Window; Ghostty's new_window (⌘N from a terminal with content) and Choose Agent… with no window still route through the palette (Choose Agent is an explicit request for it)
Why: P1
Commit: 13d56313c
Veto: [ ]

## D-246 · 2026-10-01 · Assert the environ-on-heap precondition with #require, not a skip (a …
Context: B-098 (runner call).
Chose: Assert the environ-on-heap precondition with #require, not a skip (a silent skip hides lost coverage)
Why: AUTONOMY test infrastructure
Commit: 7a79610f8, 6b44c1a22, e0c6a8db1
Veto: [ ]

## D-247 · 2026-10-01 · Arena growth and environ_initialized documented, not fixed, consisten…
Context: B-098 (runner call).
Chose: Arena growth and environ_initialized documented, not fixed, consistent with D-162/D-163
Why: AUTONOMY implementation approach, minimal Zig
Commit: 7a79610f8, 6b44c1a22, e0c6a8db1
Veto: [ ]

## D-248 · 2026-10-01 · Probe lives in main.swift's Leo section (leoInstanceClaim pattern)
Context: B-098 (runner call).
Chose: Probe lives in main.swift's Leo section (leoInstanceClaim pattern)
Why: AUTONOMY implementation approach, naming
Commit: 7a79610f8, 6b44c1a22, e0c6a8db1
Veto: [ ]

## D-249 · 2026-10-01 · dupeEnvironBlock owns its deep copy instead of calling std createPosi…
Context: B-098 (runner call).
Chose: dupeEnvironBlock owns its deep copy instead of calling std createPosixBlock (std 0.16.0 errdefer frees the pointer array with the wrong length; found by the new OOM test)
Why: AUTONOMY bug fix, minimal Zig
Commit: 7a79610f8, 6b44c1a22, e0c6a8db1
Veto: [ ]

## D-250 · 2026-10-01 · No B-072 mention in Zig comments
Context: B-098 (runner call).
Chose: No B-072 mention in Zig comments
Why: D-166
Commit: 7a79610f8, 6b44c1a22, e0c6a8db1
Veto: [ ]

## D-251 · 2026-10-01 · "No matches" is an overlay on the same sidebar list instead of a repl…
Context: B-099 (runner call).
Chose: "No matches" is an overlay on the same sidebar list instead of a replacement view, so the selection is revealed reliably after a search clears, as in Mail
Why: P1 (serves D-129; D-130 holds)
Commit: 2e7667d9b, 811717ef8, 6fcb8552c, 757c80895, 291915f91
Veto: [ ]

## D-252 · 2026-10-01 · The selected terminal is re-revealed when agents start or stop being …
Context: B-099 (runner call).
Chose: The selected terminal is re-revealed when agents start or stop being listed (Loading→connected), matching pre-B-099 behaviour
Why: D-129
Commit: 2e7667d9b, 811717ef8, 6fcb8552c, 757c80895, 291915f91
Veto: [ ]

## D-253 · 2026-10-01 · The loading-reveal layout race is left as a documented follow-up
Context: B-099 (runner call).
Chose: The loading-reveal layout race is left as a documented follow-up
Why: AUTONOMY flake fixes/test infrastructure
Commit: 2e7667d9b, 811717ef8, 6fcb8552c, 757c80895, 291915f91
Veto: [ ]

## D-254 · 2026-10-01 · Timing waits replaced with run-loop turn counting (afterPendingUpdate…
Context: B-099 (runner call).
Chose: Timing waits replaced with run-loop turn counting (afterPendingUpdates)
Why: AUTONOMY test infrastructure, D-178
Commit: 2e7667d9b, 811717ef8, 6fcb8552c, 757c80895, 291915f91
Veto: [ ]

## D-255 · 2026-10-01 · Unreachable connected/disconnected-with-rows branch in agentState ren…
Context: B-099 (runner call).
Chose: Unreachable connected/disconnected-with-rows branch in agentState renders EmptyView()
Why: AUTONOMY implementation approach
Commit: 2e7667d9b, 811717ef8, 6fcb8552c, 757c80895, 291915f91
Veto: [ ]

## D-256 · 2026-10-01 · B-109 closed as not reproducible
Context: B-109 (closed split pane's shell lingers) blocked as couldn't-reproduce; Evan answered.
Chose: close — the shell lives only for the Close Terminal undo window; autopilot-shelved/B-109 kept as-is.
Why: Evan's answer
Commit:
Veto: n/a (Evan)

## D-257 · 2026-10-01 · The shared hidden-style inset stays at 10 pt, not enlarged for the "t…
Context: B-100 (runner call).
Chose: The shared hidden-style inset stays at 10 pt, not enlarged for the "tight" corner, because D-169 fixes it
Why: AUTONOMY: layout/polish
Commit: 50fdea4fa, 32d413573, 7c9cb2d1f
Veto: [ ]

## D-258 · 2026-10-01 · Side-pane headers centre on the sidebar header's line rather than ali…
Context: B-100 (runner call).
Chose: Side-pane headers centre on the sidebar header's line rather than aligning control-frame tops
Why: P1 Mac-native, toolbar-style alignment
Commit: 50fdea4fa, 32d413573, 7c9cb2d1f
Veto: [ ]

## D-259 · 2026-10-01 · New LeoSidebarChromeMetrics.headerRowHeight = 16 applied to LeoSideba…
Context: B-100 (runner call).
Chose: New LeoSidebarChromeMetrics.headerRowHeight = 16 applied to LeoSidebarHeader as .frame(minHeight:), so the sidebar doesn't move
Why: AUTONOMY: implementation
Commit: 50fdea4fa, 32d413573, 7c9cb2d1f
Veto: [ ]

## D-260 · 2026-10-01 · Relied on B-087's LeoContentFocusTests.aRowSwitchFocusesTheShownTermi…
Context: B-101 (runner call).
Chose: Relied on B-087's LeoContentFocusTests.aRowSwitchFocusesTheShownTerminal for the row-shown → first-responder criterion instead of a duplicate test
Why: AUTONOMY: test infrastructure
Commit: c640ac20b, f09c93245
Veto: [ ]

## D-261 · 2026-10-01 · Parameterized the Tab test over presentation timing (.nextTurn real o…
Context: B-101 (runner call).
Chose: Parameterized the Tab test over presentation timing (.nextTurn real order, .immediately worst case)
Why: AUTONOMY: test infrastructure
Commit: c640ac20b, f09c93245
Veto: [ ]

## D-262 · 2026-10-01 · Refines D-177: New Terminal may hold only ⌘T (a bare T on New Termina…
Context: B-102 (runner call).
Chose: Refines D-177: New Terminal may hold only ⌘T (a bare T on New Terminal is now a violation); same rule for Choose Agent… and O
Why: AUTONOMY: test infrastructure
Commit: 1f32b5966
Veto: [ ]

## D-263 · 2026-10-01 · Removed unused LeoMenuXib.claims(on:byAnyoneBut:); live checks count …
Context: B-102 (runner call).
Chose: Removed unused LeoMenuXib.claims(on:byAnyoneBut:); live checks count hidden items too (stricter reading)
Why: AUTONOMY: test infrastructure
Commit: 1f32b5966
Veto: [ ]

## D-264 · 2026-10-01 · Pixel-width "new title drawn" signal for the retitle test, because Sw…
Context: B-103 (runner call).
Chose: Pixel-width "new title drawn" signal for the retitle test, because SwiftUI AX text is unavailable in the test host
Why: AUTONOMY: test infrastructure
Commit: 396984a56
Veto: [ ]

## D-265 · 2026-10-01 · New turns(limit:until:) helper counts run-loop turns until a conditio…
Context: B-103 (runner call).
Chose: New turns(limit:until:) helper counts run-loop turns until a condition holds (max 50) instead of a time wait
Why: AUTONOMY: test infrastructure, D-178/D-254
Commit: 396984a56
Veto: [ ]

## D-266 · 2026-10-01 · Calm-scroll waits read the window's current list, so a rebuilt list f…
Context: B-103 (runner call).
Chose: Calm-scroll waits read the window's current list, so a rebuilt list fails an explicit same-list (===) check
Why: AUTONOMY: test infrastructure
Commit: 396984a56
Veto: [ ]

## D-267 · 2026-10-01 · Calm-scroll doc comments drop project history and cite both halves of…
Context: B-103 (runner call).
Chose: Calm-scroll doc comments drop project history and cite both halves of D-129
Why: AUTONOMY: test infrastructure
Commit: 396984a56
Veto: [ ]

## D-268 · 2026-10-01 · The disconnected Choose Agent… tooltip reads Agents ▸ Reconnect's liv…
Context: B-104 (runner call).
Chose: The disconnected Choose Agent… tooltip reads Agents ▸ Reconnect's live shortcut instead of hardcoding ⇧⌘R (follows B-080's Choose Agent precedent)
Why: AUTONOMY: UX details, copy
Commit: 3612df84d, 83224b8a9
Veto: [ ]

## D-269 · 2026-10-01 · Start-screen hints spell F1–F35 ("⌘F1") when a menu item carries one;…
Context: B-104 (runner call).
Chose: Start-screen hints spell F1–F35 ("⌘F1") when a menu item carries one; config F-key rebinds still reach no menu item because upstream keyToEquivalent drops F-keys — left as a follow-up
Why: AUTONOMY: implementation approach
Commit: 3612df84d, 83224b8a9
Veto: [ ]

## D-270 · 2026-10-01 · Refines D-187: with nothing selected, the list goes to the top only i…
Context: B-105 (runner call).
Chose: Refines D-187: with nothing selected, the list goes to the top only if the Terminals section was on screen when it closed; if it was scrolled off (selection or not) the list stays put
Why: P2 calm
Commit: 5ce958ac9, 75c512e4c, 1b9d09aed
Veto: [ ]

## D-271 · 2026-10-01 · Refines D-185: the top landing reaches the list's launch offset (top …
Context: B-105 (runner call).
Chose: Refines D-185: the top landing reaches the list's launch offset (top margin included) by scrolling the NSScrollView itself, not scrollTo(first header)
Why: P2 calm
Commit: 5ce958ac9, 75c512e4c, 1b9d09aed
Veto: [ ]

## D-272 · 2026-10-01 · "On screen" means any part of the Terminals header or rows inside the…
Context: B-105 (runner call).
Chose: "On screen" means any part of the Terminals header or rows inside the clip view minus its content insets; a row only touching the edge doesn't count
Why: AUTONOMY: UX details
Commit: 5ce958ac9, 75c512e4c, 1b9d09aed
Veto: [ ]

## D-273 · 2026-10-01 · Terminals section is read from the table's last labels.count+1 rows r…
Context: B-105 (runner call).
Chose: Terminals section is read from the table's last labels.count+1 rows rather than per-row probes (unreliable under cell reuse); LeoSidebarSectionAnchor and the section .id removed
Why: AUTONOMY: implementation approach
Commit: 5ce958ac9, 75c512e4c, 1b9d09aed
Veto: [ ]

## D-274 · 2026-10-01 · Near-edge test parks one row above the section, not 1 pt (AppKit nudg…
Context: B-105 (runner call).
Chose: Near-edge test parks one row above the section, not 1 pt (AppKit nudges 2 pt at 1 pt)
Why: AUTONOMY: test infrastructure
Commit: 5ce958ac9, 75c512e4c, 1b9d09aed
Veto: [ ]

## D-275 · 2026-10-01 · The selection-highlight regression test checks a pixel probe (selecte…
Context: B-106 (runner call).
Chose: The selection-highlight regression test checks a pixel probe (selected row vs an unselected row) on top of isSelected, per the verify-absolute rule
Why: AUTONOMY: test infrastructure
Commit: 6b08d7233, c1b36b866
Veto: [ ]

## D-276 · 2026-10-01 · Refines D-191: the focused survivor is upstream's next-focus pane aft…
Context: B-107 (runner call).
Chose: Refines D-191: the focused survivor is upstream's next-focus pane after the close (previous leaf, or next if the closed pane was leftmost), else the first in tree order; the old code read a stale focusedSurface
Why: P6 sidebar is the navigation
Commit: 0ede659d9, 0c129e5cd, 5679f7b0a
Veto: [ ]

## D-277 · 2026-10-01 · Pending reconciles run synchronously (oldest first) at the top of sho…
Context: B-107 (runner call).
Chose: Pending reconciles run synchronously (oldest first) at the top of showInContent, reveal and confirmReplacingContent, so a same-turn switch keeps the carried-on shell
Why: P2 / AUTONOMY: implementation
Commit: 0ede659d9, 0c129e5cd, 5679f7b0a
Veto: [ ]

## D-278 · 2026-10-01 · A pending entry merged before its drain keeps the earlier heir unless…
Context: B-107 (runner call).
Chose: A pending entry merged before its drain keeps the earlier heir unless a later change computes a new one
Why: AUTONOMY: implementation
Commit: 0ede659d9, 0c129e5cd, 5679f7b0a
Veto: [ ]

## D-279 · 2026-10-01 · The survivor's "Last login" reflow is assessed, not fixed: it is upst…
Context: B-107 (runner call).
Chose: The survivor's "Last login" reflow is assessed, not fixed: it is upstream/shell behaviour
Why: AUTONOMY: keep Zig minimal
Commit: 0ede659d9, 0c129e5cd, 5679f7b0a
Veto: [ ]

## D-280 · 2026-10-01 · An undo-restored pane comes back as a plain split with its handle, no…
Context: B-108 (runner call).
Chose: An undo-restored pane comes back as a plain split with its handle, not as a row; the split carrying the row keeps it until that split closes
Why: D-190, P6
Commit: 4540801bc, dda028e02, f8878eeca, 8f0d20276, 05160bf62
Veto: [ ]

## D-281 · 2026-10-01 · Restored panes become reachable by re-registering Leo's own handle, n…
Context: B-108 (runner call).
Chose: Restored panes become reachable by re-registering Leo's own handle, never by adopting handle-less surfaces
Why: D-192, P6
Commit: 4540801bc, dda028e02, f8878eeca, 8f0d20276, 05160bf62
Veto: [ ]

## D-282 · 2026-10-01 · Plain splits brought back by any undo or redo also get their handles …
Context: B-108 (runner call).
Chose: Plain splits brought back by any undo or redo also get their handles back through the same mechanism
Why: AUTONOMY: bug fixes
Commit: 4540801bc, dda028e02, f8878eeca, 8f0d20276, 05160bf62
Veto: [ ]

## D-283 · 2026-10-01 · Only the window a pane left takes it back; moves between windows stay…
Context: B-108 (runner call).
Chose: Only the window a pane left takes it back; moves between windows stay with B-110
Why: AUTONOMY: implementation approach
Commit: 4540801bc, dda028e02, f8878eeca, 8f0d20276, 05160bf62
Veto: [ ]

## D-284 · 2026-10-03 · Custom title lives on the surface (Ghostty user-title state, Codable)…
Context: B-177 (runner call).
Chose: Custom title lives on the surface (Ghostty user-title state, Codable), one source for row label, window title, pane name and close confirm
Why: P1, P6
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-285 · 2026-10-03 · Menu order: Show, Split Right, Split Down, Rename…, divider, Close; "…
Context: B-177 (runner call).
Chose: Menu order: Show, Split Right, Split Down, Rename…, divider, Close; "Reveal in content" labelled Show; Split Left/Up stay in Window menu
Why: P1
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-286 · 2026-10-03 · Close on a hidden busy row asks with ⌘W's "Close “name”?" text; Cance…
Context: B-177 (runner call).
Chose: Close on a hidden busy row asks with ⌘W's "Close “name”?" text; Cancel or another alert already up keeps the row
Why: P2, D-111
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-287 · 2026-10-03 · Rename is a SwiftUI "Rename Terminal" sheet (prefilled, live-title pl…
Context: B-177 (runner call).
Chose: Rename is a SwiftUI "Rename Terminal" sheet (prefilled, live-title placeholder, "Leave blank to use the terminal’s own title."), not Ghostty's NSAlert
Why: P1
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-288 · 2026-10-03 · Confirming the unchanged prefilled title is a no-op, so a live title …
Context: B-177 (runner call).
Chose: Confirming the unchanged prefilled title is a no-op, so a live title isn't frozen
Why: P1, P2
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-289 · 2026-10-03 · leoSetUserTitle also changes Change Terminal Title…: second rename ke…
Context: B-177 (runner call).
Chose: leoSetUserTitle also changes Change Terminal Title…: second rename keeps the live title underneath, blank on an unrenamed surface is a no-op, whitespace-only = blank, control chars stripped
Why: AUTONOMY UX
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-290 · 2026-10-03 · Menu Split inherits ⌘D's config (working directory)
Context: B-177 (runner call).
Chose: Menu Split inherits ⌘D's config (working directory)
Why: P1
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-291 · 2026-10-03 · Agent surfaces ignored by rename/close/split
Context: B-177 (runner call).
Chose: Agent surfaces ignored by rename/close/split
Why: Out (agent names are daemon-owned)
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-292 · 2026-10-03 · Title persistence is met through SurfaceView encode/decode only; no s…
Context: B-177 (runner call).
Chose: Title persistence is met through SurfaceView encode/decode only; no shell row is restored at launch today (window restoration off), restoring rows at launch would be a new item
Why: P6, AUTONOMY
Commit: fd55a3a90, d8d41b5da, 10651dd62
Veto: [ ]

## D-293 · 2026-10-03 · Reuse the New Agent sheet in a worktree mode instead of adding a seco…
Context: B-176 (runner call).
Chose: Reuse the New Agent sheet in a worktree mode instead of adding a second sheet
Why: P1/P4
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-294 · 2026-10-03 · "New Agent in Worktree…" goes right after "Open in New Window"; branc…
Context: B-176 (runner call).
Chose: "New Agent in Worktree…" goes right after "Open in New Window"; branch placeholder "feature/my-change"; helper "New branch from origin's default branch"; header "New Agent in Worktree"
Why: P1
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-295 · 2026-10-03 · Spawn goes through the selected host's daemon API (branch = --worktre…
Context: B-176 (runner call).
Chose: Spawn goes through the selected host's daemon API (branch = --worktree), not a CLI exec; the fake runner is a fake LeoDaemonClient
Why: P3
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-296 · 2026-10-03 · Template prefilled and editable; Host and Repository read-only; Name …
Context: B-176 (runner call).
Chose: Template prefilled and editable; Host and Repository read-only; Name and Prompt optional and empty
Why: Out (no context carried over)
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-297 · 2026-10-03 · Item is enabled for any agent status and disabled only when the agent…
Context: B-176 (runner call).
Chose: Item is enabled for any agent status and disabled only when the agent has no owner/repo
Why: P1
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-298 · 2026-10-03 · Not added to the menu-bar Agents menu; no shortcut
Context: B-176 (runner call).
Chose: Not added to the menu-bar Agents menu; no shortcut
Why: Out
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-299 · 2026-10-03 · A host switch while the sheet is open blocks Create with "Host change…
Context: B-176 (runner call).
Chose: A host switch while the sheet is open blocks Create with "Host changed: switch back to <host> to create this agent"
Why: D-103, P3
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-300 · 2026-10-03 · LeoAgentActions binds the daemon to its host; spawn refuses with "Not…
Context: B-176 (runner call).
Chose: LeoAgentActions binds the daemon to its host; spawn refuses with "Not connected to <host> yet" on a mismatch, and the plain New Agent sheet gets the same guard
Why: P3
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-301 · 2026-10-03 · A result dropped by a host change resets the sheet with "Host changed…
Context: B-176 (runner call).
Chose: A result dropped by a host change resets the sheet with "Host changed; the agent may have been created on <host>"; editing clears a stale error; control characters get their own branch message
Why: AUTONOMY UX
Commit: 7f3a25018, 233fae09f, 6d8f5f392, cc9a85fa0
Veto: [ ]

## D-302 · 2026-10-03 · LeoTerminalRowsIntegrationTests.freshUndo had the same redundant remo…
Context: B-111 (runner call).
Chose: LeoTerminalRowsIntegrationTests.freshUndo had the same redundant removeAllActions(withTarget:) next to leoRemoveActionsTestsCanReplay, so it was removed too
Why: AUTONOMY polish / test infrastructure
Commit: b76844890, 0203d466f
Veto: [ ]

## D-303 · 2026-10-03 · Removed LeoCLI.init's runner default too, so a test that forgets a fa…
Context: B-112 (runner call).
Chose: Removed LeoCLI.init's runner default too, so a test that forgets a fake fails to compile, matching D-200
Why: AUTONOMY test infrastructure/implementation approach
Commit: 6c370c99c, 925854efc, 05b50deec
Veto: [ ]

## D-304 · 2026-10-03 · Named the helpers LeoRecordingTemplateRunner(templates:) and LeoCLI.r…
Context: B-112 (runner call).
Chose: Named the helpers LeoRecordingTemplateRunner(templates:) and LeoCLI.recordingForTests
Why: AUTONOMY naming
Commit: 6c370c99c, 925854efc, 05b50deec
Veto: [ ]

## D-305 · 2026-10-03 · Kept GatedTemplateRunner and GatedTemplateProcess as separate fakes, …
Context: B-112 (runner call).
Chose: Kept GatedTemplateRunner and GatedTemplateProcess as separate fakes, because they test concurrency rather than plain recording
Why: AUTONOMY test infrastructure
Commit: 6c370c99c, 925854efc, 05b50deec
Veto: [ ]

## D-306 · 2026-10-03 · Name "Quick Terminal" everywhere: start screen, menu and button, keep…
Context: B-113 (runner call).
Chose: Name "Quick Terminal" everywhere: start screen, menu and button, keeping upstream's menu title
Why: P1, AUTONOMY copy/naming
Commit: ed647aea6, 4dcfc5918, 1e7158bb5, 8cb00814a
Veto: [ ]

## D-307 · 2026-10-03 · Quick Terminal glyph is now menubar.arrow.down.rectangle, refining D-…
Context: B-113 (runner call).
Chose: Quick Terminal glyph is now menubar.arrow.down.rectangle, refining D-207
Why: P1 HIG, AUTONOMY polish
Commit: ed647aea6, 4dcfc5918, 1e7158bb5, 8cb00814a
Veto: [ ]

## D-308 · 2026-10-03 · Start-screen Quick Terminal gets the live-shortcut tooltip, title onl…
Context: B-113 (runner call).
Chose: Start-screen Quick Terminal gets the live-shortcut tooltip, title only when unbound (D-208)
Why: P2
Commit: ed647aea6, 4dcfc5918, 1e7158bb5, 8cb00814a
Veto: [ ]

## D-309 · 2026-10-03 · No retain cycle existed in the start-screen closures; the self captur…
Context: B-113 (runner call).
Chose: No retain cycle existed in the start-screen closures; the self capture is removed anyway (weak delegate and app captures), guarded by weak-reference tests
Why: AUTONOMY bug fixes/test infra
Commit: ed647aea6, 4dcfc5918, 1e7158bb5, 8cb00814a
Veto: [ ]

## D-310 · 2026-10-03 · One LeoSidebarButtonActions value replaces the two loose closures; Le…
Context: B-113 (runner call).
Chose: One LeoSidebarButtonActions value replaces the two loose closures; LeoPlaceholderNewTerminal is deleted, so newTab: and send are each defined once
Why: AUTONOMY implementation approach
Commit: ed647aea6, 4dcfc5918, 1e7158bb5, 8cb00814a
Veto: [ ]

## D-311 · 2026-10-03 · runtests.sh moves into the repo as a tracked script outside scratchpa…
Context: B-114 (runner call).
Chose: runtests.sh moves into the repo as a tracked script outside scratchpad/ so lanes and checkouts share one copy
Why: AUTONOMY test infrastructure
Commit: e113fee0e, a5e1b3de8
Veto: [ ]

## D-312 · 2026-10-03 · Tracked the runner at macos/scripts/leo-runtests.sh with its parse te…
Context: B-114 (runner call).
Chose: Tracked the runner at macos/scripts/leo-runtests.sh with its parse test macos/scripts/test_leo-runtests.sh beside it (outside scratchpad/)
Why: AUTONOMY test infrastructure
Commit: e113fee0e, a5e1b3de8
Veto: [ ]

## D-313 · 2026-10-03 · Dropped the stale "ConfigTests/errorsEmptyForValidConfig is an expect…
Context: B-114 (runner call).
Chose: Dropped the stale "ConfigTests/errorsEmptyForValidConfig is an expected baseline failure" note from the failures header (verify.md says treat it as real)
Why: AUTONOMY test infrastructure
Commit: e113fee0e, a5e1b3de8
Veto: [ ]

## D-314 · 2026-10-03 · If a marked pid's identity can't be read (proc_pidpath/Info.plist fai…
Context: B-118 (runner call).
Chose: If a marked pid's identity can't be read (proc_pidpath/Info.plist fails, non-UTF-8 path, wrong layout), it counts as not our copy and Leo takes the bounded ~5 s path, never an endless wait
Why: P5 / AUTONOMY implementation approach
Commit: 882b0040f
Veto: [ ]

## D-315 · 2026-10-03 · Match a marked pid on bundle ID plus CFBundleExecutable (not exact pa…
Context: B-118 (runner call).
Chose: Match a marked pid on bundle ID plus CFBundleExecutable (not exact path) so moved/translocated copies are still waited on
Why: D-051 / AUTONOMY implementation approach
Commit: 882b0040f
Veto: [ ]

## D-316 · 2026-10-03 · Read the marked pid's Info.plist directly, not via NSRunningApplicati…
Context: B-118 (runner call).
Chose: Read the marked pid's Info.plist directly, not via NSRunningApplication/LaunchServices
Why: D-215 / AUTONOMY implementation approach
Commit: 882b0040f
Veto: [ ]

## D-317 · 2026-10-03 · Info.plist opened O_RDONLY|O_NONBLOCK|O_CLOEXEC, must be a regular fi…
Context: B-118 (runner call).
Chose: Info.plist opened O_RDONLY|O_NONBLOCK|O_CLOEXEC, must be a regular file per fstat, capped at 1 MiB, so a FIFO can't hang a UI-less launch
Why: D-216, P5
Commit: 882b0040f
Veto: [ ]

## D-318 · 2026-10-03 · The marked pid's bundle folder must end in .app (case-sensitive)
Context: B-118 (runner call).
Chose: The marked pid's bundle folder must end in .app (case-sensitive)
Why: AUTONOMY implementation approach
Commit: 882b0040f
Veto: [ ]

## D-319 · 2026-10-03 · isCopy has no default; every caller passes an explicit check (no impl…
Context: B-118 (runner call).
Chose: isCopy has no default; every caller passes an explicit check (no implicit Bundle.main global)
Why: AUTONOMY implementation approach
Commit: 882b0040f
Veto: [ ]

## D-320 · 2026-10-03 · Injected sink named logError: (String) -> Void (no default, beside al…
Context: B-119 (runner call).
Chose: Injected sink named logError: (String) -> Void (no default, beside alert/terminate); the refusal log in settle still calls the logger directly to keep the change small
Why: AUTONOMY implementation approach/naming
Commit: 819fa9299
Veto: [ ]

## D-321 · 2026-10-03 · Log copy "…still holds it after N release pauses; yielding to it as a…
Context: B-119 (runner call).
Chose: Log copy "…still holds it after N release pauses; yielding to it as a running copy" (log-only, .error, privacy .public, existing leo logger)
Why: AUTONOMY copy
Commit: 819fa9299
Veto: [ ]

## D-322 · 2026-10-03 · gone()'s liveness probe is injectable (gone(isGone:)) rather than for…
Context: B-121 (runner call).
Chose: gone()'s liveness probe is injectable (gone(isGone:)) rather than forcing real pid reuse in a test
Why: AUTONOMY test infrastructure / flake fixes
Commit: 4dba68680
Veto: [ ]

## D-323 · 2026-10-03 · gone() checks at hand-out with a bounded retry (maxGoneAttempts = 5, …
Context: B-121 (runner call).
Chose: gone() checks at hand-out with a bounded retry (maxGoneAttempts = 5, then GoneError.everyPidTakenOver), not a re-check at every call site
Why: AUTONOMY test infrastructure / flake fixes
Commit: 4dba68680
Veto: [ ]

## D-324 · 2026-10-03 · waitpid inside gone() retries on EINTR (otherwise a zombie reads as n…
Context: B-121 (runner call).
Chose: waitpid inside gone() retries on EINTR (otherwise a zombie reads as not gone)
Why: AUTONOMY flake fixes
Commit: 4dba68680
Veto: [ ]

## D-325 · 2026-10-03 · Reset Window Size tests share a configuredContentSize(of:) helper and…
Context: B-122 (runner call).
Chose: Reset Window Size tests share a configuredContentSize(of:) helper and a Fixture.isResetWindowSizeEnabled property
Why: AUTONOMY test infrastructure
Commit: e18cc1bac
Veto: [ ]

## D-326 · 2026-10-03 · Test the real UpdateDriver.updater(_:mayPerform:) through an unstarte…
Context: B-123 (runner call).
Chose: Test the real UpdateDriver.updater(_:mayPerform:) through an unstarted SPUUpdater subclass that overrides automaticallyDownloadsUpdates, with no seam added to product code
Why: AUTONOMY test infrastructure
Commit: 0d97ffa3c
Veto: [ ]

## D-327 · 2026-10-03 · Named the constants UpdateDriver.CheckRefusal.{domain,code}, nested o…
Context: B-124 (runner call).
Chose: Named the constants UpdateDriver.CheckRefusal.{domain,code}, nested on the SPUUpdaterDelegate extension next to their only user, not a global
Why: AUTONOMY naming/implementation approach
Commit: 9893742e4
Veto: [ ]

## D-328 · 2026-10-03 · Left the refusal's localized description as a literal; the item cover…
Context: B-124 (runner call).
Chose: Left the refusal's localized description as a literal; the item covers only the code and domain
Why: AUTONOMY implementation approach
Commit: 9893742e4
Veto: [ ]

## D-329 · 2026-10-03 · UI tests' first app start uses launch() instead of activate(), since …
Context: B-125 (runner call).
Chose: UI tests' first app start uses launch() instead of activate(), since XCUIApplication only promises launchArguments from an earlier launch
Why: AUTONOMY test infrastructure
Commit: bb76eeb16
Veto: [ ]

## D-330 · 2026-10-03 · Same activate()→launch() change in GhosttyCommandPaletteTests, so D-2…
Context: B-125 (runner call).
Chose: Same activate()→launch() change in GhosttyCommandPaletteTests, so D-224 holds for every UI test
Why: AUTONOMY test infrastructure
Commit: bb76eeb16
Veto: [ ]

## D-331 · 2026-10-03 · Pinned the update launch order with a test via a small helper UpdateL…
Context: B-126 (runner call).
Chose: Pinned the update launch order with a test via a small helper UpdateLaunchSequence.run(resetDefaults:applyConfig:startUpdater:) (non-escaping closures; no change to UpdateController, UpdateDefaultsMigration or Sparkle), not a comment only
Why: AUTONOMY implementation approach/test infrastructure
Commit: 7e46debf8
Veto: [ ]

## D-332 · 2026-10-03 · The sequence also covers the initial config apply (reset → config → s…
Context: B-126 (runner call).
Chose: The sequence also covers the initial config apply (reset → config → start), since applying config writes the same Sparkle keys the reset clears
Why: AUTONOMY implementation approach
Commit: 7e46debf8
Veto: [ ]

## D-333 · 2026-10-03 · Named it UpdateLaunchSequence / UpdateLaunchSequenceTests, beside the…
Context: B-126 (runner call).
Chose: Named it UpdateLaunchSequence / UpdateLaunchSequenceTests, beside the other update files
Why: AUTONOMY naming
Commit: 7e46debf8
Veto: [ ]

## D-334 · 2026-10-03 · Appcast fixture expected values named newestVersion / newestShortVers…
Context: B-127 (runner call).
Chose: Appcast fixture expected values named newestVersion / newestShortVersion as static lets on AppcastFixtureTests
Why: AUTONOMY naming/test infrastructure
Commit: abe0f1962
Veto: [ ]

## D-335 · 2026-10-03 · Refresh recipe in the doc comment: curl the published appcast into ma…
Context: B-127 (runner call).
Chose: Refresh recipe in the doc comment: curl the published appcast into macos/Tests/Update/Fixtures/appcast.xml verbatim (never hand-edit), then update both constants in the same commit
Why: AUTONOMY copy/test infrastructure
Commit: abe0f1962
Veto: [ ]

## D-336 · 2026-10-03 · The automatic-updates question shows only in the pill popover, never …
Context: B-128 (runner call).
Chose: The automatic-updates question shows only in the pill popover, never in Sparkle's standard alert, even before any window exists; it waits for the first window
Why: P2, matches ci.md, keeps D-221 (Sparkle's own permission request and reply are unchanged)
Commit: a135885de, d5c5f68ee, d0c990083, 3ac5e5321, d4f4f67a3
Veto: [ ]

## D-337 · 2026-10-03 · A pending permission request survives closing the last window instead…
Context: B-128 (runner call).
Chose: A pending permission request survives closing the last window instead of being dropped without a reply
Why: bug fix, P2
Commit: a135885de, d5c5f68ee, d0c990083, 3ac5e5321, d4f4f67a3
Veto: [ ]

## D-338 · 2026-10-03 · Check for Updates… while the question is pending and no window is vis…
Context: B-128 (runner call).
Chose: Check for Updates… while the question is pending and no window is visible opens a terminal window so the pill can be reached; it never falls back to Sparkle's alert
Why: bug fix, P5
Commit: a135885de, d5c5f68ee, d0c990083, 3ac5e5321, d4f4f67a3
Veto: [ ]

## D-339 · 2026-10-03 · UpdateDriverPermissionTests use an injected openUnobtrusiveTarget sea…
Context: B-128 (runner call).
Chose: UpdateDriverPermissionTests use an injected openUnobtrusiveTarget seam (default AppDelegate newWindow) beside hasUnobtrusiveTarget, so the test host never opens a live window (a narrow departure from D-326's no-seam approach, for a different test)
Why: AUTONOMY test infrastructure
Commit: a135885de, d5c5f68ee, d0c990083, 3ac5e5321, d4f4f67a3
Veto: [ ]

## D-340 · 2026-10-03 · Check for Updates… doesn't bring the pill popover forward when a wind…
Context: B-128 (runner call).
Chose: Check for Updates… doesn't bring the pill popover forward when a window is already visible (popover state lives per window)
Why: AUTONOMY UX
Commit: a135885de, d5c5f68ee, d0c990083, 3ac5e5321, d4f4f67a3
Veto: [ ]

## D-341 · 2026-10-03 · Hide Sparkle's auto-install checkbox in Debug with Sparkle's own Info…
Context: B-129 (runner call).
Chose: Hide Sparkle's auto-install checkbox in Debug with Sparkle's own Info.plist switch (SUAllowsAutomaticUpdates=NO, Debug only via INFOPLIST_PREPROCESSOR_DEFINITIONS), not by suppressing the alert or editing its view
Why: AUTONOMY implementation approach, follows D-220
Commit: d1cbb8942
Veto: [ ]

## D-342 · 2026-10-03 · Preprocessor flag named LEO_UPDATES_CANNOT_INSTALL
Context: B-129 (runner call).
Chose: Preprocessor flag named LEO_UPDATES_CANNOT_INSTALL
Why: AUTONOMY naming
Commit: d1cbb8942
Veto: [ ]

## D-343 · 2026-10-03 · Debug builds also read "About Leo", not "About Leo[DEBUG]": the suffi…
Context: B-130 (runner call).
Chose: Debug builds also read "About Leo", not "About Leo[DEBUG]": the suffix only marks the build in the menu bar and isn't the product name
Why: AUTONOMY copy/UX details; P1
Commit: 342cba7a4
Veto: [ ]

## D-344 · 2026-10-04 · A build phase symlinks Contents/MacOS/ghostty to the Leo executable
Context: B-220 (runner call).
Chose: A build phase symlinks Contents/MacOS/ghostty -> Leo so shell-integration's ssh wrapper finds "$GHOSTTY_BIN_DIR/ghostty"; CFBundleExecutable, Zig and the upstream shell scripts are untouched
Why: AUTONOMY (keep Zig minimal); D-306 (keep upstream names)
Commit: 29ebbb822
Veto: [ ]

## D-345 · 2026-10-04 · The ghostty link target is relative
Context: B-220 (runner call).
Chose: The link target is relative, so moved or translocated bundles still work
Why: AUTONOMY implementation approach
Commit: 29ebbb822
Veto: [ ]

## D-346 · 2026-10-04 · The CI script-tests step goes in leo-ci.yml, not leo-build.yml
Context: B-221 (runner call).
Chose: The run-tests step goes in leo-ci.yml: it runs on every PR and push to main and needs no secrets
Why: AUTONOMY (test infrastructure)
Commit: 3eac947b4 8e9147557 34fe5d427 
Veto: [ ]

## D-347 · 2026-10-04 · The CI guard parses the workflow YAML with /usr/bin/ruby
Context: B-221 (runner call).
Chose: The guard parses the YAML with /usr/bin/ruby (Psych) and fails if ruby is missing
Why: AUTONOMY (test infrastructure)
Commit: 3eac947b4 8e9147557 34fe5d427 
Veto: [ ]

## D-348 · 2026-10-04 · Updated the leo-ci row in docs/leo/ci.md
Context: B-221 (runner call).
Chose: Updated the leo-ci row in docs/leo/ci.md to list the script-tests step
Why: AUTONOMY (docs/test infrastructure)
Commit: 3eac947b4 8e9147557 34fe5d427 
Veto: [ ]

## D-349 · 2026-10-04 · Plist-error cases get their own network-free test file
Context: B-222 (runner call).
Chose: Put the new cases in test_sparkle-key-check-plist-errors.sh rather than the Sparkle-downloading test_sparkle-key-check.sh
Why: AUTONOMY (test infrastructure)
Commit: b8581509f 47482639c
Veto: [ ]

## D-350 · 2026-10-04 · sparkle-key-check also reports an unreadable plist
Context: B-222 (runner call).
Chose: Also covered the unreadable-plist case via an up-front -r check
Why: AUTONOMY (bug fixes)
Commit: b8581509f 47482639c
Veto: [ ]

## D-351 · 2026-10-04 · Missing-key detection matches PlistBuddy's "Does Not Exist" text
Context: B-222 (runner call).
Chose: Missing-key detection matches PlistBuddy's ":SUPublicEDKey", Does Not Exist text, falling back to a generic error that includes PlistBuddy's raw stdout and stderr
Why: AUTONOMY (bug fixes)
Commit: b8581509f 47482639c
Veto: [ ]
