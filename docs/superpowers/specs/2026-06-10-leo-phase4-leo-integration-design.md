# Phase 4 — Leo integration (board model + daemon)

**Date:** 2026-06-10
**Status:** Approved design; implementation plan to follow under `docs/superpowers/plans/`.
**Refines:** `docs/superpowers/specs/2026-06-08-leo-terminal-design.md` §4 (Leo integration — the board model).

## Context

Phases 1–3.5 are on `main`: the grid engine renders Ghostty's surfaces as an
auto-packing grid, and a cell can attach to a live Leo agent via
`CellSource.agent(name:)` → `leo agent attach --cc <name>`, rendering and
forwarding keystrokes through the tmux control-mode `Viewer`. What is missing is
any **UI to discover and manage** agents — today a cell's source must be set
programmatically. Phase 4 is the Leo integration layer that closes that gap:
enumerate the daemon's agents, put them on a board, spawn/stop them, and
persist/restore boards across launches.

This is the phase that delivers the product's core value (a managed wall of
live agents), so it is built as **one phase** rather than sliced.

## Daemon API — verified against the live daemon (leo 0.6.2)

The Leo daemon runs two HTTP servers:

- **Daemon unix socket** `~/.leo/state/leo.sock` (perms `0600`, owner-only).
  Speaks HTTP/1.1 + JSON with a `{"ok": bool, "error": string, "data": …}`
  envelope. **No token required** — unix-socket file permissions are the auth.
  Routes used by Phase 4:
  - `GET  /agents/list` → `[Agent]`
  - `POST /agents/spawn` (body `{template, repo, name?, branch?, base?}`; template
    and repo required) → `Agent`
  - `POST /agents/{name}/stop`
  - `POST /agents/{name}/prune`
  - (available, not yet needed: `/agents/{name}/logs`, `/agents/{name}/session`,
    `/agents/resolve`)
- **Web UI** on `:8370` — network-facing, token-auth. Not used by leoterm.

`Agent` JSON shape (from `GET /agents/list`):
`{ name, template, repo, workspace, status: "running"|"stopped", started_at, env }`.

**Templates gap:** the daemon socket exposes **no** template route. Templates
come from `leo template list --json` (CLI), shape `[{ name, workspace }]`. This
is the single sanctioned CLI shell-out; everything else goes over the socket.

## Transport — `LeoDaemon` protocol + `LeoSocketClient`

- `LeoDaemon` is the DI seam (`Sendable` protocol):
  `listAgents()`, `spawn(_:) `, `stop(name:)`, `prune(name:)`, `listTemplates()`.
- `LeoSocketClient` is the production implementation: a minimal HTTP/1.1 client
  over `Network.framework`'s `NWConnection(to: .unix(path:))`. We hand-roll the
  request/response (GET/POST JSON) rather than pull in swift-nio — the surface
  is small and Foundation's `URLSession` has no unix-socket support.
  - Decodes the envelope; maps `ok == false` / transport failures to a typed
    `throws(LeoError)`.
  - `listTemplates()` is the one method that shells out (`leo template list
    --json`), isolated behind the same protocol so callers stay agnostic.
  - Socket path is injectable; defaults to `~/.leo/state/leo.sock` (overridable
    via the `leo` config section, per spec §6).

## Models

Value types matching the live JSON, `Codable`, `Sendable`:

- `Agent { name, template, repo, workspace, status: AgentStatus, startedAt, env }`
  where `AgentStatus = .running | .stopped`.
- `Template { name, workspace }`.

These model the **lifecycle** view of an agent. The richer **activity** status
(working / idle / needs-you) is *not* a daemon concept — it derives from each
attached cell's tmux control-mode stream and is Phase 5.

## State — `LeoAgentStore`

An `@Observable` view-model backed by an actor for its mutable cache:

- Holds the latest `[Agent]` and `[Template]`.
- **Refresh model:** the daemon has no event stream (request/response only), so
  the roster is poll-based. Poll `GET /agents/list` every ~3s **while the
  sidebar is visible**; refresh immediately after spawn/stop/attach actions and
  on window focus; expose a manual refresh affordance. Polling a local socket
  with a small JSON body is cheap.
- Injected with a `LeoDaemon` (mock in tests).
- Surfaces a "daemon offline" state when the socket is unreachable, without
  tearing down the grid.

## Board model — `Board` / `BoardCell`

- `Board { id, name, cells: [BoardCell] }`.
- `BoardCell { source: CellSource, layout: CellLayoutState, lastKnownAgent: AgentSnapshot? }`
  where `CellLayoutState` mirrors the grid's persisted per-cell state (slot
  order, pinned size) and `AgentSnapshot` captures `{name, repo}` so a dead cell
  can render meaningfully.
- A board maps to a Ghostty **tab**. Phase 4 scope: **one board per tab**;
  "new board" = new tab. Multi-window / drag-to-Space is Phase 6.

### Cell ownership — reuse, don't reinvent

