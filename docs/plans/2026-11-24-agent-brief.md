# Plan: Agent Brief (Mac + iOS + leo daemon)

Spec (source of truth): `docs/specs/2026-11-24-agent-brief.md`. Platforms: both.

## Orchestrator decisions (2026-11-24)

1. `agents.json` atomic write (temp + rename) goes in D1: brief writes raise record-write frequency.
2. Mac row precedence: attention reason > task progress > **live tool line while working** > brief
   status > turn preview > fallback. (Brief replaces the idle-state line, never the live one.)

## Resolved

- **(a) Storage:** `Brief *brief.Brief` on `agentstore.Record` (`store.go:41`), sole writer `SetBrief`,
  `Save` preserves it (like `Appearance`, `store.go:347`), `Portable()` copies it so move carries it
  (`agentmove/job.go:323`, `settle.go:159`); receiver clears it on `ModeCopy` (`receiver.go:501`).
  Delete/rename covered by record removal/re-key (`manager.go:2001-2055,2252`).
- **(b) Turn counting:** in-memory `internal/brief.Tracker` (`TurnCompleted`, `Wrote`, `Nudge`),
  incremented on Stop/StopFailure in `daemon/session_router_turns.go:69-73` (claude, codex Stop;
  opencode `session.idle`). Restart resets → nudge may be late, never doubled.
- **(c) Withholding:** `leo_brief` is a dynamic built-in: listed while atomic `briefEnabled` is true
  (initial from launch env `LEO_BRIEF=1`, `service/process.go:1575`); `brief_config_changed` event
  → MCP updates flag + `notifications/tools/list_changed` (`mcp/clienttools_watch.go`). Codex never
  re-lists → backstop: handler refuses when off. Dispatches/no-token refused like `leo_progress`.
- **(d) Opencode & codex:** opencode plugin (`leo-turns.js`) gains synthesized SessionStart /
  UserPromptSubmit context injection via `leo dispatch context`, gated on probe D0; codex has no
  SessionStart hook installed (`codex/hooks.go:33`) — also probed. Failing probe → tool only, gap
  documented in README + PR body.
- **(e) Settings:** config singleton resource `brief` (`enabled`, default off: true only when set
  true), via `GET/PATCH /api/v1/config/brief` with `If-Match` (428/409), operator/device token.
  Reload that flips it publishes `brief_config_changed`. Apps use `LeoConfigClient.document/update`
  (`LeoConfigClient.swift:44-60`), switch shown only when daemon advertises `.agentBrief`.

## Wire contract

```jsonc
// tools/list (only while on)
{"name":"leo_brief","description":"Keep a short brief of your current work for the user. Replaces the whole brief; call with no arguments to clear it. Update only when goal, status/next step, decisions or open items change.",
 "inputSchema":{"type":"object","additionalProperties":false,"properties":{
   "goal":{"type":"string","maxLength":140},"status":{"type":"string","maxLength":140},
   "decisions":{"type":"array","maxItems":5,"items":{"type":"string","maxLength":140}},
   "open":{"type":"array","maxItems":5,"items":{"type":"string","maxLength":140}}}}}
// POST /api/agent/brief {"token":"<launch token>","brief":{...}} → 200 stored | 400 | 403 | 409 off
// /api/v1/state agent entry (omitted when off, redacted reader, or none)
"brief":{"goal":"…","status":"…","decisions":["…"],"open":["…"],"updated_at":"2026-11-25T02:00:00Z"}
// events
{"type":"agent_brief","seq":88,"at":"…","agent":"luna-dev","brief":{…}|null}
{"type":"brief_config_changed","seq":89,"at":"…","enabled":false}
// hello feature "agent_brief" whenever supported (on or off)
// leo.yaml: brief: { enabled: true }   # absent → false
```
Agent-token / API-client readers: `agent_brief` withheld (`Withhold`, `handlers_observe.go:566`),
`brief` cleared in `Agent.WithoutContent()` (`snapshot.go:69`). Socket must show briefs (verify).

## D0 · explore (parallel with D1) — probe codex + opencode
`scripts/harness-probe`: codex SessionStart (with source) / UserPromptSubmit `additionalContext`
reaches the model? opencode `chat.message` synthetic part reaches the model; `session.compacted`
fires? Report verdicts + payloads only.

## D1 · implement (high) — leo daemon PR (leo agent reviews + merges)
1. `internal/brief`: `Brief`, `Normalize`, `Tracker`. Tests first: over-length/too many → error;
   control chars stripped, newlines→spaces; empty strings dropped; empty → clear; clamp backstop;
   Tracker nudges at 10, silent 11–19, again at 20, reset on `Wrote`.
