# B-324 · Move, copy, and duplicate agents from the Mac and iOS apps: implementation plan

- **Spec:** `.autopilot/BACKLOG.md` B-324 (lines 1171–1179). If this plan and the spec disagree, the spec wins.
- **Daemon:** leo PR #308, `origin/feat/agent-move` @ `364d1bcf32cb5bbf93c8335c2709c24e0201a484` (2026-10-28 09:55 EDT). It is not merged yet. Every `leo:` ref below is at that SHA.
- **Parity call: both platforms.** The wire types, decoding, request shape and the Force decision go in LeoKit. Each app adds only its menus, sheets and row glue. The difference: the Mac talks to every machine over its socket, which has a job-poll route. iOS talks to the web listener, which has none (see A1).

## 1. Pinned contract

### Routes
| Client | Start | Poll | Success | Refusal body |
|---|---|---|---|---|
| Mac: socket, one `LeoSocketDaemonClient` per machine | `POST /agents/{name}/move` (leo `internal/daemon/server.go:379`, handler `handlers_move.go:88-106`) | `GET /moves/{id}` (`server.go:382`, `handlers_move.go:108-120`) | **202 with a bare `JobStatus`, no envelope**. Poll answers 200 with the same shape | `{"error":"<code>","message":"<text>"}`. **`error` holds the code**, unlike `LeoDaemonEnvelope` (`agentmove/problem.go:124-127`). 400 = `bad_request`, 409 = everything else (`handlers_move.go:147-153`), 503 = `unavailable` (`:89-92`). An unknown job id gets 404 `bad_request` "no such move job" (`:114-117`) |
| iOS: web, bearer device token, not operator-gated | `POST /api/agent/{name}/move` (`internal/web/web.go:673`, `handlers_agent_move.go:29-56`) | **none on the web listener** | 202 `{"ok":true,"data":JobStatus}` | `{"ok":false,"error":"<text>","code":"<code>"}`. 400/409 as above; agent lookup failures use `resolveAgentQuery`'s status; 503 means moves are unavailable |

### Request (`agentmove/job.go:61-71`)
- Body: `{"mode":"move"|"copy","to":"<client.hosts key>","force":bool,"name":"…","branch":"…"}`. The mode constants are at `manifest.go:19-20`.
- The agent name comes from the path, not the body.
- `to` that is empty or `"localhost"` means the source host.
- `force`, `name` and `branch` are `omitempty`.
- Unknown keys are ignored (plain `json.Decoder`).
- **Duplicate** is `{"mode":"copy"}` with no `to`.
- A **move** to the source host is refused with `same_host` (`job.go:262-263`).

### JobStatus (`jobs.go:30-43`)
| Field | Content |
|---|---|
| `id` | `"mv-<16 hex>"` (`jobs.go:205`) |
| `request` | The request as sent |
| `state` | `running`, `done` or `failed` (`jobs.go:13-17`) |
| `stages` | `[{name, at}]` |
| `notes` | `[{code, message}]` |
| `error` | `{code, message}`. `message` is `err.Error()`: for several problems it is `"code: msg; code: msg"` (`problem.go:71-77`) |
| `problems` | Each preflight refusal listed separately |
| `result` | `{name, host, to, workspace, branch, notes, rsync}` (`job.go:74-84`) |
| `started_at`, `finished_at` | Timestamps |

### When refusals arrive
- **Synchronous, from Start:**
  - `agent_moving`: a transfer of this agent is already running (`jobs.go:120-122`).
  - `bad_request`: no agent named (`jobs.go:112-114`).
- **Asynchronous, a 202 followed by `state:"failed"`:** everything else from `Mover.Run`'s validate, preflight and idle steps (`job.go:161-189`). This covers the codes in `problem.go:10-45` plus:
  - `outcome_unknown` (`job.go:49`)
  - `move_pending`
  - `move_failed`, the fallback when an error has no code (`problem.go:102-119`)