`TerminalGridView` renders Ghostty's existing `SplitTree<SurfaceView>`; it does
not own a separate cell list. Therefore:

- **Add an agent** = build a `SurfaceView` from
  `CellSource.agent(name:).surfaceConfiguration` and insert it as a new leaf via
  the existing `TerminalSplitOperation` path.
- **Close a cell** = remove that leaf (= detach; the agent keeps running).

Phase 4 adds a `SurfaceView.ID → CellSource` mapping (side-table or a property
on the surface) so the app can: persist each cell's source, answer "is this
agent already on the board?" in the sidebar, and render dead cells on restore.

### Persistence & restore

- **Storage:** `Codable` JSON at `~/Library/Application Support/Leo/boards.json`.
  leoterm stores only **view state** (which agents on which board, sizes, pin
  flags); agent lifecycle stays daemon-owned (spec §6).
- **Save:** debounced write on any board mutation.
- **Restore on launch:** load boards, then reconcile each saved cell's
  `lastKnownAgent.name` against a live `GET /agents/list`:
  - agent present & running → attach normally;
  - **agent missing or stopped → dead cell**: a greyed placeholder that keeps
    its slot and size and offers **respawn** (re-spawn from the snapshot's
    template+repo) and **remove**. No silent data loss.

## Sidebar — `LeoSidebarView`

SwiftUI (matching the existing `Command Palette` stack), togglable side panel:

- **Running agents** section: each row shows name · repo · a lifecycle dot
  (running/stopped) · an on-board indicator. Click → insert a cell on the
  current board. Context action: **Stop** (`POST /agents/{name}/stop`).
- **Templates** section: **New Agent** → sheet to pick template + repo (+
  optional branch) → `spawn` → land the new agent on the board.
- **New terminal cell** → insert a `PTYSource` (`$SHELL`) leaf.
- Toggle via menu item + keybind.

## Command-palette entries

Register into the existing `TerminalCommandPalette`: "Attach agent…", "Spawn
agent…", "New terminal cell", "Toggle sidebar" — all routing to the same
`LeoAgentStore` / board actions the sidebar uses (no duplicated logic).

## Lifecycle (daemon-owned, "model A")

- Close a cell = **detach** (remove leaf; agent keeps running in the daemon).
- **Stop** an agent is separate and explicit.
- Quitting persists boards; agents continue running.
- Relaunch re-discovers running agents and restores saved boards (with the
  dead-cell reconciliation above).

## Data flow

```
LeoSocketClient ──> LeoAgentStore (cache + poll) ──> LeoSidebarView (roster)
                                                          │ click / spawn
                                                          ▼
                              Board inserts SurfaceView from CellSource.agent
                                                          │
                                                          ▼
                              tmux control-mode render + input (Phase 3/3.5)

Board mutation ──debounced──> boards.json
Launch ──> load boards ──> reconcile vs GET /agents/list ──> attach | dead cell
```

## Error handling

- **Daemon unreachable** (no socket / connection refused): sidebar shows a
  non-blocking "daemon offline" state; the grid and any PTY cells keep working
  (clean degradation to a plain terminal grid, spec §1).
- **Spawn failures** (repo missing, name collision): surfaced inline in the
  spawn sheet with the daemon's error message.
- All transport surfaces a typed `LeoError`; no silent swallowing.

## Testing

- **Unit — transport:** `LeoSocketClient` against a stub unix-socket HTTP
  server; envelope + model decoding from real-JSON fixtures; `LeoError` mapping.
- **Unit — store:** `LeoAgentStore` poll/refresh state machine with a mock
  `LeoDaemon` (offline → online transitions, post-action refresh).
- **Unit — board:** save/restore round-trip and reconciliation logic
  (pure, table-driven, including the dead-cell case), 80%+ on this logic.
- **Manual / E2E (on Dionysus, where the daemon socket is local):** add / close
  / spawn / stop; restore a board whose agent was killed while the app was
  closed. GUI feel is verified by Evan — it cannot be checked from the agent
  session (see `gui-verification-constraint`).

## Scope boundaries (explicitly deferred)

- Live **working / idle / needs-you** status dots, bell/hook detection,
  Dock/title badge → **Phase 5**.
- Hover modes B/C, focus-follows-mouse, **multi-window / multi-board across
  Spaces**, full `leo`-section config surface → **Phase 6**.

## Key risks

| Risk | Mitigation |
|------|------------|
| Swift has no native unix-socket HTTP client | Hand-rolled minimal HTTP/1.1 over `NWConnection.unix`; small, tested surface. |
| Daemon API drift (routes/shapes change) | All access behind `LeoDaemon`; fixtures captured from live daemon; envelope decoding fails loudly. |
| Template list only via CLI | Isolated single shell-out behind the protocol; low frequency (spawn sheet open). |
| Poll cadence causes churn | Poll only while sidebar visible; cheap local socket; event-driven refresh after actions. |
| `SurfaceView → CellSource` mapping leaks/drifts as leaves are added/removed | Single owner of the mapping, updated on the same insert/remove path as the tree. |
