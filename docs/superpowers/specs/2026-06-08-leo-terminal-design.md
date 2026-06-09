# Leo — Multi-Agent Terminal (design spec)

**Date:** 2026-06-08
**Repo:** `leoterm` · **User-facing name:** Leo
**Status:** Approved design, pre-implementation

---

## 1. Summary

Leo is a macOS terminal application, forked from [Ghostty](https://github.com/ghostty-org/ghostty), whose primary view is an **auto-arranging grid of coding agents**. As you add agents, they become cells in a grid; the grid auto-packs and cells shrink to make room. Cells default to *dynamic* sizing (hovering grows the cell so you can see it better) and can be made *fixed* by manual resize.

Leo is a live **view onto the Leo agent daemon** — agents persist independently of the GUI. It degrades cleanly to a plain terminal grid (no Leo required), and is architected so that generic (non-Leo) coding agents can be supported later.

### Goals

- A readable "wall of agents" view: many coding agents visible at once, each in its own cell.
- Dynamic hover-to-grow + manual fixed sizing.
- Deep integration with the existing Leo daemon (spawn, attach, status), with agents owned by the daemon (not the GUI).
- Usable as a plain terminal grid with zero Leo dependency.
- Extensible to generic agents in the future.

### Non-goals (v1)

- Cross-platform (Linux/Windows) UI. macOS only. Upstream Ghostty's Linux app is not a target.
- Replacing the Leo daemon, CLI, or web UI.
- Generic (non-Leo) agent providers — architected for, not built in v1.
- Remote-host agent boards (Leo supports remote agents via SSH; v1 targets the local daemon).

---

## 2. Architecture

### 2.1 Fork strategy

Fork Ghostty's macOS app. **Keep:** the Metal renderer, terminal emulation (`libghostty` / Zig core), PTY handling, config system, themes, command palette, tabs, and windows. **Replace:** the split-tree (`SplitTree`) layout with a managed **GridLayout** engine.

Maintenance principle: isolate all new functionality in **new files**; keep edits to upstream Ghostty files surgical and minimal so the fork stays mergeable with upstream.

### 2.2 `CellSource` abstraction

Introduce a `CellSource` protocol — the byte source feeding a terminal surface — with two implementations:

- **`PTYSource`** — a direct child process (e.g. `$SHELL`). Backs a **plain terminal cell**. Reuses Ghostty's existing PTY path.
- **`TmuxControlSource`** — a **tmux control-mode (`-CC`) client** (the largest new subsystem). Connects to agent tmux session(s), parses the control-mode protocol, and routes pane output into Ghostty surfaces. Backs an **agent cell**.

Both feed the same `TerminalSurface` view, so the renderer and input stack are agnostic to what backs a cell.

### 2.3 tmux control-mode client (`TmuxControlSource`)

Leo agents run inside tmux sessions managed by the Leo daemon (`leo agent attach --cc` already speaks control mode). `TmuxControlSource` is a native control-mode client that:

- Opens a control-mode connection (via `leo agent attach --cc <name>` or `tmux -CC` against the agent's socket/session).
- Parses control-mode notifications: `%output`, `%layout-change`, `%window-add`/`%window-close`, `%session-changed`, `%bell`, `%exit`, etc.
- Maps tmux panes/windows to Ghostty surfaces and feeds pane output to them.
- Sends input and **resize** commands back to tmux (decoupling cell visual size from logical pane size where needed).

Reference implementations: iTerm2 and WezTerm tmux integration.

**Open implementation question (resolve in plan):** whether all Leo agents share one tmux server (one control connection multiplexing sessions) or each agent is a separate server/socket (N control connections). The client must handle the actual Leo topology — verify against a running daemon during Phase 3.

---

## 3. Grid / layout engine

### 3.1 Auto-packing

Square-ish, biased wider (cols ≥ rows):

| Agents | Layout |
|--------|--------|
| 1 | full |
| 2 | 1×2 |
| 3 | 1×3 |
| 4 | 2×2 |
| 6 | 2×3 |
| 9 | 3×3 |

Past a configurable cap (default ~12–16 visible cells), cells stop shrinking and the board **scrolls** rather than becoming unreadable.

### 3.2 Hover-grow (dynamic sizing)

Three user-selectable modes; **default = A**:

- **A · Elastic reflow (default)** — the hovered cell grows *within* the grid; neighbors squish proportionally. Always a clean tiling, never overlapping. The grown cell receives real extra rows/cols (its agent reflows).
- **B · Magnify overlay** — the hovered cell scales up and floats *above* neighbors (Dock/Exposé feel). Pure visual zoom: same rows/cols, no reflow.
- **C · Hybrid** — magnify (B) for the transient hover-peek; commit a real reflow-resize (A) only when the cell is clicked to focus.

**Resize debouncing:** PTY/pane resizes fire only after hover settles (a short delay), never on every pixel of mouse motion, to avoid reflow storms in mode A.

### 3.3 Fixed vs dynamic cells

- **Dynamic** is the default: cell participates in auto-flow and hover-grow.
- Dragging a cell edge sets an explicit size → the cell becomes **fixed (🔒)**, using the **reserved-track** model: it claims a grid track at its size; dynamic cells tile the remaining space and reflow among themselves. Adding agents never shrinks a fixed cell. No overlap.
- Double-clicking a cell edge returns it to dynamic.

### 3.4 Focus model

- **Sticky click-to-focus (default):** hover only *peeks/grows* a cell visually; keystrokes go to the **last-clicked** cell and stay there regardless of mouse position. The focused cell remains the highlighted "active" cell.
- **Focus-follows-mouse:** opt-in setting; keystrokes go to whatever cell is hovered.

Rationale: with a hover-grow grid, coupling keyboard to the mouse risks typing into the wrong agent (e.g. an agent at a `y/N` prompt). Sticky is the safe default.

---

## 4. Leo integration — the board model

### 4.1 Boards

A **board** is a **curated set of agents**, not an auto-dump of every running agent (a user may have 20+ agents). Boards map onto Ghostty **tabs**; multiple **windows** are supported (a board can be dragged to its own window / placed on a different Space).

### 4.2 Sidebar / command palette

Lists everything the daemon knows:

- **Running agents** (`leo agent list --json`) with live status dots.
- **Templates** (`leo template`, e.g. `coding`, `incident`).

Actions:

- **Click a running agent** → joins the current board (opens a cell, attaches via `TmuxControlSource`).
- **New Agent** → pick template + repo/workspace → `leo agent spawn` → lands on the board.
- **New plain terminal cell** → opens a `PTYSource` cell running `$SHELL`.

### 4.3 Lifecycle (daemon-owned, "model A")

- **Close a cell = detach** — the agent keeps running in the daemon.
- **Stop an agent** is a separate, explicit action (`leo agent stop`).
- Quitting the app closes windows only; agents continue running.
- On relaunch, Leo re-discovers running agents and **restores saved boards** (cells, sizes, fixed/dynamic state).

### 4.4 Daemon transport

Talk to the daemon via its **unix socket + API token** at `~/.leo/state` (`leo.sock`, `api.token`). Fall back to shelling out to the `leo` CLI for operations not exposed on the socket. v1 targets the **local** daemon only.

---

## 5. Cell types, chrome & status

### 5.1 Cell types

- **Agent cell** — backed by `TmuxControlSource`; carries full agent status semantics.
- **Plain terminal cell** — backed by `PTYSource` (`$SHELL`); shows only activity/idle, no agent semantics.

### 5.2 Chrome — Adaptive (R)

- **Small / unfocused cells:** minimal — a tiny corner name + a status dot drawn as a thin overlay; controls appear on hover.
- **Focused / grown cell:** full slim header — name · repo/branch · status · pin (🔒) / detach (✕) buttons.

### 5.3 Status language

| State | Color | Meaning |
|-------|-------|---------|
| Working | green | output actively flowing |
| Idle | grey | quiet, nothing happening |
| **Needs you** | amber (pulsing dot + glowing border) | waiting on the user |
| Error / exited | red | process error or exit |

Plain terminal cells use only Working/Idle (activity-based).

### 5.4 "Needs you" detection (layered — best signal wins)

1. **Claude Code *Notification* hook → Leo → leoterm** — clean, explicit "waiting for input/permission". (Requires a Leo-side relay; see risks.)
2. **Terminal bell (BEL)** — reported by tmux over control mode (`%bell`).
3. **Prompt-pattern heuristic** — output stopped at a known prompt (fallback).

"Needs you" cell counts roll up to a **window-title / Dock badge** so they're noticed across Spaces.

---

## 6. Persistence & config

- **Agent lifecycle:** daemon-owned. leoterm stores only **view state** (which agents on which board, cell sizes, pin flags, hover mode, focus mode) in its own config/state directory.
- **Config:** extend Ghostty's config format with a `leo` section:
  - default hover mode (A/B/C)
  - focus mode (sticky / follows-mouse)
  - visible-cell cap before scrolling
  - chrome density (default Adaptive)
  - sidebar visibility
  - daemon socket path / token location

---

## 7. Default keybindings (proposed)

| Key | Action |
|-----|--------|
| `⌘K` | command palette |
| `⌘N` | new agent (template + repo picker) |
| `⌘T` | new board (tab) |
| `⌘1…9` | focus cell N |
| `⌘⌥ ←/→/↑/↓` | move focus between cells |
| `⌘↩` | toggle full-zoom of focused cell |
| `⌘W` | close (detach) focused cell |
| `⌘⇧W` | close board |
| drag cell edge | pin/resize (→ fixed) |
| double-click cell edge | unpin (→ dynamic) |

---

## 8. Phasing

1. **Fork & baseline** — fork Ghostty, build, strip the split UI, confirm a single surface still works.
2. **Grid engine** — `GridLayout` with auto-packing, plain-terminal (`PTYSource`) cells, dynamic/fixed sizing, hover-grow mode A, sticky focus. *Deliverable: a usable mode-A terminal grid with no Leo dependency.*
3. **tmux control-mode client** — `TmuxControlSource`; attach to one agent and render it natively. Verify Leo's tmux topology.
4. **Leo integration** — sidebar/palette, board model, spawn/attach/detach, board save & restore, daemon transport.
5. **Status layer** — status dots, "needs you" detection (bell + heuristic; hook relay if/when available), Dock/title badge.
6. **Polish** — hover modes B/C, focus-follows-mouse, multi-board/multi-window, full config surface.

---

## 9. Testing

- **Unit:** packing math; fixed-track reservation; focus state machine; control-mode protocol parser (fixture-driven); board save/restore serialization.
- **Integration:** `TmuxControlSource` against a real `tmux -CC` session; daemon enumeration/spawn against a scratch Leo config.
- **Manual / E2E:** wall-of-agents flows — add/close/pin/resize, hover-grow feel across modes, "needs you" surfacing and badge counts.

Target coverage on new, testable logic (packing, layout, parser, serialization): 80%+. UI/feel verified manually.

---

## 10. Key risks & mitigations

| Risk | Mitigation |
|------|------------|
| tmux control-mode client is a real protocol implementation (schedule risk, Phase 3) | Fixture-driven parser; iTerm2/WezTerm as references; isolate behind `CellSource`. |
| Fork maintenance vs upstream Ghostty | New code in new files; surgical edits to upstream files. |
| Resize/reflow storms in default mode A | Debounced PTY resize after hover settles. |
| Cleanest "needs you" signal depends on a Leo-side hook relay that doesn't exist yet | Bell + prompt heuristic cover v1; add hook relay later. |
| Unknown tmux topology (one server vs many) | Verify against a live daemon in Phase 3; client handles both. |
