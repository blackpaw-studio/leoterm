# Backlog

Ranked. Statuses: `ready`, `ready (next run)`, `blocked`, `done`.
Source roadmap: `docs/leo/roadmap.md` on `main` (not edited by autopilot).

## B-001 · Attention model, app side   [ready]
Accept: implement docs/superpowers/specs/2026-09-21-leo-attention-model.md with
D-005 answers (tab focus acks Dock count, row badge stays; focused split =
viewing; ⌃⌥⌘J jump). `LeoAttentionReducer` value type, fixture-driven tests
for every transition. Legacy daemons show Working only. Screenshot row badges
using fixture/scratch data.
Source: roadmap Tier 1

## B-002 · Request daemon `attention` field from the leo agent   [ready]
Accept: send the leo agent the exact contract from the spec's "Leo-daemon
prerequisite" section; log the reply/ETA in DECISIONS.md. No leo repo edits.
Source: attention spec; D-006

## B-003 · File access layer (local FS + SFTP)   [ready]
Accept: one `LeoFileAccess` protocol, local backend and SFTP backend over the
existing SSH ControlMaster for the selected host; list dir, read, write
(atomic), stat/mtime conflict check. Tests with a local sshd or fake.
Source: Evan, vision session; D-003, D-007

## B-004 · Editor pane for surfaced files   [ready]
Accept: ⌘-click a path / OSC 8 link in an agent's terminal opens it in a Leo
editor pane (syntax highlight, edit, ⌘S save, external-change detection).
Relative paths resolve against the agent's workspace. Works local and remote.
Source: Evan, vision session; D-007

## B-005 · Per-agent workspace browser   [ready]
Accept: from a sidebar row (context menu + shortcut), browse the agent's
workspace tree via B-003 and open files in B-004's pane. Keyboard navigable.
Source: Evan, vision session; D-007

## B-006 · Tab ↔ row linkage   [ready]
Accept: highlighted row follows the focused attach tab; tab-count glyph on rows
with live tabs; clicking a highlighted row focuses its tab.
Source: roadmap Tier 2

## B-007 · Disconnected state   [ready]
Accept: on tunnel drop or wake, grey the list and show a Retry banner instead
of stale rows. Manual retry only.
Source: roadmap Tier 2

## B-008 · Fix order-dependent test flake + swiftlint baseline   [ready]
Accept: `LeoHostSelectionReloadTests.editingAnUnrelatedHostDoesNotReselect`
passes 10/10 in full serial runs (pid-file read race in
`LeoHostSelectionTestSupport`); clear the 3 `large_tuple` violations in
`macos/Tests/Leo/LeoAttachCoordinatorTests.swift:316-319`.
Source: roadmap Test infra; vision-session test run

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
