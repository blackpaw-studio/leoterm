# Agent progress amendment: automatic tasks and agent guidance. Implementation plan

Spec (source of truth): `docs/specs/2026-11-03-agent-progress.md` § "Amendment 2026-11-03". Base: daemon #314 (987bc42c) and #315 (23bf705d). Apps on `affba2131`.
Platforms: **both**. The daemon creates and ends auto tasks. LeoKit owns `source`, the dismiss rule, primary ordering and finish gating. The apps only stop offering Dismiss on auto tasks.

## Orchestrator resolutions (verified on origin/main unless marked)
- **Hooks already in place.** Supervised Claude agents already relay `PostToolUse` and `PostToolUseFailure` to `/api/agent/hook`, unmatched (`harness/claude/settings.go:40-43`, `AttentionHooks`). The only new hook is `PreToolUse` with matcher `Bash`. Supervised Codex agents already get `PreToolUse`/`PostToolUse` through `CODEX_HOME/hooks.json` (`codex/attention.go` → `PrepareInteractive`, `codex/hooks.go:33`). Codex has no `PostToolUseFailure`.
- **Payload fields verified in repo code:** `tool_use_id` on Pre and Post (`consult/tool_activity.go`); `tool_response.backgroundTaskId` and `tool_input.command` on a Bash `PostToolUse` (`consult/pending_tracker.go:137-150`); `error` string on `PostToolUseFailure` (`pending_tracker.go:124-131`, CC 2.1.317); the Stop `background_tasks[]{id,type,status,command,description}` list (`reconcileStop`); a harness-injected `UserPromptSubmit` carrying `<task-id>` (`notificationTaskID`, `consult/interactive.go:1063 isHarnessInjection`).
- **Payload fields NOT verified (step 0 captures them):** `tool_input.description`, `tool_input.run_in_background`, `PostToolUseFailure.is_interrupt`, `tool_response.interrupted`, the task-notification `<status>` value, whether hook `"async": true` is honored on CC 2.1.318, Codex's `tool_name` for shell calls and its exit/error field.
- **Error mapping:** `PostToolUseFailure` → `failed` (`cancelled` if `is_interrupt`); `PostToolUse` → `succeeded` (`cancelled` if `tool_response.interrupted`); Codex `PostToolUse` → `succeeded` unless step 0 finds a non-zero exit field. `Stop` (main loop) and `SubagentStop` (by `agent_id`) cancel open foreground calls; `SessionEnd` cancels everything. Background shell: notification `completed` → succeeded, `failed` → failed, `killed` → cancelled, unknown → succeeded; `TaskStop`/`KillShell` → cancelled; omitted from the Stop list → succeeded.
- **Background-shell logic is shared, not copied.** Move the pure functions `trackToolEvent`, `trackPrompt`, `reconcileStop`, `isHarnessInjection` and helpers into a leaf package `internal/bgshell`; `consult` keeps thin wrappers. Existing consult tests prove the move.
- **Task keys:** `auto.cmd.<first 12 hex of sha256(tool_use_id)>` (tool_use_ids are mixed-case and fail the id regex) and `auto.dispatch.<dispatch id>` (hashed the same way if it fails `[a-z0-9._-]`). Agent-reported ids starting with `auto.` are rejected in `TaskUpdate.Normalize` (400 "reserved prefix"). Contract change to a feature shipped hours ago; no users yet.
- **Cap and classes:** `classOf` splits by source. Agent running cap 8 (`ErrTaskCap`) unchanged. Auto running cap 8: `UpsertAuto` returns `ErrTaskCap`, the caller silently skips that entry and its later end. Ended auto tasks bounded at 8 (oldest dropped), removed 60 s after `ended_at`, any state. Auto tasks are never stale. `Dismiss` on auto → 409 "auto tasks clear themselves".
- **`started_at` is the real start.** `UpsertAuto(agent, AutoTask{ID, Title, Status, State, StartedAt})` stamps the Pre time or the dispatch `StartedAt`, not the publish moment 20 s later.
- **Async ordering.** Pre can arrive after Post. The tracker keeps ended tool_use_id tombstones (bounded 64, 2 min TTL) so a late Pre never arms a ghost task.
- **Tracker key.** Keyed by attention token (the launch); resolves the name via `AttentionStore.AgentForToken` at publish. Renames follow; stopped launches drop out. The store's existing `RemoveNonFailed` and `Move` cover published tasks.
- **Dedupe** lives in the progress route (`handlers_progress.go`), shared by MCP and CLI. After an agent-source `running` upsert succeeds, `autoCmds.Suppress(agent)` removes every running `auto.cmd.*` task for that agent (armed or published) and marks those entries suppressed until they end. Dispatch tasks are never touched.
- **Dispatch choke point.** `consult.DispatchObserver.Tick` (1 s diff over all records, `consult/observe_dispatch.go:113`) gains `WithDispatchTasks(sink)`. Walk `ParentDispatchID` to the root, then the owner agent via `owner(CallerBridgeKey, CallerBridgeLaunch)`, else `rec.Caller` if a supervised agent; otherwise skip. Status: `queued`, `running`, `waiting on you` (`rec.NeedsInput != nil`), `waiting` (`StatusWaiting`). Ends: `done`/`idle` → succeeded; `failed`/`timeout` → failed; `canceled`/`closed`/`released` while running → cancelled. Running after `idle` is a fresh run. Avoids touching the 57 persist call sites.
- **Hook migration.** Hooks are `--settings` argv at launch. Running agents get `PreToolUse` at their next relaunch; Leo does not restart them (Evan's call). Background-shell tasks work on old launches right away (armed at Post via `backgroundTaskId`). Codex agents already have the hooks; Codex guidance arrives on relaunch.
- **Hook latency.** `PreToolUse` matcher `Bash`, `"async": true` if step 0 confirms CC honors it. `reportAttention` takes the quick path for tool events (1 attempt, 1.5 s, as `reportDispatch`); today PostToolUse uses 5 s × 3, so a dead daemon can stall every tool call. Without async: one leo spawn + loopback POST per Bash call (step 0 measures it).
- **Guidance.** MCP `initialize` gains `instructions` (constant `leomcp.ProgressGuidance`, exact spec text), only when `LEO_ATTENTION_TOKEN` is set and `LEO_DISPATCH_ID` is not. Codex: unknown whether it surfaces MCP instructions, so Leo always appends `ProgressGuidance` to supervised Codex agents' `SystemContext` (`internal/agent/args.go`, rendered via `developer_instructions`, `codex/codex.go:136`). A duplicate line is harmless. opencode out.

## Wire contract delta
```jsonc
// task gains source; daemon always sends it; apps default a missing one to "agent"
{"id":"auto.cmd.3f9a0c1b2d4e","source":"auto","title":"Build the Mac app","mode":"indeterminate",
 "state":"running","stale":false,"started_at":"…","updated_at":"…","ended_at":null,"revision":1}
{"id":"auto.dispatch.d-7k2p","source":"auto","title":"impl-auth · implement","status":"waiting on you", …}
```
- `POST /api/agent/progress`: id starting with `auto.` → 400. `DELETE …/tasks/{id}` on auto → 409. No new event type.

## Phase 1: daemon PR (`~/.leo/agents/leo`, branch `feat/progress-auto`; lands first, `leo` agent merges)
0. **Payload capture (no TDD).** Scratch tmux pane, CC 2.1.318 with `--settings` hooks teeing stdin for Pre, Post, PostFailure, Stop, SubagentStop, UserPromptSubmit, SessionEnd. Run `sleep 25`, `false`, a background `sleep 5` it waits on, an Esc-interrupted `sleep 60`; once with `"async": true` on Pre. Same for Codex with a temp `CODEX_HOME`. Commit redacted payloads as `internal/web/testdata/hooks/*.json`. Report any field differing from the resolutions before going on.
1. **Extract `internal/bgshell`.** Mechanical move with consult wrappers. Verify `go test -race ./internal/consult/ ./internal/bgshell/`, green with only import edits.
2. **Store `source` and auto policy.** `observe/progress.go`: `TaskSource`, `AgentTask.Source`, `auto.` rejected in `Normalize`. `progress_store.go`: `UpsertAuto`, source-split classes, 60 s auto expiry, no stale, Dismiss 409. Tests first (`progress_auto_test.go`, fake clock): separate caps (8+8 accepted), 9th auto → `ErrTaskCap`, failed auto present at 59 s and gone at 60 s, Dismiss auto → `ErrTaskNotDismissable`, `started_at` honored, wire golden has `source`. Verify `go test -race ./internal/observe/ -run 'Progress|Auto'`.
3. **Command tracker.** `observe/autocmd.go`: `AutoCommands` (FeedClock, store, name resolver); pure `autoCmdTitle(description, command)`. Tests first (`autocmd_test.go`, step-0 payloads): ends at 19 s publishes nothing, 20 s publishes; Pre/Post pair by id; failure → failed then gone at 60 s; interrupt → cancelled; Post-before-Pre leaves no ghost; background shell running until notification/`TaskStop`/Stop-omission; background shell without Pre armed at Post; Stop cancels main-loop strays only, SubagentStop its own, SessionEnd all; `Suppress`; unresolvable token dropped; auto cap → skipped and end ignored; Codex `tool_name` filter. Title tests: description wins; `FOO=x heavy xcodebuild -scheme Y` → `heavy xcodebuild`; `curl -H "Authorization: …"` → `curl`; `mysql -pSECRET` → `mysql`; `cd dir && make test` → `make test`; first arg kept only if `^[A-Za-z0-9._-]{1,32}$`. Verify `go test -race ./internal/observe/ -run AutoCmd`.
4. **Hook route.** `web/handlers_attention.go` `agentHookPayload` gains `ToolUseID`, `ToolResponse json.RawMessage`, `IsInterrupt`, `AgentID`; route payloads to `s.autoCmds.Hook(token, payload)`. `handlers_progress.go` calls `Suppress` after an agent-source running upsert. Tests first: hook arms a task (fake clock); stale token no-op; `leo_progress` suppresses running auto.cmd but not auto.dispatch. Verify `go test -race ./internal/web/ -run 'AgentHook|Progress'`.
5. **Hook config and report path.** `claude/settings.go` `AttentionHooks` adds `PreToolUse:[{matcher:"Bash", hooks:[{…, async:true}]}]`; dispatch `ToolActivityHooks` unchanged. `cli/dispatch.go` `reportAttention`: 1 attempt, 1.5 s when `consult.IsToolActivityReport`. Tests first: settings JSON golden; httptest dead daemon returns within 1.5 s with one attempt for a tool event, 3 attempts for Stop. Verify `go test -race ./internal/harness/claude/ ./internal/cli/ -run 'AttentionHooks|Report'`.
6. **Dispatch tasks.** `consult/observe_dispatch.go`: `WithDispatchTasks(sink)` and pure `dispatchTaskSet(records, owner, isAgent)` diffed per Tick. Tests first (`observe_dispatch_tasks_test.go`): status→state table incl. `NeedsInput` → "waiting on you"; nested rolls up to root; keyless caller falls back to `Caller` only for a known agent; follow-up after idle = fresh run; released while idle changes nothing; title `name · role`, else template. Verify `go test -race ./internal/consult/ -run DispatchTasks`.
7. **Wiring.** `internal/daemon/server.go` constructs `AutoCommands`, passes it to web via a `With…` option (DI), gives the observer the dispatch sink. Service test: stopping an agent clears its tracker launch. Verify `go test -race ./internal/daemon/ ./internal/service/ -run 'Progress|Auto'`.
8. **Guidance.** `internal/mcp/server.go` `initialize` adds `instructions` behind the env gate; `leomcp.ProgressGuidance` holds the spec text; `agent/args.go` appends it for codex. Tests first: `instructions` present with token; absent under `LEO_DISPATCH_ID`; codex argv `developer_instructions` contains it; claude argv unchanged. Verify `go test -race ./internal/mcp/ ./internal/agent/ ./internal/leomcp/ -run 'Initialize|Guidance|Nudge'`.
9. **Docs.** Progress doc in `docs/configuration/`: auto tasks, `auto.` reservation, "relaunch to pick up PreToolUse" release note.
10. **Gate.** `make lint`; `heavy go test -race ./...` (background); `env -i … TMUX_TMPDIR=$(mktemp -d) make e2e`. Live check on an isolated daemon (separate `LEO_HOME`; never `leo service restart`): scratch claude agent runs `sleep 30` → task at ~20 s, succeeds, gone at 60 s; `false` after `sleep 25` → failed then gone; a dispatch shows `· implement` and ends. Assert on `/state` and `/events`.

## Phase 2: LeoKit (`Packages/LeoKit`; parallel with Phase 1 against the contract)
1. `LeoAgentTaskWire.swift` / `LeoAgentTask.swift`: `source` enum (`agent`/`auto`; missing/unknown → `.agent`); `isAuto`; `isDismissable = isEnded && !isAuto`. Test `LeoAgentTaskWireTests` (fixture with and without `source`).
2. `LeoAgentTasks.swift` `primary`: failed agent → running agent → running auto → ended (newest). `+N` unchanged. Test `LeoAgentTasksTests` incl. a failed auto never outranking a running agent task.
3. `LeoTaskReducer.swift`: no `LeoTaskFinish` for auto tasks. Test `LeoTaskReducerTests`.
4. `LeoTaskText.swift`: auto tasks always show elapsed, never ETA. Test `LeoTaskTextTests`.
Verify: `cd Packages/LeoKit && swift test --filter '<Suite>'`.

## Phase 3: Mac (after Phase 2)
1. Gate every Dismiss on `isDismissable` (`LeoTaskListView.swift`, `LeoTaskStrip.swift`; replaces `LeoTaskDetailText.canDismiss`).
2. `LeoProgressPanelModel.swift`: running tasks of both sources plus failed agent tasks only. Test `LeoProgressPanelModelTests`.
3. `LeoProgressFixture.swift`: auto command and dispatch rows for the visual gate.
Verify: `heavy xcodebuild build-for-testing … && heavy xcodebuild test-without-building … -only-testing:GhosttyTests/LeoProgressPanelModelTests` (background); `swiftlint lint --strict --fix`.

## Phase 4: iOS (after Phase 2; parallel with Phase 3)
1. AgentDetail swipe offered only when `isDismissable`. TCA test: no dismiss for auto.
2. Chat panel B: same filter as Mac step 2. Test in `AgentProgressTests`.
Verify: `cd ios/LeoFeatures && swift test --filter 'AgentProgress|FleetProgress'`; simulator build via `xcode-remote`.

## Visual gate (orchestrator)
Fixture screenshots of row, popover, strip and chat card with an auto command, an auto dispatch ("waiting on you") and an agent task together. No Dismiss on auto rows; elapsed shows. Mac via Peekaboo `--capture-engine cg`; iOS via simulator.

## Dispatch split
- **D1** `implement` (high): Phase 1 → `review.concurrency` (timers, async hook ordering, tracker/store locking). Bar: P0/P1 plus anything a real Bash or dispatch workload hits.
- **D2** `implement` (medium): Phases 2–4 in one run, parallel with D1 → `review`.
- Orchestrator checks step 0 findings before D1 starts step 2, and runs the isolated-daemon live check itself if D1's pane can't host a scratch agent.

## Risks and open questions
- If `async` is ignored, Pre runs synchronously (one spawn per Bash call). Acceptable; measured cost goes in the PR body.
- Codex may name its shell tool differently and lack an exit field; then Codex commands only succeed or cancel. Accepted risk.
- Stop-omission → `succeeded` guesses an unknown outcome; real failures arrive via notifications.
- Already-running Claude agents show command tasks only after relaunch (except background shells). Evan decides whether to bounce the fleet.
- Reserving `auto.` breaks any agent already using such ids; none exist.
