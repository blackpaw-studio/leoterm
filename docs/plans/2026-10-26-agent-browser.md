# Agent Browser — implementation plan

Spec (source of truth): `docs/superpowers/specs/2026-10-26-agent-browser.md`. Branches: leoterm `feat/agent-browser` (parallel phases use sub-worktrees merged back); leo `feat/client-tools-relay`. The leo PR is reviewed and merged by the `leo` agent.

**Platform call:** Mac only. LeoKit holds the parts iOS can reuse: the client-tools wire client, tool definitions, command decoding, executor core, control state machine, and the snapshot/console JS. The Mac app holds the WebKit adapter, input synthesis, port forwards and UI. The iOS executor goes to the autopilot backlog (F5).

**Commands**
- `GO(x)`: `cd ~/.leo/agents/leo && go test -race ./internal/<pkg>/... -run '<x>'`
- `LK(x)`: `cd Packages/LeoKit && DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer swift test --filter '<x>'`
- `MB`: from `macos/`: `DEVELOPER_DIR=… xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
- `MT(x)`: `timeout 600 xcodebuild test-without-building … -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<x>`

## Settled investigations

1. **`ssh -O forward` works with the tunnel's master. Verified live on 2026-10-26** (OpenSSH_10.3p1 client → Dionysus).
   - Test setup: a master started with the exact `tunnelArguments` flags (`LeoSSHCommand.swift:26-42`: `-n -N`, `ControlMaster=yes`, `ControlPersist=no`, `ExitOnForwardFailure=yes`).
   - It accepted `ssh -o ControlPath=<cp> -O forward -L 127.0.0.1:P:localhost:RP <target>`: rc 0, and the remote sshd banner came through the forward.
   - A duplicate forward also returns rc 0, and `-O cancel -L …` removes the forward.
   - A busy local port returns rc 255 ("Port forwarding failed") and the master stays up. `ExitOnForwardFailure` only covers the master's own forwards.
   - Forwards die with the master.
   - `-L` port 0 is rejected ("Bad local forwarding specification"), so the app has to pick the free port itself.
   - The mux client must mirror `sftpClientArguments` (`LeoSSHCommand.swift:72-88`) but **without `ClearAllForwardings=yes`**, which would clear the `-L` itself. Keep `ProxyCommand=/usr/bin/false` so a dead master fails fast.
   - The per-forward `ssh -N -L` fallback is needed anyway: `multiplexingControlPath` can be nil (`LeoMachineConnection.swift:162`, `LeoSSHCommand.swift:37-39`).
2. **Trusted input to a hidden `WKWebView`.** Unverified until C4 passes.
   - Every tab's web view always sits in a window. When the pane isn't showing it, it moves to an app-owned `LeoAgentBrowserParkingWindow`: borderless, sized like the pane, placed outside every screen, `orderBack`, `ignoresMouseEvents`, `canBecomeKey/Main=false`, excluded from the Windows menu, `.transient/.ignoresCycle`.
   - Input is real `NSEvent`s (`mouseEvent(with:)` / `keyEvent(with:)`) with that window's `windowNumber` and window coordinates converted from the element's client rect. They are passed straight to the view (`webView.mouseDown(with:)`, `keyDown(with:)` …). That skips the `NSWindow.sendEvent` first-mouse and activation logic. WebKit turns UI-process events into `isTrusted` DOM events; WebKitTestRunner drives offscreen windows the same way.
   - Takeover detection uses a `LeoAgentWebView: WKWebView` subclass that overrides mouse-down, scroll-wheel and key-down. Events the executor synthesized are recorded in a ledger keyed by (type, timestamp), so WebKit's async re-dispatch of unhandled keys can't look like user input.
   - Proof is C4's tests. Fallback if typing fails in the non-key parking window: the parking window overrides `isKeyWindow` only while keys are being delivered (WebKitTestRunner precedent). If that also fails, use `insertText(_:replacementRange:)` (trusted `input` events, but no `keydown`).
3. **`list_changed` from leo's MCP server.**
   - leo uses no Go MCP library. The server is hand-rolled JSON-RPC over stdio (`internal/mcp/server.go`, protocol `2024-11-05`, which defines `notifications/tools/list_changed`).
   - It needs `capabilities.tools.listChanged: true`; today it sends `"tools": map[string]any{}` (`server.go`, `initialize` case).
   - It also needs a server-initiated write path. `runWith`'s `writeResponse` is already mutex-guarded, so the notification is just a `jsonRPCMessage{Method: "notifications/tools/list_changed"}` written through it.
   - `tools/call` returns text only today (`registry.callContext` returns `string`, `tools.go:836`), so image pass-through needs a content-block handler path.
4. **`WKWebsiteDataStore(forIdentifier:)` needs macOS 14.** The app targets 13.0/13.1 (`project.pbxproj` `MACOSX_DEPLOYMENT_TARGET`) and LeoKit `.macOS(.v13)` (`Package.swift:19`).
   - Decision (veto-able): on macOS 13 the app never registers the `browser` group (no tools appear) and the Settings toggle reads "Requires macOS 14". Everything behind `@available(macOS 14, *)`.
   - LeoKit never imports WebKit. WebKit isn't used in the app yet; `import WebKit` autolinks it.
5. **Transport.**
   - The app reaches every daemon over its unix socket (`LeoSocketActivityClient.swift:57`; remote = forwarded socket), so the app-side routes must be mounted on the socket. Follow the chat pattern (`internal/daemon/chat.go:12`, `server.go:351`).
   - The MCP server calls TCP with the agent token (`internal/mcp/client.go:39`). Agent-gone hook: `agentMgr.SetGoneHook(srv.CloseChatAsksOf)` (`internal/service/process.go:1138`).
6. **ATS.** `Ghostty-Info.plist` has no ATS keys. Add `NSAllowsArbitraryLoadsInWebContent=YES` so `http` pages load; it applies to web content only.

## Wire contract (pin before fan-out)

- **Feature:** hello `features` gains `client_tools`. The app opens a provider stream only when it is present.
- **Provider stream:** socket `GET /events?client_tools=1`, TCP `GET /api/v1/events?client_tools=1`.
  - TCP needs the operator token; the agent token gets 403.
  - Hello adds `"client_id":"ct_<ulid>"`.
  - Closing the stream withdraws that client's tools and releases its ownerships. The Settings toggle off just closes the stream.
- **Events** (`seq`/`at` as usual):
  - `client_tools.changed`, all streams: `{"revision":7,"tools":["browser_click",…]}`.
  - `client_tool.request`, provider streams: `{"request":{"id":"ctr_<ulid>","agent":"alfred","group":"browser","tool":"browser_click","args":{…},"owner":"ct_…"|"","timeout_s":30,"created_at":"…"}}`. Non-provider streams get `{"request":{"id":"…"}}` (redacted, but keeps seq contiguous for the sidebar's gap detection).
  - `client_tool.cancelled` *(addition)*: `{"id","agent","reason":"timeout"|"cancelled"|"agent_gone"}`, redacted the same way. It lets the executor abort a wait and dismiss a handoff banner.
- **Routes.** Same paths on the socket (the socket's file permissions are the auth) and TCP (operator token unless noted). Existing envelope `{ok,data,error,code}`.
  - `POST /api/v1/client-tools` `{client_id,group,tools:[{name,description,input_schema,timeout_s}]}` → `{revision}`.
    - 400 `invalid_tool` / `too_many_tools`; 404 `unknown_client`; 409 `name_conflict` (data: `{tool}`).
    - A re-POST from the same client replaces the group. An identical group from another client adds it as a provider with no revision bump.
  - `GET /api/v1/client-tools` → `{revision,ever_registered,tools:[{group,name,description,input_schema,timeout_s}]}`. TCP also serves `GET /api/agent/{name}/client-tools` (agent token).
  - `POST /api/agent/{name}/client-tools/call` (TCP, agent token) `{tool,args}` blocks until settled.
    - Returns `data:{ok:true,content:[…]}` or `data:{ok:false,error:{code,message}}`.
    - Daemon codes: `no_client`, `timeout`, `cancelled`. 404 for an unknown tool.
  - `POST /api/v1/client-tools/requests/{id}/claim` `{client_id}` → `{request}`; 409 `owned_by_other` / `already_claimed`; 404 `unknown_request` (also when settled).
  - `POST /api/v1/client-tools/requests/{id}/result` `{client_id,ok,content?,error?}` → `{}`; 409 `not_claimant` / `already_settled`; 404.
  - `GET /api/v1/client-tools/requests?pending=1` → `{requests:[{…request,claimed_by}]}`.
- **App error codes:** `user_has_control`, `stale_ref`, `tab_limit`, `scheme_not_allowed`, `navigation_failed`, `timeout`, `js_error`, plus the additions `invalid_args` and `no_such_tab`.
- **MCP mapping:** ok → `{content}` verbatim; error → `{content:[{type:text,text:"<code>: <message>"}],isError:true}`.
- **Golden JSON** for every shape above lives in both `internal/clienttools/testdata/wire/` and `Packages/LeoKit/Tests/LeoKitTests/Fixtures/client-tools/` (identical copies; A2/A4 encode-compare, B1 decodes).
- The browser tool schemas live only in LeoKit `LeoBrowserTools`. The daemon never sees "browser".

## Phases and parallelism

- Once this contract is committed, these run in parallel:
  - **P0**
  - **A1–A7**
  - **B1–B3**
  - **C1–C2** (LeoKit)
  - **C3–C4** (WebKit adapter and input)
  - **D1–D3**
- **A8** needs P0's results. **C5–C6** need B and C1–C4.
- **E** needs C2 and C5 interfaces. E1/E4 can start against stubs.
- **F** needs everything, plus the leo PR merged and installed.
- Max 6 concurrent implementers. B and C1/C2 touch different LeoKit files.

### Phase 0 — harness probe (leo repo)

- **P0.1 Probe server.** Files: `scripts/harness-probe/probeserver/main.go` (+ `main_test.go`).
  - Test first: `TestProbeEmitsListChangedAfterPing`. Driven over `io.Pipe`, `probe_ping` returns, then `notifications/tools/list_changed` is written, and the next `tools/list` contains `probe_late`.
  - Notes: echoes the client's `protocolVersion`; advertises `tools.listChanged:true`.
  - `probe_late` returns a token plus an 8×8 red PNG image block (this also probes image pass-through).
  - Appends JSONL to `$PROBE_LOG`: initialize `clientInfo{name,version}`, every `tools/list` (with an after-notify flag), every `tools/call`.
  - Verify: `cd ~/.leo/agents/leo && go test -race ./scripts/harness-probe/...`
- **P0.2 Runner script** (glue, no TDD). Files: `scripts/harness-probe/run.sh [claude|codex|opencode|all]`, `README.md`, `results/`.
  - Per harness, in a fresh `$TMPDIR` dir:
    - claude: `--mcp-config` + `--strict-mcp-config`
    - codex: `-c mcp_servers.probe.command=…`
    - opencode: `OPENCODE_CONFIG` with `mcp.probe{type:"local"}`
  - Probe tools are auto-approved with each harness's own flag/config.
  - The authoritative run is interactive in a private tmux server (`tmux -L leo-probe`, matching how leo spawns agents). The prompt is fixed: "call probe_ping; then re-check your tools; call probe_late if present; say the image colour". It waits up to 180 s for `probe_late`. Headless (`claude -p`, `codex exec`, `opencode run`) is recorded as a secondary signal.
  - Writes `results/<date>.json`: `{harness,version,client_info_name,relisted,called_late,image_seen,honors}`, where `honors = relisted && called_late` (interactive).
  - Installed versions to probe: Claude Code 2.1.310, codex-cli 0.162.1, opencode 1.18.18.
  - Feeds A8's table, keyed by the recorded `client_info_name`.
  - Verify: `scripts/harness-probe/run.sh all && cat scripts/harness-probe/results/*.json`

### Phase A — daemon relay (leo repo)

- **A1 Registry.** Files: `internal/clienttools/registry.go` (new): `Connect() ClientID`, `Disconnect(id)`, `Register(id, group, []Tool) (rev, error)`, `Snapshot()`.
  - Test first: `TestRegisterValidation`:
    - Rejected: bad name regex, a `leotools.Names` collision (conflict), another group's name (conflict), the 65th tool (limit), a schema that isn't a `{"type":"object"}` object.
  - Also `TestIdenticalGroupSharesProviders` and `TestDisconnectWithdrawsAndBumpsRevision`.
  - Notes: schema check is structural only (object; `type=object`; `properties` is an object; `required` is `[]string`). No JSON Schema library in go.mod.
  - Verify: `GO(Register|Identical|Disconnect)` on `clienttools`.
- **A2 Calls.** Files: `internal/clienttools/calls.go`: `Call(ctx, agent, tool, args) Result`, `Claim`, `Settle`, `Pending`, `CancelAgent`. Clock injected.
  - Tests first:
    - `TestCallTimesOutPerTool` (fake clock, `timeout_s:30`), `TestTimeoutZeroWaitsForCtx`, `TestNoClientFailsFast`
    - `TestOwnershipFirstClaimWins409`, `TestSecondResult409`
    - `TestOwnerDisconnectReleasesAndUnclaims`: an in-flight request becomes claimable again.
    - `TestPendingListsUnsettled`, `TestCancelOnCtxAndAgentGone`: publishes `client_tool.cancelled`.
    - `TestImageContentPassThrough`: raw JSON bytes are unchanged.
  - Notes: in memory only. Uses an `observe.Publisher` interface. The waiter pattern follows `internal/chat/prompts.go:18`.
  - Verify: `GO(Call|Owner|Second|Pending|Cancel|Image)`
- **A3 Persisted flag.** Files: `internal/clienttools/flag.go`: a `FlagStore` interface plus a file implementation at `<home>/state/client-tools.json` (0600).
  - Test first: `TestFirstRegistrationPersistsEverRegistered`. It survives a new store over the same path; a failed write is logged, not fatal.
  - Verify: `GO(EverRegistered)`
- **A4 Events and stream.** Files: `internal/observe/event.go` (3 event types, `FeatureClientTools`, `HelloPayload.ClientID`); `internal/observe/httpapi/httpapi.go` (`EventsOptions.ClientTools` hook, redaction).
  - Tests first: `TestProviderStreamHelloCarriesClientID`, `TestNonProviderStreamGetsRedactedRequestKeepingSeq`, `TestStreamCloseDisconnectsClient`, golden-JSON encode tests.
  - Verify: `GO(Provider|Redacted|StreamClose)` on `observe/...`.
- **A5 HTTP routes.** Files: `internal/web/handlers_clienttools.go` (new), registered in `web.go` near line 669. Socket mount in `internal/daemon/server.go` (like the chat prefix). The socket `/events` handler (`daemon/handlers_observe.go:89`) reads `client_tools=1`.
  - Tests first:
    - `TestClientToolsRoutesStatusCodes`: 400/404/409 per the contract.
    - `TestAgentTokenCannotOpenProviderStream`: 403.
    - `TestCallRouteDisablesWriteDeadline`: a call longer than WriteTimeout still answers.
    - `TestSocketServesClientToolsPaths`.
  - Verify: `GO(ClientTools|AgentToken|CallRoute)` on `web/...` and `daemon/...`.
- **A6 Wiring.** Files: `internal/service/process.go`. One relay is injected into both the socket server and the web server (DI, no globals). The gone hook becomes `func(n){srv.CloseChatAsksOf(n); relay.CancelAgent(n)}`.
  - Test first: `TestGoneHookCancelsParkedClientToolCall` (daemon package, fake manager).
  - Also write `docs/` API page for client tools.
  - Verify: `GO(GoneHook)`
- **A7 MCP native tools.** Files: `internal/mcp/tools.go` (content-block handler type; `list()` merges client tools filtered by `perms.DeniesTool`), `server.go` (`tools/call` passes `content`/`isError` through), `client.go` (`clientTools()`, `callClientTool(ctx, …)` on an `http.Client` with no Timeout; deadline = `timeout_s` + 5 s; 0 = ctx only).
  - Tests first: `TestToolsListIncludesRegisteredClientTools`, `TestClientToolCallReturnsImageBlock`, `TestDeniedClientToolHiddenAndRefused`, `TestCancelledNotificationAbortsClientCall` (fake daemon via httptest).
  - Verify: `GO(ClientTool|DeniedClient|CancelledNotification)` on `mcp/...`.
- **A8 `list_changed` and fallback (needs P0).**
  - Files:
    - `internal/mcp/harnesscaps.go` (new): `honorsToolListChanged(clientInfoName) bool` from P0's results; unknown → false.
    - `server.go`: capture `initialize.clientInfo`; `capabilities.tools.listChanged:true`; `notify()` writer.
    - `clienttools_watch.go`: native mode only. SSE `GET /api/v1/events` with reconnect and backoff, ignores everything but `client_tools.changed`, re-fetches the list on hello and on each event, coalesces 1 s, sends `list_changed` when the revision changes.
    - Fallback mode: `leo_app_tools` / `leo_app_call{tool,args}`, listed only if `ever_registered` was true at the first `tools/list` (sampled once, so the list never changes).
  - Tests first:
    - `TestListChangedEmittedOnRevisionChange` (pipes + fake SSE)
    - `TestNonHonoringClientGetsFixedFallbackList`
    - `TestFallbackHiddenUntilEverRegistered`
    - `TestAppCallMatchesNativeCallContent`
    - `TestUnknownClientInfoUsesFallback`
  - Verify: `GO(ListChanged|Fallback|AppCall|UnknownClientInfo)`
- **A9 Known tools** (depends on Q2). Files: `internal/leotools/leotools.go` and `internal/config/config.go:1276`, through an injected `extraKnown func(string) bool` (no global).
  - Test first: `TestDenyToolsAcceptsPersistedClientToolName`.
  - Verify: `GO(DenyTools)`
- **A10 Ship.** `go test -race ./...` and lint (`make lint`) once at the gate. Open the PR; the `leo` agent reviews and merges. Pin the release that carries `client_tools` (Q4).

### Phase B — LeoKit protocol client

- **B1 Wire types.** Files: `Packages/LeoKit/Sources/LeoKit/ClientTools/LeoClientToolsWire.swift`.
  - Test first: `LeoClientToolsWireTests`: every golden JSON decodes and round-trips; a redacted request decodes as `.redacted(id)`; unknown fields are ignored.
  - Verify: `LK(LeoClientToolsWire)`
- **B2 Client.** Files: `ClientTools/LeoClientToolsClient.swift`: actor over `LeoSocketActivityTransport`.
  - `events()` yields `.hello(clientID)`, `.request`, `.cancelled`, `.changed`, `.gap`, `.disconnected` (seq tracking as in `LeoSocketActivityClient.swift:50-80`).
  - Also `register(group:tools:)`, `claim(id)`, `postResult(id,_)`, `pending()`. One stream per call and no reconnect of its own (D-061); the session (C6) owns retry.
  - Test first: `LeoClientToolsClientTests` with a fake transport (paths, bodies, 409 mapped to typed errors, gap yields `.gap`).
  - Verify: `LK(LeoClientToolsClient)`
- **B3 Browser vocabulary.** Files: `AgentBrowser/LeoBrowserTools.swift` (15 definitions, timeouts; `browser_handoff` timeout 0), `LeoBrowserCommand.swift` (tool+args → enum, else `invalid_args`), `LeoBrowserError.swift`, `LeoBrowserKeyCombo.swift` (`"Meta+a"` parse), `LeoBrowserStoreID.swift` (UUIDv5 of `machineID + "\u{0}" + agent`; fixed namespace), `LeoBrowserURLPolicy.swift`.
  - Tests first:
    - `LeoBrowserCommandTests`: every tool decodes; missing `ref` → `invalid_args`; `ms` over 25 000 → `invalid_args`.
    - `LeoBrowserKeyComboTests`
    - `LeoBrowserStoreIDTests`: deterministic, distinct per agent and machine.
    - `LeoBrowserURLPolicyTests`: `file:` / `javascript:` → `scheme_not_allowed`; `about:blank` passes.
    - Golden `browser-tools.json`.
  - Verify: `LK(LeoBrowser)`

### Phase C — executor, browser, tabs, takeover/handoff

- **C1 Executor core** (LeoKit). Files: `AgentBrowser/LeoBrowserExecutor.swift`; protocols `LeoBrowserPage` / `LeoBrowserTabs` / `LeoBrowserURLMapping` (WebKit-agnostic, `@MainActor`).
  - Test first: `LeoBrowserExecutorTests` against a fake page:
    - Each command maps to the right page call and result shape.
    - Mutating ops under user control → `user_has_control`; reads still pass.
    - The 11th tab → `tab_limit`; an unknown tab → `no_such_tab`.
    - Ops are serialized per browser; a pending handoff does not block reads.
    - Reported URLs pass through `toRemote`.
  - Verify: `LK(LeoBrowserExecutor)`
- **C2 Control state machine** (LeoKit). Files: `AgentBrowser/LeoBrowserControl.swift`: `agent` / `user` / `handoff(requestID, message)`; transitions `userInput`, `pill`, `giveBack`, `handoff`, `done`, `decline`, `cancelled` (removes the banner, leaves control as is).
  - Test first: `LeoBrowserControlTests`: full transition table; Done → `done` and agent control; Decline → `declined`.
  - Verify: `LK(LeoBrowserControl)`
- **C3 WebKit page adapter** (Mac). Files: `macos/Sources/Features/Leo/AgentBrowser/LeoWKBrowserPage.swift`, plus snapshot/console JS in LeoKit `AgentBrowser/LeoBrowserScripts.swift`.
  - Snapshot runs in an isolated `WKContentWorld`, with refs in a world-local `Map`, so the page DOM isn't mutated. Navigation resets the world, so old refs fail with `stale_ref`.
  - Console hook runs in the page world (500-entry ring per tab via `WKScriptMessageHandler`). `eval` uses `callAsyncJavaScript` in `.page`.
  - Screenshot uses `takeSnapshot`, capped at 1600 px wide, PNG. Full page uses a `scrollHeight` rect.
  - Navigation waits for `didFinish` (internal deadline 28 s, so the agent gets a meaningful `timeout` before the daemon's).
  - Test first: `LeoWKBrowserPageTests`, real `WKWebView` with local fixtures served by a test `WKURLSchemeHandler`:
    - Snapshot lists roles, names, values and refs; truncates at 50 000 chars with a note; ref goes stale after a second snapshot.
    - eval of a thrown error → `js_error`.
    - Console captures `log`, `error` and unhandled rejection.
    - A tall fixture's full-page PNG is taller than the viewport and at most 1600 px wide.
  - Verify: `MB && MT(LeoWKBrowserPageTests)`
- **C4 Input delivery proof** (Mac). Files: `AgentBrowser/LeoAgentWebView.swift`, `LeoSyntheticInput.swift` (kVK map, coordinate conversion, ledger), `LeoAgentBrowserParkingWindow.swift`.
  - Test first: `LeoAgentInputDeliveryTests`, parametrized over {visible non-key window, parking window, re-parented from visible to parking while another window is key}. The fixture logs `event.isTrusted`.
    - Click → trusted `mousedown` / `mouseup` / `click`.
    - type "héllo 1" → value matches; `keydown` and `input` events trusted.
    - `Enter` submits the form; `Meta+a` selects all.
    - Parked screenshot pixel shows the fixture colour; a `requestAnimationFrame` (rAF) callback fires within 500 ms while parked (records throttling).
    - `syntheticInputDoesNotTakeOver` and `directMouseDownTakesOver`.
  - Notes: if typing fails while parked, enable the `isKeyWindow` fallback (see investigation 2) and repeat the same tests. Escalate if that fails too.
  - Verify: `MT(LeoAgentInputDeliveryTests)`
- **C5 Browser and registry** (Mac). Files: `AgentBrowser/LeoAgentBrowser.swift` (up to 10 tabs; `WKUIDelegate.createWebViewWith` creates a tab with the given configuration; `WKWebsiteDataStore(forIdentifier:)`; macOS 14 gate), `LeoAgentBrowsers.swift` (app-level, keyed `(LeoHostID, agent)`; created on the first request; closed on `agent_stopped` or pane close; store kept).
  - Test first: `LeoAgentBrowserTests`:
    - A `target=_blank` click lands as a new active tab; the 11th popup → `tab_limit`.
    - Same identifier for the same machine and agent across instances.
    - `agent_stopped` closes the browser; the store file remains.
  - Verify: `MT(LeoAgentBrowserTests)`
- **C6 Per-machine session** (Mac). Files: `AgentBrowser/LeoClientToolsSession.swift`, plus wiring in `Hosts/LeoMachineRegistry.swift` (start on `.connected`, stop otherwise) and a Settings key.
  - Flow: on the `client_tools` feature, open the stream → register `browser` → on hello / reconnect / gap, `pending()` → claim → executor → result. In-flight request ids are deduped, so a re-claim attaches instead of re-running. `cancelled` aborts the op. Exponential retry while the machine is connected.
  - Test first: `LeoClientToolsSessionTests` with a fake client:
    - Registers once per hello; Settings off closes the stream.
    - Pending recovery doesn't re-run an in-flight click.
    - 409 on claim is ignored.
    - No feature, or macOS 13 → no stream.
  - Verify: `MT(LeoClientToolsSessionTests)`
- **C7 Config** (no TDD). `Ghostty-Info.plist` gets `NSAllowsArbitraryLoadsInWebContent`. Settings "Agent browser" toggle row (styling). Verify by building `MB`.

### Phase D — port forwarding (Mac)

- **D1 Planner.** Files: `AgentBrowser/LeoPortForwardPlanner.swift`.
  - Test first: `LeoPortForwardPlannerTests`:
    - Only remote machines and `localhost` / `127.0.0.1` / `[::1]` hosts forward.
    - The same port is used when free; otherwise the injected port prober picks another.
    - URLs are rewritten local↔remote both ways, keeping path, query and fragment.
    - Non-loopback hosts are untouched.
  - Verify: `MT(LeoPortForwardPlannerTests)`
- **D2 Runners.** Files: `Hosts/LeoSSHCommand.swift`, new `forwardArguments(controlPath:local:remotePort:op:)` (`-O forward` / `-O cancel`, binds `127.0.0.1` only) and `forwardProcessArguments(...)` (`-N -L`, mirrors the tunnel flags with no ControlMaster); `AgentBrowser/LeoPortForwardRunner.swift` (mux runner via `LeoProcessRunning`; process runner reuses the `LeoTunnel` process lifecycle).
  - Test first: `LeoSSHCommandForwardTests` (exact argv; no `ClearAllForwardings`; rejects ports outside 1–65535) and `LeoPortForwardRunnerTests` (rc 255 → `.portBusy`; cancel issued on teardown).
  - Verify: `MT(LeoSSHCommandForwardTests|LeoPortForwardRunnerTests)`
- **D3 Manager.** Files: `AgentBrowser/LeoPortForwards.swift` (per machine, refcounted per agent browser; implements `LeoBrowserURLMapping`).
  - Test first: `LeoPortForwardsTests` with a fake runner:
    - Busy port → retry on a new port.
    - Browser close cancels its forwards; machine disconnect drops all.
    - The mux runner is chosen when a control path exists, the process runner otherwise.
  - Verify: `MT(LeoPortForwardsTests)`

### Phase E — pane UI (Mac)

- **E1 Content case.** Files: `Editor/LeoRowPanes.swift` (`LeoRowPane.content: .editor | .agentBrowser`; the existing `browser` property is the workspace file browser, so the new name avoids it), `Editor/UI/LeoEditorTabBar.swift` (leading "Browser" item), `LeoEditorTabsViewController.swift` (`isPaneOpen` includes the browser; swaps content).
  - Test first: `LeoRowPaneAgentBrowserTests`:
    - A browser created by the agent opens the pane without changing first responder.
    - Closing the Browser item closes the agent browser.
    - Rows without a browser are unchanged.
  - Verify: `MT(LeoRowPaneAgentBrowserTests)`
- **E2 Browser pane.** Files: `AgentBrowser/UI/LeoAgentBrowserPaneViewController.swift`, `LeoAgentBrowserToolbar.swift` (inner tab strip, URL bar, back/forward/reload, pill).
  - Test first: `LeoAgentBrowserPaneModelTests`: pill text per control state; URL bar shows the remote-terms URL; Enter in the URL bar counts as user input.
  - Styling is exempt from TDD; screenshot it.
  - Verify: `MT(LeoAgentBrowserPaneModelTests)` plus a screenshot.
- **E3 Handoff.** Files: `AgentBrowser/UI/LeoHandoffBanner.swift`; notification via `LeoNotificationPosting.post` (`Attention/LeoAttentionController.swift:53-55`).
  - Test first: `LeoHandoffTests` with a fake poster: banner and notification on handoff; Done → result `done`; Decline → `declined`; `cancelled` removes the banner.
  - Verify: `MT(LeoHandoffTests)`
- **E4 Globe badge.** Files: `Sidebar` row presentation.
  - Test first: `LeoAgentRowBrowserBadgeTests`: badge shown iff a browser exists for (host, agent). `dispatch:<id>` agents map to their dispatch row.
  - Verify: `MT(LeoAgentRowBrowserBadgeTests)`
- **E5 Hosting.** Files: `AgentBrowser/LeoAgentBrowserHost.swift`: moves web views between the pane on screen and the parking window. When several windows show the row, the most recent one wins; the others show a "Shown in another window" placeholder.
  - Test first: `LeoAgentBrowserHostTests`: re-parenting on row switch keeps page state (a JS counter survives, no reload); a hidden pane leaves the view parked.
  - Verify: `MT(LeoAgentBrowserHostTests)`

### Phase F — end to end (Dionysus)

- **F1 Setup.**
  - Install the leo release with the relay on Dionysus. Run a local isolated daemon for the "never registered" check (follow the isolated-daemon recipe in Claude's project memory).
  - Debug app built here, with Dionysus added as a machine. Agents are scratch only (debug-app keystroke safety: select the scratch row and confirm focus with a screenshot before sending any key).
  - Scratch Vite app on Dionysus running `npm run dev -- --port 5173`.
- **F2 Success criterion 1, per harness.** Before connecting the app, `tools/list` has no `browser_*` / `leo_app_*`.
  - Check by calling `leo mcp-server` over stdio with the agent's environment.
  - Then, with claude, codex and opencode agents already running, connect the app and have each one make a browser call (natively or via `leo_app_call`, per the A8 table).
- **F3 Success criteria 2–6.**
  - The agent navigates to `localhost:5173`, snapshots and clicks through.
  - Evan's click gives `user_has_control`; Give back restores control.
  - `browser_handoff("Log in please")` blocks until Done.
  - Two tabs: list, select, close; a `_blank` link lands as a new tab.
  - Quitting the app makes the next call return `no_client` and withdraws the tools.
  - Evidence: windowed video and native-pixel PNGs of the pane in `docs/plans/2026-10-26-agent-browser-evidence/`.
- **F4 Integration gate.** Full Go suite, LeoKit suite and Mac suite, load-aware. Fresh-context review: `review` for the UI, `review.concurrency` for the relay and executor.
- **F5 Backlog.** Add an autopilot backlog item: iOS executor (LeoKit client, executor and scripts are ready; needs a UIKit host and input via `UITouch`-free JS-less path, to be investigated).

## Risks

- **Keyboard while parked.** Typing may need page focus, which follows the key window. C4 proves it or falls back to the `isKeyWindow` override, then `insertText`.
- **Hidden-page throttling.** The off-screen parking window is occluded, so `requestAnimationFrame` (rAF) and timers slow down. Animation-driven pages may settle late. C4 measures this; mitigations need Evan's call.
- **Handoff ceiling.** Handoff is effectively capped by leo's 32-minute harness tool timeout (`internal/leomcp/timeout.go:16`). The cancel arrives as `cancelled` and the banner is dismissed.
- **Image blocks may not reach codex/opencode models.** P0 records `image_seen`.
- **Tool-list churn.** A bus slow-subscriber drop withdraws and re-registers tools. A8 coalesces notifications, and C6 recovers through `pending()`.
- **Test environment.** WebKit tests need a window-server session on the test host. Mark them in the plan and skip with a reason when there is none.
- **Dispatch children.** `LEO_PROCESS_NAME=dispatch:<id>` gives each dispatch its own store and browser.

## Open questions (not settled by the spec)

1. **Success criterion 1 vs the persisted fallback flag.** On a daemon that has never seen an app register, a harness that ignores `list_changed` can't gain `leo_app_*` without a restart, because its tool list is fixed. Recommend accepting a one-time restart for that case. The point is moot if P0 shows all three harnesses honor `list_changed`.
2. **`deny_tools` validation.** Config validation runs at daemon boot, before any app connects, so "known while registered" would reject `deny_tools: [browser_eval]`. Recommend persisting ever-registered tool names with the flag and accepting those names (A9).
3. **Contract additions.** OK to add the `client_tool.cancelled` event, the `invalid_args` / `no_such_tab` codes, the `client_tools` feature flag, and redacted request events on non-provider streams?
4. **Release path for F.** Who cuts the leo release, bumps the app's bundled daemon, and upgrades Dionysus — the `leo` agent, or this agent after the merge?

## Orchestrator resolutions (2026-10-26)

1. Accept the one-time restart: on a daemon that has never had an app register, a non-honoring harness needs one restart to gain `leo_app_*`. After the first registration, everything works mid-session. Spec success criterion 1 amended to match. Moot if P0 shows all three harnesses honor `list_changed`.
2. Accept: persist ever-registered tool names alongside the flag; `deny_tools` accepts them (A9).
3. Accept all contract additions (`client_tool.cancelled`, `invalid_args`, `no_such_tab`, `client_tools` feature flag, redacted request events).
4. The `leo` agent reviews, merges and releases the daemon PR per its normal process. This agent bumps the app's bundled daemon and upgrades Dionysus in phase F.
5. Accept the macOS 14 gate (investigation 4).
