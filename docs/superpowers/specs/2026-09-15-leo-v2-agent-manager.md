# Leo v2 — Native Agent Manager on Ghostty (design spec)

**Date:** 2026-09-15 · **Status:** Draft, awaiting approval · **Supersedes:** `2026-06-08-leo-terminal-design.md`

## 1. Summary

Leo v2 is a macOS Ghostty fork with one addition: a native **Agents sidebar** that manages Leo daemon agents and opens attachments as ordinary terminal tabs. Ghostty's windows, tabs, splits, renderer, config, and Zig core are untouched.

Everything the v1 fork built to *render* agents (auto-grid, tmux control-mode renderer, boards, cell registry) is dropped. An attachment is a stock tmux client (`leo agent attach <name>`) running in a normal Ghostty surface.

### Goals
- Manage agents: list, spawn, start, stop, restart, set template, rename, delete, view logs.
- Attach to an agent in one action; focus the existing attachment if one is open.
- Raw terminal always one keystroke away (stock ⌘N / ⌘T).
- One host at a time, chosen from `leo host list`; remote via `leo host forward`.
- **Zero Zig changes.** Swift-only, isolated under `macos/Sources/Features/Leo/`, with surgical hooks into upstream files.

### Non-goals (v2.0)
- Wall/grid of live agents, control-mode rendering, boards, pinning, hover-grow.
- Native scrollback/search over tmux history (tmux copy mode is the scrollback).
- Multiple hosts visible simultaneously.
- Non-Leo agent providers.

## 2. Git setup

- Current `main` → renamed `legacy/grid` (pushed). Tag `legacy-grid-final` at its tip.
- New `main` branches from `upstream/main` (`d4c88d806`, 2026-09-15). App display name, bundle id, and icon changes re-applied as the first commit.
- v1 Swift files are ported **by file, after review**, never by cherry-picking commits. Candidates: `LeoSocketClient`, `LeoHTTP`, `LeoModels`, `LeoSSEParser`, `LeoActivityClient`, `LeoProcessRunner`, `LeoCLI`, `LeoHost*`, `LeoForwardManager`, `SpawnValidation`. Each ported file is re-verified against leo 0.27 before it lands.

## 3. Architecture

```
Ghostty macOS app (upstream, unmodified except hooks)
 └─ LeoSidebar (SwiftUI, per window, collapsible)
     ├─ LeoHostPicker      ── in-app hosts (UserDefaults) + LeoTunnel (ssh -N -L unix socket)
     ├─ LeoAgentList       ── GET /agents/list (poll) + SSE activity overlay
     ├─ LeoAgentActions    ── POST start/stop/restart/set-template/rename, DELETE
     ├─ SpawnAgentSheet    ── POST /agents/spawn; templates from leo template list --json
     └─ AttachCoordinator  ── opens/focuses a tab running `leo agent attach` (local) or `ssh -t <target> <leo> agent attach` (remote)
```

### 3.1 Daemon contract (leo 0.27.0)
Unix socket `~/.leo/state/leo.sock`, HTTP/1.1, no auth. Routes used: `GET /agents/list`, `POST /agents/spawn`, `POST /agents/{name}/{start|stop|restart|set-template|rename}`, `DELETE /agents/{name}`, `GET /agents/{name}/logs`. Field shapes are read from `~/.leo/agents/leo/internal/daemon/server.go` and `internal/agent/manager.go` at implementation time and pinned in `LeoModels.swift` with decoding tests. Unknown fields are ignored; missing optional fields never fail decoding (the v0.19 lesson).

Activity (`working|idle|unknown`, `current_action`) comes from the observability SSE endpoint (`web.bind:port`, bearer `~/.leo/state/api.token`). Activity is an overlay: if the endpoint is unreachable the list still works with status only, and rows show no activity dot.

### 3.2 Hosts (revised 2026-09-16 13:50: app-owned SSH tunnels)

Decision (Evan, 2026-09-16 13:49, superseding the daemon-hub revision of the same morning): **the app owns one SSH tunnel to the selected remote host.** No local leo daemon is required to use remote hosts, and leo needs no hub. The reference pattern is openclaw's `RemotePortTunnel.swift` (~180 lines of launch + readiness logic); the abandoned `feat/m6-hosts` branch is *not* the reference — it failed five reviews on readiness protocols, coalesced switches, and retry timers, all of which are out of scope here.

Hosts:
- Configured in-app, stored as JSON in UserDefaults (`leo.hosts`), no secrets. Fields: `name` (unique, picker label), `sshTarget` (`user@host[:port]`), `identityFile?`, `remoteLeoPath` (default `~/.local/bin/leo`), `remoteSocketPath` (default `~/.leo/state/leo.sock`). Edited in a Hosts sheet opened from the host picker ("Manage Hosts…"): table + add/remove + form, validation on save (non-empty name/target, unique name). `localhost` is implicit and needs no entry.
- `leo host list --json` / leo.yaml `client.hosts` are no longer read.

