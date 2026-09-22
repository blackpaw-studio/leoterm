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
Commit:
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