### Mid-turn refusal and Force
- **Move:** `agent_busy` (`job.go:501-517`). `force:true` skips the busy probe (`:505-507`).
- **Copy:** `agent_busy` comes from Codex/opencode, or from a failed probe (`job_copy.go:131-145`). **Force does not help here** (docs table, `docs/configuration/agent-move.md:239`).
- **Client rule:** offer Force only when `state=="failed" && error.code=="agent_busy" && request.mode=="move"`.

### Copy naming
- The copy is named `name` if given. Otherwise it gets `<agent>-copy`, then `-copy-2`, `-copy-3` and so on (`job_copy.go:45-61`).
- An explicit name that is already taken is refused with `name_taken` (`job_copy.go:47`, `preflight.go:117`).
- The branch is `<current>-<name>`.
- A detached HEAD with no branch is refused with `bad_request` (`job_copy.go:38-39`). The spec rules out a branch field, so the client shows this as an error.

### `moved_to` and `moved_at`
| Source | Fields | Ref |
|---|---|---|
| Socket `GET /agents/list` (Mac rows) | `moved_to`, `moved_at` (RFC 3339) | `internal/agent/manager.go:400-404` |
| `/api/v1/state` and socket `/state` (`observe.Agent`) | **`moved_to` only, no `moved_at`** | `observe/snapshot.go:101-103`, `web/handlers_observe.go:273` |
| `GET /agents/{name}/session` | `moved_to`, `moved_at` | `daemon/types.go:146-149` |

- A moved agent is `status:"stopped"` with `wake_on_message:false` (`agent/move.go:201-215`).
- **No event carries `moved_to`.** `MarkMoved` writes the store without emitting anything. The only earlier signal is `agent_stopped` from the move's stop stage.
- A start, wake or control call on a moved agent gets 409 `agent_moved`:
  - socket: `daemon/types.go:37`, `handlers_agents.go:642-643`
  - web: `agent_control_core.go:177-180`
- The `agent_moved` message comes from `agent/move.go:65-72` and names CLI commands.

### How a copy appears
- The destination's `Receive` saves the record, then calls `Start` (`agent/receive.go:98,108`).
- The process start emits `agent_spawned` on the **destination's** event stream (`service/process.go:466`).
- Both apps' feeds already refetch on `agent_spawned`:
  - Mac: `LeoSidebarFeed.swift:326`
  - iOS: `Fleet.swift:373`
- This needs confirming against a real daemon pair in the e2e step.