Tunnel (`LeoTunnel`, a dumb process wrapper, no state machine of its own):
- `/usr/bin/ssh -n -N -o BatchMode=yes -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ControlMaster=no -o ControlPath=none -o StreamLocalBindUnlink=yes [-i identity] [-p port] -L <localSocket>:<remoteSocketPath> <target>`. Local socket lives under the app's Application Support dir: `hosts/<name>.sock`; any stale file is removed before launch. Only stderr is captured, capped at 4 KB.
- Readiness: probe `GET /health` on the local socket every 100 ms for up to 6 s. Early exit → error with the stderr tail; timeout → "tunnel did not become ready". No stderr parsing, no fixed delay.
- Failure surfaced verbatim plus one hint per class: host-key unknown → "run `ssh <target>` once in a terminal to accept the host key"; auth → "BatchMode needs a key or agent; try `ssh <target>` in a terminal".
- Orphans: pid + process start time + socket path are recorded in UserDefaults while the tunnel runs; at app launch any recorded pid whose start time still matches is sent SIGTERM, then SIGKILL after 1 s, and the record is cleared. App quit terminates the tunnel and waits for exit.

Selection (`LeoHostSelection`, `@MainActor`, generation-guarded):
- States per selected host: `connecting`, `connected(socket)`, `failed(message)`. Localhost is always `connected(~/.leo/state/leo.sock)`.
- Selecting a host: bump generation, terminate the previous tunnel (wait for exit), start the new one, await readiness, publish `connected` unless the generation moved on. Only one tunnel exists at any time.
- Tunnel exit after readiness → `failed` with the stderr tail and a Retry button. **No auto-reconnect, no backoff, no timers.** Retry = select the host again.
- The sidebar feed targets `(host, generation, socketPath)`; a `failed` host shows the last rows greyed with the panel-level error.

Remote CLI calls (templates only): `ssh [-i identity] [-p port] -o BatchMode=yes <target> <remoteLeoPath> template list --json`. Until leo ≥0.29 ships `GET /templates` on the socket, this is the only per-host ssh exec. Activity: leo ≥0.29 serves `GET /events` / `GET /state` on the unix socket (no token), which the tunnel carries for free; on older remotes there is no activity overlay (status only).

### 3.3 Attach
- Action: double-click a row, Return on a selected row, or the row's Attach button. Opens a **new tab in the current window** with the surface command set to the attach argv (structured arguments, no shell string). ⌥-attach opens a new window instead.
- Identity: `(host, agentName)`. The coordinator keeps a map from identity to surface; attaching an already-open identity focuses that tab. Closing the tab removes the mapping and detaches the tmux client only. **Closing never stops or deletes an agent.**
- Environment for the attach process: inherited app env with `TMUX` and `TMUX_PANE` removed; `leo` resolved to an absolute path (`~/.local/bin/leo`, overridable via Ghostty config key `leo-path`).
- Remote attach (2026-09-16): the tab runs `ssh -t [-i identity] [-p port] '<target>' '<remoteLeoPath>' agent attach -- '<agent>'` directly; no local `leo --host`, no ControlPath sharing with the tunnel. Host-key and auth prompts stay visible in the tab.
- Tab title: `agent · host` set via the surface's title; the attached shell's own title changes are allowed to override it.

### 3.4 Agent list rows
Name, template, status badge (`running` / `stopped` / `starting`), activity dot (green working, grey idle, none unknown), one-line `current_action.detail`. Sorted: working first, then running, then stopped, alphabetical within. Search field filters by name and template.

