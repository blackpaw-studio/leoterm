# Daemon feature request — richer agent usage telemetry

Date: 2026-11-12 · Status: draft for Evan's approval, then handed to the `leo` agent, which owns the daemon (it reviews and merges) · Consumer: leoterm's Status plugin (`2026-11-12-status-plugin.md`)

## Why this belongs in the daemon

Only the agent's own machine can see these facts. They live inside the harness process (Claude Code), and the agent may be remote. The daemon already holds and streams agent usage (`Agent.Usage`, `agent_usage` SSE). This request adds more raw numbers to that same model. Formatting, thresholds, colours and layout stay in the app and plugin.

## Fields to add to the agent usage snapshot

All are optional. A harness that can't report a field omits it.

| Field | Meaning | Proposed source |
|---|---|---|
| `effort` | current thinking effort of the main loop | leo-bridge, from the harness turn data |
| `context.breakdown {system, tools, mcp, memory, messages}` | token estimate per category (`used` rows only) | leo-bridge, from Claude Code's `/context` summary estimate; no token-count API calls |
| `context.compact_at` | auto-compact threshold as a fraction of the window | same summary (`compactThreshold ÷ window`); omitted when auto-compact is off |
| `rate_limits [{kind: five_hour\|seven_day, percent_used, resets_at}]` | the account's limits for the session | harness usage data; omitted for API-key or gateway sessions |
| `git {added, removed}` | `git diff HEAD --shortstat` in the agent's workspace | daemon or bridge on the agent's machine, at most every 10 s, `GIT_OPTIONAL_LOCKS=0`, 5 s timeout |

## Delivery

- **Routes:** add the fields to the existing `/api/v1/state` agent usage and to the `agent_usage` events.
- **No new event types.**
- **No presentation strings.**
- **The `model` field:** already present on `Agent`; just confirm it is in the state payload.

## Open for the `leo` agent

- Does the leo-bridge Claude Code plugin have access to the same host usage API that `rich-statusline` uses (`session.usage({breakdown:'summary'})`, `rateLimits`)? If not, propose the nearest source.
- Is git stats better collected by the daemon (it knows the workspace) or by the bridge?
- How should other harnesses (Codex) fill or omit each field?