2. `config.BriefConfig` + `brief` resource. Tests: absent = off; PATCH round trip with If-Match; 409.
3. `agentstore`: `SetBrief`, Save preserves, Portable carries, copy clears; **atomic temp+rename
   write** (decision 1). Tests incl. crash-safety of write path.
4. `POST /api/agent/brief` (`handlers_brief.go`, like `handlers_progress.go`). Tests: 403, 409 off,
   success publishes one event + `Tracker.Wrote`.
5. Wire: `observe.Agent.Brief`, redaction, `FeatureAgentBrief` + hello fixture, `brief_config_changed`
   on reload. Tests: agent token never sees brief text (state + events); device/operator/socket do.
6. MCP: `registerBrief`, dynamic `list()`, `LEO_BRIEF` env, watch on `brief_config_changed`. Tests:
   hidden when off; list_changed on flip; dispatch refused.
7. Context: brief provider in `agentContext` (`handlers_agent_context.go:104`), own `toldStore`
   (`brief-told.json`, instruction hash). SessionStart → instruction (+ stored brief on
   clear/compact/resume); UserPromptSubmit → instruction only on change + Tracker nudge. Tests.
8. Tracker increment on Stop/StopFailure in `session_router_turns.go`; fixture per harness.
9. (After D0) codex SessionStart/context hooks via `PrepareInteractive`; opencode plugin injection
   with JS harness tests — or document the gap.
Verify: `go test ./internal/{brief,config,agentstore,agentmove,web,mcp,daemon,harness}/...`, `go vet ./...`.

## D2 · implement (medium, parallel with D1) — LeoKit
`LeoAgentBrief` (lenient; malformed → nil) on `LeoAgent`; events `.agentBrief(agent, brief?)`,
`.briefConfigChanged(enabled)`; `LeoDaemonFeatures.agentBrief`; config key `brief.enabled`;
`LeoAgentBriefPresentation` (hidden when empty, age text, `isStale` when updated_at > 24 h older than
last activity); `LeoInboxAgent.brief`; `LeoInboxItem.secondaryLine` = brief.status ?? context.
Tests first (`LeoAgentBriefTests`, `LeoInboxTests`). Verify: `swift test --filter 'Brief|Inbox|DaemonFeatures'`.

## D3 · implement (medium, after D2) — Mac
1. Row precedence per decision 2 (`LeoAgentRowPresentation.swift:171`); tests in
   `LeoAgentRowPresentationTests` (attention > brief, progress > brief, live tool > brief while
   working, brief > turn preview when idle).
2. Feed applies `agentBrief`; `briefConfigChanged(false)` clears, `true` refetches `/state`; test.
3. Inbox detail Brief panel (`Inbox/LeoInboxDetail.swift:97-106`), styling TDD-exempt; screenshot.
4. Settings "Agent briefs" switch in machine Daemon pane on `LeoConfigSingletonModel` (`brief`),
   gated on `.agentBrief`; model gate test.
Verify: targeted xcodebuild under `heavy` (background) + Peekaboo screenshots (isolated debug copy).

## D4 · implement (medium, after D2, parallel with D3) — iOS (UIKit + TCA)
1. AgentDetail Brief section (`AgentDetailViewController.swift:8,307`), pure row builder + test.
2. ChatThread collapsible Brief header; `isBriefExpanded` in reducer; TestStore test.
3. Inbox card uses `item.secondaryLine` (`ChatInboxCardView.swift:183`).
4. Settings toggle in Machine/DaemonSettings via `configClients` (`DaemonSettings.swift:115-126`),
   gated on `.agentBrief`; TestStore: load, toggle, save with revision, 409 alert.
Verify: `cd ios/LeoFeatures && swift test`; `heavy` build-for-testing (Xcode 26.5); simulator shot.

## D5 · integration (orchestrator)
Reviews (D1 → `review.security`; apps → `review`); live E2E on an isolated daemon covering every
Acceptance item (stub agent writes brief, /clear + /compact re-inject, nudge at 10, toggle, restart,
move). Apps need a daemon release advertising `agent_brief`.

## Risks
Codex keeps launch-time tool list until relaunch (handler refuses when off). Hook relay 3 s budget
(`cli/dispatch_context.go:19`) — brief lookup must stay cheap. Name clash with "opening prompt brief":
use `AgentBrief` / `brief.Brief`. Tracker resets on restart (late nudge, never double).
