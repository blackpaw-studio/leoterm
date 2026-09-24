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
