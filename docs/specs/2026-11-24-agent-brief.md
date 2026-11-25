# Agent Brief ("where was I") — Spec

Date: 2026-11-24 · Status: draft for approval · Platforms: **both** (model + client in LeoKit; UI per app)
Builds on: `docs/specs/2026-11-24-needs-you-inbox.md` (inbox detail pane reserved room for this).
Repos: leo daemon (tool, storage, injection, config) via PR merged by the `leo` agent; leoterm (apps).

## Problem

Coming back to an agent, Evan has lost the thread: what it is trying to do, what was decided, what
is next, what it is waiting on. Transcripts are too long to skim; nothing in Leo holds a summary.

## What

Each agent keeps a short **brief** about its current work, written by the agent itself through a Leo
tool, and Leo shows it in the apps. No separate summarizer model.

Brief fields (all plain text, server-clamped, control chars stripped):
- `goal`: one line, ≤140 chars.
- `status`: current state / next step, one line, ≤140 chars.
- `decisions`: ≤5 bullets, ≤140 chars each.
- `open`: open items / waiting on, ≤5 bullets, ≤140 chars each.
- `updated_at`: daemon time, set on write.

## Daemon (leo repo)

- **Tool `leo_brief`** (MCP, token-scoped like `leo_progress`: an agent can only write its own brief).
  Replaces the whole brief each call; an empty call clears it. Validation errors are returned to the
  agent, not silently clamped away (clamping still applies as a backstop).
- **Storage:** persisted per agent, survives daemon restart, `/clear`, compaction, and resume, and
  moves with the agent on agent move. Deleted with the agent.
- **Wire:** brief included in `/api/v1/state` agent entries and published as `agent_brief {agent,
  brief}` on `/api/v1/events`. Hidden from agent-token and API-client readers (same rule as #353);
  operator, device, SSO, and unix socket see it. Hello feature `agent_brief`.
- **Agent guidance (how agents know to write it):**
  - Once per session (SessionStart, re-emitted only when the text changes, following the
    delegation-context pattern): a short instruction to keep the brief current and to update it only
    when goal, status/next step, decisions, or open items change.
  - On SessionStart after `clear|compact|resume`: the agent's current brief is injected back as
    context, so the agent itself also knows where it was.
  - Staleness nudge on UserPromptSubmit: one line ("your Leo brief is missing / may be stale")
    when the brief is missing, or when the agent has completed ≥10 turns since its last brief update.
    Never more than once per 10 turns.
  - Harnesses: Claude and Codex (both have SessionStart/UserPromptSubmit-equivalent hooks).
    Opencode: supported if its hooks allow injection; otherwise the tool still works and only the
    guidance is missing (plan decides; document the gap).
- **Toggle:** daemon config `brief.enabled` (per machine), **default off**. Off means: no guidance
  injected, no nudges, tool not offered to agents, brief omitted from the wire. Stored briefs are kept
  so turning it back on restores them.

## Apps

- **Settings (Mac + iOS):** per-machine "Agent briefs" switch writing `brief.enabled` through the
  existing config routes, with one line of help text ("Agents keep a short summary of their work.
  Uses a few tokens when it changes."). Hidden for machines whose daemon lacks the `agent_brief`
  feature.
- **Mac inbox detail:** a Brief section under the item (goal, status, decisions, open, "updated
  12m ago"). Shown for blocked and finished items.
- **Mac agent row:** the detail line falls back to the brief's `status` when there is no attention
  reason or task progress (precedence: attention reason > task progress > brief status > existing
  fallback).
- **iOS:** brief shown in the agent detail screen and at the top of the chat thread (collapsible),
  and `status` as the secondary line on inbox cards when present.
- **Empty states:** no brief → section hidden (no placeholder noise). Stale brief (updated_at older
  than the agent's last activity by > 24 h) shows its age in secondary color.

## Out of scope

Leo-side summarizer or configurable template; brief history/log; user editing of briefs; project
grouping; cross-agent threads; push notifications on brief change.

## Acceptance

- With briefs on, a Claude agent that changes its goal calls `leo_brief`; the Mac row, Mac inbox
  detail, and iOS agent detail all show the new brief within one event.
- After `/clear` (and after compaction) the agent receives its brief back in context.
- An agent with no brief after 10 turns gets exactly one nudge; no further nudge for the next 10.
- Agent-token readers never see brief text; device/operator/socket do.
- Toggle off: no guidance or nudges are injected, the tool is not offered, apps hide brief UI; on
  again restores stored briefs.
- Brief survives daemon restart and agent move.
- Daemon logic (validation, clamping, persistence, nudge counting, redaction) and LeoKit decoding /
  presentation precedence are unit-tested.
