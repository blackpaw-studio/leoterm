# Agent-advertised task progress

Status: APPROVED (Evan, 2026-11-03)
Mockups: `docs/mockups/2026-11-03-agent-progress/options.html` (chosen: Row A, Detail A + B, iOS cell 2, Chat panel B)
Platforms: **both** — data model, decode, lifecycle rules and ETA derivation live in LeoKit; each app owns only rendering. The daemon owns the data.

## Goal

Agents can advertise long-running work (builds, deploys, test sweeps) with progress. Leo shows it in the sidebar, in an agent's detail, in a floating panel over chat, and with a notification when a task finishes.

## Data model (daemon-owned, wire shape)

An agent has 0..8 **tasks**, each keyed by an agent-chosen `id`.

| field | type | rules |
|---|---|---|
| `id` | string | 1–64 chars, `[a-z0-9._-]` |
| `title` | string | required on create, ≤ 80 chars |
| `mode` | `determinate` \| `indeterminate` | sending `percent` implies determinate |
| `percent` | number 0–100 | determinate only; clamped |
| `status` | string? | ≤ 120 chars, e.g. "Compiling 412/980" |
| `eta_at` | RFC 3339? | agent-supplied ETA, stored absolute |
| `state` | `running` \| `succeeded` \| `failed` \| `cancelled` | |
| `stale` | bool | daemon-computed: running and no update for 15 min |
| `started_at`, `updated_at`, `ended_at?` | RFC 3339 | daemon-stamped |
| `revision` | int | per-task, monotonic |

Updates are upserts: omitted fields keep their value. Strings are trimmed, and control characters are stripped. A 9th active task is rejected with an error the agent can read.

## Lifecycle (daemon, injected clock)

- Created by the first update for an `id`. Ended by an update with a terminal `state`.
- If a running task gets no update for 15 min, it becomes `stale: true`. Any update clears the flag.
- `succeeded` and `cancelled` tasks are removed 10 min after `ended_at`.
- `failed` tasks persist until dismissed. They do not count toward the cap of 8.
- When an agent stops for any reason (explicit stop, idle-suspend, crash-restart, environment switch), its running, succeeded and cancelled tasks are removed. Failed tasks survive stops and go only on dismiss, on agent deletion, or by the failed-task bound (8 per agent, oldest dropped). A daemon restart clears everything (in-memory only).
- An update to an ended task with the same `id` starts a fresh run (new `started_at`), except a repeat of the same terminal state with no other fields, which is an idempotent no-op (no event, no notification).

## Report paths (daemon)

- **MCP tool `leo_progress`** in the leo MCP server: `{id, title?, percent?, indeterminate?, status?, eta_seconds?, state?}`. It uses the calling agent's identity. An agent can only write its own tasks.
- **CLI `leo progress <id> [--title] [--percent N | --indeterminate] [--status] [--eta 90s|5m] [--done | --fail | --cancel]`**. It authenticates with the same per-agent token the hook route uses, read from the agent's environment, so scripts inside an agent's pane can report.
- Both call one token-authenticated route that sits alongside `POST /api/agent/hook`.
- **Dismiss**: operator-authenticated `DELETE /api/v1/agents/{name}/tasks/{id}`. The apps call it; agents can't.
- Tasks ride on `/state` agent rows and on a change event on `/events` (unix socket and web). Broadcasts are coalesced to ≤ 2 per second per task.

Daemon changes ship as a PR in `~/.leo/agents/leo`, reviewed and merged by the `leo` agent. The apps tolerate a daemon that doesn't send `tasks` (decode is lenient and the feature stays hidden).

## LeoKit (shared)

- `LeoAgentTask` model with lenient decode, plus a per-agent task list on `LeoAgent`.
- **Primary task** for compact surfaces: an undismissed `failed` task first, else the most recently updated `running` task, else the most recent `succeeded` or `cancelled` one. `+N` counts the agent's other tasks that are not removed.
- **ETA**: use `eta_at` if present. Otherwise, for a determinate running task, derive a linear ETA from retained samples once there are ≥ 2 samples spanning ≥ 30 s. Hide it if progress is not increasing. Indeterminate tasks show elapsed time instead.
- **Finish detection**: an event that moves a task `running → succeeded|failed` emits a finish signal. Each app turns it into a notification.

## UI

- **Mac sidebar row (A).** A thin bar under the subtitle. The subtitle reads `title · status · 62% · 4m`. Indeterminate tasks get an animated bar. Several tasks add a `+N` badge. Stale tasks get a dimmed bar plus "stale". Failed tasks get a red bar with "Failed: title". **Needs-you attention wins**: when attention is set, the subtitle shows attention and the bar is hidden.
- **Mac detail (A + B).**
  - A: clicking the row's bar opens a popover anchored on the row. It lists every task for that agent with its bar or spinner, status, ETA or elapsed time, end state, and a Dismiss control on failed tasks.
  - B: a strip in the selected agent's pane header, above the terminal. Collapsed, it shows one line with the primary task. Expanded, it shows the same list as the popover. It is hidden when the agent has no tasks.
- **iOS agent cell (2).** An inline bar under the subtitle. Same text, `+N` and attention rules as the Mac row.
- **iOS AgentDetail.** A Tasks section listing every task. Swipe to dismiss a failed task.
- **Chat panel (B), Mac + iOS.** A translucent card docked at the top-right of the chat panel. It lists running and undismissed failed tasks across all agents: emoji, agent name, title, bar or spinner, %/status, ETA. It is expanded by default. It collapses to a "Tasks 3 · 62%" header, and the collapsed state is remembered per device. It is hidden when there are no tasks. Tapping a row selects that agent. Failed rows have Dismiss. On iPhone (compact width) the card spans the width under the nav bar (16 pt inset) and starts collapsed; the remembered collapsed state still applies once the user toggles it.
- **Notifications.** A system notification on `succeeded` or `failed`, suppressed when the app is frontmost with that agent selected. Mac: always delivered (the app is long-running). iOS: delivered while the app is receiving events. Remote push while suspended is out of scope.

## Out of scope

OSC 9;4 ingestion, persistence across daemon restarts, web dashboard UI, iOS remote push for finishes, a Cancel control that signals the agent, light-mode-specific design work beyond system colors.

## Testing

- **Daemon:** validation, upsert, cap, and lifecycle timers (stale, 10 min expiry, failed persists, agent-stop clears) with an injected clock. Auth tests for "own tasks only" and for dismiss requiring the operator token. MCP and CLI round-trip.
- **LeoKit:** decode (including a missing `tasks` field), primary-task selection, `+N`, ETA derivation edge cases, finish signal.
- **Apps:** row presentation tests (attention-over-progress). The visual check is debug-app screenshots of each chosen surface driven by a scripted CLI sequence, with no real agents spawned.
