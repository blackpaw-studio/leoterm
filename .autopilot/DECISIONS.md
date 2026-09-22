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
Commit:
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
Chose: accepted leo's terms: needs_input from Claude only at first (Codex/opencode go working→finished; absence of needs_input = "not detectable"); revision resets per daemon lifetime, plus a requested daemon boot id in hello to trigger re-baseline; `unknown` after a daemon restart until the next hook; unexpected exit (any code) → errored, explicit stop/suspend incl. idle-suspend → unknown; supervised agents only; field absent on existing agents until respawn. Update: Evan approved the daemon spec (/Users/evan/.leo/workspace/docs/specs/2026-09-22-agent-attention.md) incl. `boot_id` on SSE hello; re-emitting the same state (finished→finished across turns) still bumps revision. Leo is planning; will ping when on main.
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
