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
