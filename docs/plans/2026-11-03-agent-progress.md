# Agent progress — implementation plan

Spec (source of truth): `docs/specs/2026-11-03-agent-progress.md`. Mockups: `docs/mockups/2026-11-03-agent-progress/options.html` (Row A, Detail A+B, iOS cell 2, Chat panel B).
Platforms: **both**. Daemon owns data; LeoKit owns model/decode/primary/`+N`/ETA/finish signal/text; apps only render.

## Orchestrator resolutions (spec gaps settled here)
- Only hook-launched agents get `LEO_ATTENTION_TOKEN`; others (and dispatch children) get a readable error. Accepted for v1.
- Cap counts `running` tasks only. Failed tasks get their own bound: max 8 per agent, oldest dropped (publishes `task:null`).
- Tasks clear on every `StopAgent`, including restart/reset (matches the spec's "agent stops").
- Mac finish notifications go through the existing "Agent Notifications…" opt-in / authorization path.
- Visual gate: an env-gated app fixture replays scripted task events through the real decode path (like `LeoAttentionFixture`). One real `leo progress` E2E runs on an isolated daemon in Phase 1.
- iOS chat panel B sits over the Chats split (list + thread), per mockup B.

## CLI token discovery (verified by planner)
`service/process.go` (~:2250) exports into each supervised agent's tmux env: `LEO_ATTENTION_TOKEN` (per launch, hooks only), `LEO_WEB_PORT`, `LEO_API_TOKEN` (shared agent bearer), `LEO_PROCESS_NAME`. `leo dispatch report` already POSTs `http://127.0.0.1:$LEO_WEB_PORT/api/agent/hook` with bearer `LEO_API_TOKEN`, body `{"token": $LEO_ATTENTION_TOKEN}`; the daemon resolves the agent via `AttentionStore.AgentForToken`. `leo progress` / `leo_progress` reuse this and never trust `LEO_PROCESS_NAME`. MCP env: Claude stdio inherits pane env (verify with a test); Codex forwards by name, so add `LEO_ATTENTION_TOKEN` to `leomcp.BridgeEnvNames`; opencode, add to its launch overlay.

## Wire contract
```jsonc
// task (on /state agents[].tasks and in events); omitted = unset
{"id":"build","title":"Xcode build","mode":"determinate","percent":62,"status":"Compiling 412/980",
 "eta_at":"2026-11-03T19:40:00Z","state":"running","stale":false,
 "started_at":"…","updated_at":"…","ended_at":null,"revision":7}
// event on /events (socket + web); task:null = removed (expiry, dismiss, agent stop, failed bound)
{"type":"agent_task_changed","seq":812,"at":"…","agent":"alfred","id":"build","task":{…}|null}
// hello.features gains "agent_progress"
```
- `POST /api/agent/progress` (apiMux, bearer `LEO_API_TOKEN`) body `{"token","id","title?","percent?","indeterminate?","status?","eta_seconds?","state?"}` → 200 `{ok,task}`; readable errors: 400 validation, 403 unknown/stale token, 409 cap.
- Dismiss: `DELETE /api/v1/agents/{name}/tasks/{id}` (`requireOperatorToken`) and socket `DELETE /agents/{name}/tasks/{id}` → 204; 404 unknown; 409 if not failed.
- MCP `leo_progress {id, title?, percent?, indeterminate?, status?, eta_seconds?, state?}`, `state ∈ running|succeeded|failed|cancelled`.
- CLI `leo progress <id> [--title T] [--percent N | --indeterminate] [--status S] [--eta 90s|5m] [--done | --fail | --cancel]`; non-zero exit with the daemon error; no token → exit 2 "not inside a Leo agent".

## Phase 1 — daemon PR (`~/.leo/agents/leo`, branch `feat/agent-progress`; lands first, `leo` agent reviews/merges)
1. **Validation/model.** `internal/observe/progress.go` (`AgentTask`, `TaskUpdate`; avoid `observe.Task`, which means cron tasks). Test first `progress_validate_test.go`: id regex `[a-z0-9._-]{1,64}`, title ≤80 required on create, status ≤120, trim + strip control chars, percent clamp 0–100, percent ⇒ determinate, percent+indeterminate rejected, state enum. `go test ./internal/observe/ -run TestProgressValidate`.
2. **Store/upsert/cap.** `ProgressStore` with `FeedClock` (reuse the `bridgefeed.go` `Now`+`AfterFunc` interface) and a `Publisher`. Tests: omitted fields keep value; `eta_seconds` → absolute `eta_at`; revision increases on every write; update to an ended id starts a fresh run (new `started_at`, revision keeps increasing); 9th running → `ErrTaskCap`; ended don't count; 9th failed drops the oldest failed. `-run TestProgressStore`.
3. **Lifecycle (fake clock, no sleeps).** Stale after 15 min without update (publish), cleared by any update; succeeded/cancelled removed 10 min after `ended_at` (publish null); failed persists; `RemoveAgent` clears + publishes null each; `Move(old,new)` re-keys. `-run TestProgressLifecycle`.
4. **Coalescing.** Leading+trailing coalescer per (agent,id), ≤2 publishes/s; terminal states and removals flush immediately. `-run TestProgressCoalesce`.
5. **Event/snapshot.** `EventAgentTaskChanged`, `AgentTaskChangedPayload` in `event.go`; `FeatureAgentProgress`; `Agent.Tasks []AgentTask` `json:"tasks,omitempty"` in `snapshot.go`; read seam in `internal/web/handlers_observe.go` (next to `Attention:`) and the socket `/state` builder (grep `Attention: s.attention`). Golden snapshot/event test first. `go test ./internal/observe/... ./internal/web/ -run 'Snapshot|Progress'`.
6. **Wiring.** Construct the store in `internal/daemon/server.go`; `RemoveAgent` from `Supervisor.StopAgent` (`service/process.go:551`) beside `UnregisterAgent`; `Move` on rename. Service test: stop clears tasks. `go test ./internal/service/ -run Progress`.
7. **Routes/auth.** `handlers_progress.go`. Tests: bad/stale token 403; token A never writes agent B (body has no agent field); agent token on DELETE 403; operator 204; dismiss running 409. `go test ./internal/web/ ./internal/daemon/ -run Progress`.
8. **CLI.** `internal/cli/progress.go` on root, via the `postReport` helper. httptest: flag→body mapping, `--eta` via `time.ParseDuration`, mutually exclusive flags, no-token message. `go test ./internal/cli/ -run Progress`.
9. **MCP.** `leo_progress` in `internal/mcp/tools.go` + `daemonClient.progress`; read `LEO_ATTENTION_TOKEN` in `server.go`, readable error when absent; add to `leotools.Names` (drift test); token in `BridgeEnvNames` and the opencode overlay. Tests: tool round-trip against a fake daemon; codex/opencode env forwarding. `go test ./internal/mcp/ ./internal/leotools/ ./internal/leomcp/ -run 'Progress|BridgeEnv'`.
10. **Gate.** `heavy go test ./...` (background). E2E on an isolated daemon (memory `isolated-leo-daemon-recipe`): `leo progress` inside a scratch agent pane appears on `/state` and `/events`.

## Phase 2 — LeoKit (`Packages/LeoKit`; parallel with Phase 1 against the contract)
1. `Observe/LeoAgentTaskWire.swift` + `Models` `LeoAgentTask`: lenient decode (unknown mode/state degrades, never throws; missing `tasks` → `[]`); `LeoAgentRow.tasks`; decode `agent_task_changed` in `LeoActivityClient.swift` (malformed → sequence-only event, as appearance does); `agent_progress` in `LeoDaemonFeatures`. Test `LeoAgentTaskWireTests` + fixtures in `Tests/LeoKitTests/Fixtures`.
2. `Progress/LeoAgentTasks.swift`: `primary(_:)` (undismissed failed → newest running → newest succeeded/cancelled) and `extraCount`. Test `LeoAgentTasksTests`.
3. `Progress/LeoTaskETA.swift`: value-type estimator, injected `now`, samples keyed by (agent, id, started_at); `eta_at` wins; else linear from ≥2 samples spanning ≥30 s; nil when flat/falling; elapsed for indeterminate. Test `LeoTaskETATests` (one sample, 29 s span, regression, restarted run).
4. `Progress/LeoTaskReducer.swift`: `apply(snapshot)` / `apply(event)` → new task map + `[LeoTaskFinish]`. Finish only on a live event to succeeded/failed with `ended_at` newer than last seen; never on snapshot/reconnect replay. Test `LeoTaskReducerTests` (replay silent, duplicate revision ignored, null removes).
5. `Text/LeoTaskText.swift`: `title · status · 62% · 4m`, `Failed: title`, `stale`, `+N`. Test `LeoTaskTextTests`.
6. `Progress/LeoTaskAPI.swift`: dismiss for both flavors, mirroring `LeoAppearanceAPI`. Test `LeoTaskAPITests` (path/method per flavor, 404/409 mapping).
Verify each: `cd Packages/LeoKit && swift test --filter <Suite>`.

## Phase 3 — Mac (after Phase 2)
1. **Feed.** `LeoSidebarFeed+Progress.swift` folds events through `LeoTaskReducer`. Test `macos/Tests/Leo/LeoSidebarFeedProgressTests.swift`.
2. **Row A.** Extend `LeoAgentRowPresentation` with a progress line; test attention-hides-bar, indeterminate, stale, failed, `+N`. Render in `LeoAgentRowContent.swift` (styling, no TDD).
3. **Popover (A).** Clicking the bar opens a row-anchored popover listing all tasks; Dismiss → `LeoTaskAPI`.
4. **Header strip (B).** Above the selected agent's terminal: collapsed = primary task, expanded = list, hidden when empty. Start at `Sidebar/LeoSidebarSplit.swift` to find the content container.
5. **Chat panel B.** Docked card in `Chat/LeoChatPane.swift` from a cross-agent model (running + failed); test the model; collapsed state in UserDefaults `leo.progressPanel.collapsed`.
6. **Notifications.** `LeoProgressNotifier` mirroring `LeoAttentionController` (injected `LeoNotificationPosting`, dedupe by agent+id+`ended_at`, existing opt-in); suppressed when `NSApp.isActive` and the agent is selected. Test suppression + dedupe.
Verify: `heavy xcodebuild build-for-testing … && heavy xcodebuild test-without-building … -only-testing:GhosttyTests/<Suite>` (background); `swiftlint lint --strict --fix`.

## Phase 4 — iOS (after Phase 2; parallel with Phase 3)
1. `Models/Agent.swift` gains tasks; `Features/Fleet.swift` reduces `agent_task_changed` via LeoKit. Test `FleetProgressTests`.
2. Cell 2 in `Leo/Agents/AgentRowTile.swift`, same presentation rules (test the presentation struct).
3. Tasks section in `Features/AgentDetail.swift` + `Leo/AgentDetail/AgentDetailViewController.swift`; swipe-to-dismiss failed; TCA test for the dismiss effect.
4. Chat panel B over the Chats split (`App/ChatsSplitViewController.swift`); collapsed state in UserDefaults.
5. Local notification while events flow; suppressed when active and that agent's detail/thread is visible; TCA test.
Verify: `cd ios/LeoFeatures && swift test --filter '<Suite>'`; simulator build via `xcode-remote`.

## Visual gate (orchestrator, end)
Fixture-driven debug-app screenshots of all 6 surfaces (running, percent steps, indeterminate, failed, succeeded), compared to the chosen mockups at native pixels. Mac via Peekaboo `--capture-engine cg`; iOS via simulator.

## Dispatch split
- **D1** `implement` (high): Phase 1 in the leo repo → `review.security` (auth).
- **D2** `implement` (medium): Phase 2, parallel with D1 → `review`.
- **D3** Mac, **D4** iOS `implement` (medium): parallel after D2 lands on `feat/agent-progress` → `review` each.
- Full LeoKit/Mac/iOS suites once at merge.

## Remaining risks
- Revision keeps increasing per id across fresh runs and resets only on removal; clients dedupe on (`started_at`, revision).
- Claude stdio MCP env inheritance is assumed; step 9 test confirms it.