Row context menu: Attach, Start/Stop (whichever applies), Restart, Set Template ▸ (submenu from template list), Rename…, View Logs (opens a tab running `leo [--host h] agent logs -f <name>`), Delete… (confirmation sheet; the daemon's delete-plan text is shown if the route returns one).

### 3.5 Spawn sheet
Fields: template (required, picker), repo (directory picker + text), name (optional), branch (optional), prompt (optional multiline). Validation mirrors the daemon's rules (name charset, template exists). On success the sheet closes and the new agent is attached automatically.

### 3.6 Sidebar chrome
- Toggle: ⌘⇧L and View ▸ Toggle Agents Sidebar. Width persisted. Default visible on first launch.
- New Agent: ⌘⇧A. Raw terminal: stock ⌘N / ⌘T (no Leo involvement).
- Daemon unreachable: sidebar shows a single state view with the error and a "Start daemon" button that runs `leo service start` in a new tab.

### 3.7 Upstream hooks (the only edits to upstream files)
1. Window controller: host the sidebar beside the terminal content (split view).
2. Menu: two items (toggle sidebar, new agent) plus their key equivalents.
3. Surface creation: a path to create a tab with an explicit command + env. If upstream already exposes this, no edit.
Each hook is one small, commented block so upstream merges stay mechanical.

## 4. Data flow
- Poll `GET /agents/list` every 2 s while the sidebar is visible; pause when hidden or the window is occluded. SSE `agent_spawned` / `agent_stopped` / `agent_state_changed` trigger an immediate refresh; `agent_activity` updates the overlay without a refresh.
- All daemon and CLI calls run off the main thread; the sidebar model is `@MainActor` and receives immutable snapshots.
- Errors surface inline in the sidebar (row-level for actions, panel-level for connectivity) with the daemon's message verbatim.

## 5. Error handling
- Every daemon call has a 5 s timeout except spawn (30 s) and delete (30 s).
- A failed action leaves the row unchanged and shows the error under the row until the next successful refresh.
- Tunnel failures include the ssh stderr tail (≤4 KB) in the host-level message, plus the host-key / auth hint.
- Missing `leo` binary: panel-level error with the resolved path tried.

## 6. Testing
- Unit (XCTest, `GhosttyTests` target): model decoding against fixtures captured from leo 0.27 (`/agents/list`, SSE frames, `host forward` first line); sort/filter logic; attach identity map; argv/env construction; host-switch state machine.
- Integration (opt-in, skipped when no daemon): spawn → list → attach argv → stop → delete against the local daemon using a throwaway template.
- Manual acceptance (Evan, GUI): attach/close/reattach, two attachments to one agent at different sizes, mouse and paste inside tmux, remote host attach with an SSH prompt, daemon down and recovered, delete confirmation.

## 7. Milestones (each its own PR-sized branch, reviewed)
1. New `main` from upstream, rename/bundle-id commit, builds and launches.
2. Daemon client + models + fixtures + tests (ported and re-verified).
3. Sidebar with agent list, status, activity, host picker (local only).
4. Attach coordinator + tab identity + env handling.
5. Actions: start/stop/restart/set-template/rename/delete/logs + spawn sheet.
6. Remote host forwards.

## 8. Open questions
None blocking. Field shapes for 0.27 are resolved during milestone 2.

## 9. Implementation decisions (added 2026-09-15 after the upstream survey)

Facts that constrain §3.3–3.7, verified in upstream source:
- `Ghostty.SurfaceConfiguration.command` is a **shell string**; `embedded.zig` sets `.shell` and forces `wait-after-command = true`. There is no argv path and no per-surface env removal. Therefore the attach command is `env -u TMUX -u TMUX_PANE '<leo>' agent attach '<name>'` with strict single-quote escaping (`'` → `'\''`, NUL rejected). After detach the tab shows Ghostty's normal exit banner; the attachment handle is marked inactive and the next Attach opens a fresh tab.
- Adding a Ghostty config key needs Zig, so Leo settings (`leo.executablePath`, sidebar visibility/width) live in `UserDefaults.ghostty`.
- No per-host observability URL exists in leo.yaml; remote hosts get status only.

Object graph:
- `AppDelegate` owns one `LeoRuntime` (daemon client, CLI, activity client, `@MainActor LeoSidebarModel`, attach coordinator, window-session registry). No singletons; dependencies injected.
- Each regular `TerminalController` gets a `LeoWindowSession` (visibility, preferred width, search, selection), passed into `TerminalView` as an optional init parameter. Quick terminal gets none and never shows a sidebar.
- One poll scheduler: immediate refresh, then every 2 s while any visible, non-occluded window has its sidebar open; SSE spawn/stop/state events trigger a coalesced refresh; activity events update the overlay only. On `hello`, reconnect, or seq gap: clear activity, refetch list + state. Results are tagged with a host generation and stale ones dropped.
- Attach coordinator keeps `identity → ordered set<AttachmentHandle>` (surface id + weak controller). Normal attach focuses the most recent live handle or opens a tab; ⌥ always opens a new window. Handles are dropped by reconciling `surfaceTree` and `NSWindow.willCloseNotification`, not on `ghosttyCloseSurface` (close may still be cancelled). Production seam `AttachTabHost` (`openTab`, `openWindow`, `focus`, `isOpen`, lifecycle events) adapts `TerminalController.newTab`/`newWindow`; tests use a fake.
- Title: `titleOverride` is seeded with `agent · host`; once the surface publishes a later non-empty title, the seed is cleared so the shell's title wins.

Upstream hook budget (≤ 4 files): `AppDelegate.swift` (own runtime, shutdown), `TerminalController.swift` (create session, pass to view, initial content width), `TerminalView.swift` (optional session, wrap content in `LeoSidebarSplit`), `MainMenu.xib` (Toggle Agents Sidebar ⌘⇧L; New Agent ⌘⇧A lands with milestone 5). Responder actions live in a new `TerminalController+Leo.swift` extension.

Sidebar split is a custom SwiftUI horizontal split with a draggable divider (width 260 pt default, clamped 200–420 pt), not `HSplitView` or `NSSplitViewController`, so `TerminalViewContainer` and the titlebar styles stay untouched. Sidebar width is added only to the initial window size; sidebar geometry never resizes the window.