### Ambiguities for a client
- **A1. iOS cannot poll.** The web listener has no job route. Every async refusal, including `agent_busy` and every preflight error, is invisible to iOS. So is completion. As the contract stands, iOS cannot meet "shows the daemon's own error text" or "offers Force only when the daemon refuses". See Q1.
- **A2. No feature flag.** There is no `hello` feature for moves. An older daemon answers the route with a plain-text 404 (Go mux).
- **A3. What `to` means.** `to` is a key in the **source daemon's** `client.hosts`, not the app's Machine name. The source daemon has no hosts route. Its config API does expose the collection `hosts` (`web/config_resources.go:228-236`), which LeoKit reads with `configClient().collection("hosts")`. That route is operator-gated on the web listener.
- **A4. CLI wording in messages.** The busy and moved messages say "pass --force" and "`leo --host … agent attach`". Showing them verbatim (the spec's rule) leaks CLI phrasing.
- **A5. A pruned job.** The daemon keeps 64 finished jobs (`jobs.go:21`) in memory only. After a daemon restart, a poll for the id gets 404.
- **A6. `moved_at` is missing on iOS.** It is absent from `/api/v1/state`, so the iOS row can only say "Moved to X", with no time.

## 2. Current leoterm surfaces

### LeoKit
- **`LeoDaemonClient`** protocol: `Packages/LeoKit/Sources/LeoKit/Daemon/LeoDaemonClient.swift:3-43`.
  - New verbs get default throwing implementations here (pattern at `:50-64`), so the existing test actors keep compiling.
  - `LeoSocketDaemonClient` (`:89-266`) has the helpers to reuse: `route(_:_:)` `:192`, `checked` `:232`, `controlError` `:240`, `configClient()` `:151`.
- **`LeoWebDaemonClient`** (iOS): `Remote/LeoWebDaemonClient.swift:5-130`. It has `request` `:110` and `checked` `:121`.
  - It already uses the unversioned `/api/agent/start` (`:68`).
  - `configClient()` is at `:36`.
- **Models:**
  - `LeoAgent`: `Models/LeoModels.swift:37-77`, CodingKeys `:70`.
  - `LeoDaemonEnvelope`: `:113`.
  - `LeoDaemonError` and its description: `:151-180`.
  - `LeoObservedAgent`: `Observe/LeoActivityClient.swift:13`, CodingKeys `:58`.
- **Config collection:** `LeoConfigCollection.items[].name` at `Config/LeoConfigDocument.swift:86-88`.
- **Test doubles:**
  - `RecordingTransport` for the socket: `Tests/LeoKitTests/LeoSocketDaemonClientTests.swift:142`.
  - `FakeWebTransport` for the web listener: `LeoWebDaemonClientTests.swift:128`.

### Mac
- **Row model:** `LeoAgentRow`, `macos/Sources/Features/Leo/Sidebar/LeoSidebarState.swift:4-64`. It is built from `LeoAgent` at `LeoSidebarFeed.swift:501` and `LeoSidebarFeed+Disconnect.swift:50`. The reducer copy is at `LeoSidebarReducers.swift:24`.
- **Row state and dormant rendering:** `LeoAgentRowState.swift:37-68`.
  - `.restoring` shows "Restoring…" trailing (`:53-54`).
  - `.stopped` shows `stop.fill` with a dimmed name (`:55-56`).
- **Availability:**
  - `LeoRowActionAvailability`: `LeoAgentRow.swift:19-45`.
  - Control bar: `Control/LeoAgentControl.swift:36-49`.
- **Row context menu:** `LeoAgentRow.swift:127-158`. Items run Attach…Delete, with "Set Template" and "Environments" as submenus at `:140-145`.
- **Actions:** `LeoAgentActions`, `Sidebar/LeoAgentActions.swift`.
  - `run(...)` at `:269-296` handles pending state, generation gating and row errors.
  - Templates are cached per host at `:197` and following.
- **Agents menu:**
  - Declared in `macos/Sources/App/MainMenu.xib`.
  - `@IBAction`s and validators: `Integration/LeoAgentMenuActions.swift:15-117`.
  - Dynamic submenus by identifier: `LeoAgentsMenuController` `:126-240` (`leo.agents.setTemplate`, `…setEnvironments`).
  - Enablement: `Integration/LeoMenuCommands.swift:40-52`.
- **Machines:**
  - `LeoMachineClientResolving.daemon(for:)`: `Sidebar/LeoMachineClients.swift:10-23`.
  - `LeoHostID`: `Packages/LeoKit/Sources/LeoKit/Models/LeoHostID.swift:5`.
  - Registry: `Hosts/LeoMachineRegistry.swift`.
- **Sheets:** `Sidebar/LeoAgentSheets.swift` (Rename `:7`, Delete `:45`).
- **Fixtures and tests:**
  - DEBUG screenshot fixture `LEO_MACHINES_FIXTURE`: `Sidebar/LeoMachinesFixture.swift:13-46`.
  - Fake daemons: `ActionDaemon`, `GatedActionDaemon` in `macos/Tests/Leo/LeoAgentActionsTests.swift:543,578`.

### iOS
- **Daemon dependency:** `ios/LeoFeatures/Sources/LeoFeatures/Dependencies/DaemonClient.swift:6-38`.
  - `AgentCommand` enum and the `perform` closure.
  - Live values at `:47-81`.
- **Agent model:** `Models/Agent.swift:16-29`. `isStopped` is at `:59`.
- **Presentation:** `ios/Leo/Support/AgentPresentation.swift:18,77-78`.
- **Detail reducer:** `Features/AgentDetail.swift`.
  - State `:18-40`, actions `:42-62`.
  - Confirmations `:163-180`, `failureAlert` `:200`.
  - The view controller: `ios/Leo/AgentDetail/AgentDetailViewController.swift`. Rows and commands are built at `:203-238`; stopped agents show `[.start]`, others `[.interrupt, .restart, .stop]` (`:235`).
- **Agent list:** `ios/Leo/Agents/AgentsViewController.swift`.
  - List layout at `:91`; swipe actions go on that configuration.
  - The context menu at `:216-226` shows only Appearance and returns nil when appearance is unsupported.
  - List-level requests route through `AppFeature` (`Features/AppFeature.swift:49,111`).
- **Fleet refetch:** `Fleet.swift:344-374` refetches `/state` on hello, gap and `agent_spawned`. `agent_stopped` patches the row in place (`:456`).
- **Fixtures and tests:**
  - Screenshot fixture: `ios/Leo/Machines/MachinesFixture.swift:11,40` (launch arg plus `DependencyValues`).
  - Reducer tests: `LeoFeatures/Tests/LeoFeaturesTests/AgentDetailTests.swift` (TCA `TestStore`).

## 3. Ordered plan

Every step is test-first. The test named in each step must fail before the change and pass after it.

**Commands:**
- LeoKit: `swift test --package-path Packages/LeoKit --filter <Suite>`
- LeoFeatures: `swift test --package-path ios/LeoFeatures --filter <Suite>`
- Mac (run once after `macos/scripts/leo-runtests.sh <label>` has built): `xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<Suite>`, run from `macos/` with `DEVELOPER_DIR` pointed at Xcode 26.3.

### LeoKit (parity: both)
1. **L1 `moved_to` decoding.**
   - Add `movedTo: String?` and `movedAt: String?` to `LeoAgent` (`moved_to`, `moved_at`), and `movedTo` to `LeoObservedAgent`.
   - Tests in `LeoModelsTests` / `LeoObservedStateDecodingTests`:
     - `/agents/list` JSON with `moved_to` and `moved_at` decodes both.
     - With neither key, both are nil.
     - `/api/v1/state` with `moved_to` decodes.
2. **L2 Wire types.** New file `Daemon/LeoAgentMove.swift`.
   - Types: `LeoMoveMode` (`move`, `copy`) and `LeoMoveRequest(mode, to?, force, name?)`. The request is Encodable and leaves `to`, `name` and `force` out when empty or false. `branch` is out of scope.
   - Factories: `.move(to:force:)`, `.copy(to:name:)`, `.duplicate(name:)`.
   - Decodable `LeoMoveJob {id, request, state, error: LeoMoveProblem?, problems, result: LeoMoveResult?}`.
   - `LeoMoveJob.offersForce` implements §1's Force rule.
   - Tests in `LeoAgentMoveTests`:
     - exact request JSON for each factory; a duplicate has no `to` key
     - a captured `JobStatus` fixture decodes, both `running` and `failed`
     - `offersForce` is true for move + `agent_busy` and false for copy + `agent_busy`
3. **L3 Socket client.**
   - Add `startMove(_ name:, _ req:) -> LeoMoveJob` and `moveJob(id:) -> LeoMoveJob` to `LeoDaemonClient` with default throwing implementations, then implement them in `LeoSocketDaemonClient`.
   - Decode the bare body on 202 or 200.
   - On non-2xx, decode `{"error","message"}` and throw `LeoDaemonError.daemon(code:message:)`. If it doesn't parse, fall back to `controlCode(forStatus:)`, so a 404 from an older daemon becomes `not_found` (A2).
   - Use `mutationTimeout`.
   - Tests in `LeoSocketDaemonClientTests` with `RecordingTransport`: method, path and percent-escaped name; 409 `agent_moving` keeps the daemon's text; a plain-text 404 maps to `not_found`.
4. **L4 Run-to-outcome.** New `LeoAgentMover`, injected with a client and a `sleep` closure (no real waits).
   - It starts the job, then polls `moveJob` once a second until the state is no longer `running` or the task is cancelled.
   - It returns `LeoMoveOutcome`:
     - `.done(LeoMoveResult)`
     - `.refused(code, message, offersForce)`
     - `.unknown(message)` when a poll gets 404 (A5)
   - Tests in `LeoAgentMoverTests`, using a fake sequence of client answers:
     - running → done
     - running → failed with `agent_busy`, so Force is offered
     - a preflight `problems` list surfaces the daemon's message verbatim
     - a 404 poll gives `.unknown`
     - cancellation stops polling
5. **L5 Web client.**
   - Add `LeoWebDaemonClient.startMove(_:_:) -> LeoMoveJob`, which decodes the envelope `data` on 202 and uses the existing `checked()` for errors.
   - Tests in `LeoWebDaemonClientTests` with `FakeWebTransport`: the 202 envelope decodes; 409 `{code:"agent_moving"}` gives the daemon's message.
6. **L6 Destinations.** A pure function `LeoMoveDestinations.entries(hosts:)`.
   - Input: names from `collection("hosts")`.
   - It sorts them and drops `localhost` from "Move to".
   - "Copy to" gets the same list. Duplicate is always offered.
   - If the hosts list fails to load, both submenus show an "Unavailable" placeholder.
   - Test: `LeoMoveDestinationsTests`.

### Mac (parity: Mac glue over L1–L6)
7. **M1 Moved rows.**
   - Thread `movedTo` into `LeoAgentRow` at all three construction sites.
   - `LeoAgentRowState` gets a `.moved` case, resolved before `.stopped`:
     - symbol `arrow.up.forward.square`, tertiary ink, dimmed name
     - trailing "On \<host>"
     - help "Moved to \<host> \<moved_at>"
     - spoken "Moved to \<host>"
   - `LeoRowActionAvailability` gains `moved`. A moved row cannot Start, Attach, Restart, Rename, Set Template, Move, Copy or Duplicate. Delete is decided in Q4.
   - `LeoAgentControl` gives a moved agent `.off` with the reason "\<name> moved to \<host>."
   - Tests:
     - `LeoAgentRowStateTests`: a moved row wins over stopped.
     - `LeoRowActionAvailabilityTests`: a moved row can't start or attach.
     - `LeoAgentControlTests`: the moved reason.
8. **M2 Actions.**
   - Add `move(row, to:, force:)`, `copy(row, to:, name:)` and `duplicate(row, name:)` to `LeoAgentActions`. They run L4 through `run()`, so the row stays pending while polling and the generation gating still applies.
   - `.done` calls `refresh()`.
   - `.refused` sets the row error to the daemon text and code, and publishes `forceOffer: LeoAgentRow?` when Force applies.
   - Add a per-host destinations cache, like the template cache, filled from `configClient()?.collection("hosts")`.
   - Tests in `LeoAgentActionsTests`, with `ActionDaemon` extended to cover moves:
     - each call forwards the exact request
     - `agent_busy` publishes the Force offer
     - accepting it re-sends with `force:true`
     - copy + `agent_busy` publishes no offer
     - success refreshes once
9. **M3 Row context menu.** In `LeoAgentRow.swift` after "Set Template" / "Environments", add `Menu("Move To")`, `Menu("Copy To")` and `Button("Duplicate…")`, built from L6 entries and disabled per M1.
   - Move asks for confirmation first: "Move \<name> to \<host>? It stops here and resumes there."
   - Copy and Duplicate open a new `LeoCopyAgentSheet` in `LeoAgentSheets.swift`. It has an optional Name field (placeholder `<name>-copy`) and a Copy button.
   - Force is an alert with the daemon's text and buttons "Move Anyway" and "Cancel", shown only when the offer exists.
   - No unit test, because this is UI glue (TDD exception). M2 covers the logic, and M6 checks it visually.
10. **M4 Agents menu.**
    - Add to `MainMenu.xib`, after "Switch to": submenus with identifiers `leo.agents.moveTo` and `leo.agents.copyTo`, plus "Duplicate…".
    - `LeoAgentsMenuController.menuNeedsUpdate` populates the submenus the same way as Set Template, including the generation guard.
    - Add `@IBAction`s, validators, and `LeoMenuCommands.canMove/canCopy/canDuplicate`.
    - **Shortcuts:** none of these appear in the xib or in Ghostty's default `super` binds (`src/config/Config.zig` about 6900–7600). The Agents menu already uses the ⌃⌘ family (⌃⌘A, M, ., K, ⇧K).
      - Duplicate… ⌃⌘D. HIG's ⌘D is taken by Split Right (`Config.zig:7180`). ⌃⌘D shadows text-field Look Up; the terminal's Look Up is force-click (`SurfaceView_AppKit.swift:1135`).
      - Move To ⇧⌃⌘M.
      - Copy To ⇧⌃⌘C.
      - AppKit may not fire a key equivalent on an item that has a submenu (Q2). If it doesn't, the shortcut pops the same host menu over the selected row.
    - Test: `LeoMenuCommandsTests` for enablement, including that a moved row disables all three.
11. **M5 Mac shots.** Add a DEBUG `LEO_MOVE_FIXTURE=1` fixture modelled on `LeoMachinesFixture`.
    - Fake clients for two machines.
    - Rows: one moved row, one live row whose move answers `agent_busy`, and a copy that appears after Duplicate.
    - Launch with `open -n --env LEO_MOVE_FIXTURE=1 macos/build/DD/Build/Products/Debug/Leo.app`.
    - Capture with Peekaboo (`--capture-engine cg`): the context menu with "Move To ▸" open, the Agents menu showing its shortcuts, the Force alert, the moved row, and the copy row.
    - Drive only by menu clicks. Never press keys against real agents (per `verify.md`).

### iOS (parity: iOS glue over L1, L2, L5, L6; UIKit + TCA)
12. **I1 Model.**
    - `Agent.movedTo` comes from `LeoObservedAgent`.
    - `AgentPresentation` shows "Moved to \<host>" with a dormant symbol.
    - `AgentDetailViewController:235` shows no commands for a moved agent, and the Terminal row is disabled.
    - Test: in `FleetTests`, a snapshot with `moved_to` sets it; `statusText` is pure, so it is tested in LeoFeatures.
13. **I2 Dependency.** Add to `DaemonClient`:
    - `startMove(connection, agent, LeoMoveRequest) -> LeoMoveJob`
    - `moveHosts(connection) -> [String]` (web `configClient().collection("hosts")`)
    - live values for both
14. **I3 Shared `AgentMove` reducer.** New file `Features/AgentMove.swift`.
    - State: daemon, agent, intent (`move(to)`, `copy(to)`, `duplicate`), name, `inFlight`, alert.
    - Move is confirmed first.
    - Copy and Duplicate take an optional name. The UIKit VC shows a `UIAlertController` with a text field and sends `.nameSubmitted`.
    - A 202 ends in `.accepted(job)`, and the parent asks `Fleet` for a bounded refetch (I5).
    - A synchronous refusal shows `failureAlert` with the daemon's text.
    - Force follows Q1. Until that is decided, a move on an agent whose `activity == .working` gets a "Mid-turn" confirmation with "Move Anyway".
    - Tests in `AgentMoveTests` (`TestStore`):
      - each intent sends the exact request
      - 409 `agent_moving` puts the daemon's text in the alert
      - cancel does nothing
      - a busy agent's move offers Force and sends `force:true`
15. **I4 Wiring.**
    - `AgentDetail` presents `AgentMove`, from a new "Move" section with Move To, Copy To and Duplicate rows. Move To and Copy To are `UIMenu` pickers over `moveHosts`.
    - `AgentsViewController`: the context menu always returns a menu with Move To ▸, Copy To ▸ and Duplicate…, and keeps Appearance when it is supported. A trailing swipe "Move" opens the same picker. Both go through `AppFeature.moveRequested(ref, intent)`.
    - Tests: `AgentDetailTests` checks the move rows present `AgentMove`; `AppFeatureTests` checks `moveRequested` presents it for the right daemon.
16. **I5 Refetch after accept.** After an accepted move, `Fleet` refetches `/state` every 2 s on an injected `ContinuousClock`, up to 30 tries. It stops when the agent shows `moved_to`, when a copy appears (`agent_spawned` already refetches), or when the tries run out.
    - Test: `FleetTests` with `TestClock` checks the stop when `moved_to` appears and the stop at the cap.
17. **I6 iOS shots.** Add a `-moveFixture` launch arg modelled on `MachinesFixture.prepare`.
    - Two daemons; one moved agent; one busy agent; a copy that appears.
    - Run the simulator on the host: `xcodebuild -project ios/Leo.xcodeproj -scheme Leo -destination 'platform=iOS Simulator,name=iPhone 17' build`, then `xcrun simctl launch booted studio.blackpaw.leo.ios -moveFixture`, then `xcrun simctl io booted screenshot`.
    - Capture: the context menu, the swipe, the detail's Move section, the copy name prompt, the moved row and the error alert.
    - The bundle id is in `ios/project.yml`.

### Integration gate (once, before merge)
- `swift test --package-path Packages/LeoKit` (full)
- `swift test --package-path ios/LeoFeatures` (full)
- `heavy bash macos/scripts/leo-runtests.sh b324`, run in the background, checking load first
- `swiftlint lint --strict`
- A fresh-context `review` of `git diff main...HEAD`, at the bar P0/P1 or anything a real user can hit.
- **Optional e2e:** the isolated two-daemon recipe from memory (`isolated-leo-daemon-recipe`), with both daemons built from `364d1bcf`. Check the 202 → poll → `moved_to` → `agent_spawned` path for real, then repin if the PR head moves.
- B-324 stays blocked until #308 is in a daemon release. The plan is buildable now against the pinned SHA.

## 4. Open questions
- **Q1 (blocks the iOS Force and error parts of the spec).** The web listener has no job poll, so iOS never sees async refusals or completion (A1).
  - **Recommendation:** ask the `leo` agent to add `GET /api/agent/moves/{id}`, returning the same JobStatus envelope, to PR #308 before it merges. Then I3 polls through L4 like the Mac does.
  - Fallback: the client-side mid-turn pre-check in I3 plus the bounded refetch. iOS would then never show preflight refusals.
- **Q2 (Mac shortcuts).** HIG's Duplicate (⌘D) is taken by Split Right, so I chose ⌃⌘D. The spec puts Move and Copy in submenus, which may not be able to carry a key equivalent.
  - **Recommendation:** ⇧⌃⌘M / ⇧⌃⌘C on the submenu parents. If AppKit ignores those, they pop the host menu over the selected row.
- **Q3 (host list).** The list shows the source daemon's `client.hosts` keys, not the app's Machine names. The two may differ (A3). Reading them needs operator auth on the web listener.
  - Fine for the Mac.
  - On iOS, if the read is refused, only Duplicate is offered. Is that acceptable?
- **Q4 (moved rows).** Should Delete stay enabled on the dormant source record? The daemon's delete may remove its worktree and branch.
  - **Recommendation:** keep Delete enabled, but keep the delete sheet's branch checkbox off by default. Confirm the daemon's behavior with the `leo` agent first.
- **Q5 (wording).** Should `agent_busy` and `agent_moved` messages be shown verbatim, CLI phrasing ("pass --force", "`leo --host …`") included, as the spec says? Or should LeoKit reword those two known codes, as it already does for `daemon_restoring` (`LeoModels.swift:170`)?
  - **Recommendation:** reword only those two codes in LeoKit.
- **Q6 (feature gating).** There is no hello feature for moves. The items stay visible, and an older daemon's 404 shows as "This Leo daemon can't move agents yet."
  - Alternative: ask for an `agent_move` hello feature in #308.

## Addendum: merged contract 500d2d77

leo PR #308 merged to leo main as `500d2d77`. Checked against that commit (`internal/web/handlers_agent_move.go`, `internal/observe/{event,snapshot}.go`); this supersedes Q1, Q6 and A1 above.

- **Web poll.** `GET /api/agent/moves/{id}` returns `{ok, data: JobStatus}` and covers copy jobs too. 404 `no such move job` for an unknown or pruned id; 503 `agent moves not available` with no job store; 401 for a bad token (same auth as the POST). The route is served ahead of the agent mux so a literal agent named `moves` still routes normally.
  - LeoKit: `LeoWebDaemonClient.moveJob(id:)` polls it. The narrow protocol `LeoMoveJobClient` (`startMove`, `moveJob`) is what `LeoAgentMover` takes, so the socket client (Mac) and the web client (iOS) share one poller. A 404 reads as `not_found`, which `LeoAgentMover` maps to `.unknown`.
  - iOS therefore follows a job to its outcome like the Mac does: the client-side mid-turn pre-check and the bounded `/state` refetch loop from I3/I5 are gone. After `done` (or `unknown`) the app refetches that daemon's `/state` once (`Fleet.refreshRequested`).
- **`agent_move` hello feature** (also in `/version` capabilities). When it is absent the move items are **hidden**, on both platforms: Mac's Agents menu, row menu and context menu; iOS's row menu, swipe and detail Move section. The "can't move agents yet" text stays only as the fallback for a 404 from the move route.
- **`moved_at`** is on `observe.Agent` in `/api/v1/state` (`omitempty`, set with `moved_to`). `LeoObservedAgent.movedAt` decodes it. The daemon writes Go RFC 3339, with nanoseconds when the instant has them, so `LeoMovedAgentWording.date(from:)` accepts both shapes (a plain `ISO8601DateFormatter` rejects fractions). Rows read "Moved to X · 5 minutes ago".
- **Delete on a moved row.** The daemon removes the source host's worktree, plus the branch only if it is merged; the destination is untouched. Both platforms say so: "Remove leftover copy on <source> (the agent lives on <moved_to>)", with the button reading Remove and the branch checkbox off by default (Mac: `LeoDeleteAgentSheet`; the wording is `LeoMovedAgentWording`). iOS has no delete action, so nothing changes there.

### iOS as built
- `AgentMove` (reducer, `Features/AgentMove.swift`) owned by `AppFeature` (`@Presents move`); the detail's Move rows and the list's menu both send `moveRequested`. `daemonClient.move` runs start + poll through `LeoAgentMover`; `daemonClient.moveHosts` reads `client.hosts` (`.unavailable` → Duplicate only, per Q3).
- Mid-turn refusal (`agent_busy`, `offersForce`) → "<agent> is busy" with Move Anyway, which resends `force: true`. Other refusals and thrown errors show the daemon's text in an alert.
- Hosts are read when a daemon connects with `agent_move` (`AppFeature.moveDestinations`).
- Screenshots: `-moveFixture` + `LeoUITests/LeoMoveTests` write `docs/plans/shots/agent-move/ios-*.png` (`TEST_RUNNER_MOVE_SHOTS_DIR`).

### Mac as built (deltas)
- Move To / Copy To parents have actions (`moveSelectedLeoAgent:`, `copySelectedLeoAgent:`) so AppKit validates them: a submenu parent with no action is always enabled, which is why they showed enabled with no row selected. Set Template has the same latent issue (not changed).
- ⇧⌃⌘M / ⇧⌃⌘C: AppKit ignores key equivalents on submenu parents, so `LeoAgentsMenuController` matches them in a local key monitor and pops the host list at the pointer for the selected row.
