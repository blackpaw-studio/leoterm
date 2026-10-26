# Agent Browser — spec

Date: 2026-10-26 · Status: approved by Evan 2026-10-26

## Goal

A browser inside the Leo Mac app that a Leo agent drives through MCP tools and
that Evan can watch and take over. A dev server on a remote agent's
`localhost` opens in it through a port forward on that machine's ssh connection.

Platform call: **Mac only** for v1. The client-tools protocol client and the
snapshot script live in LeoKit so iOS can adopt them; the iOS executor is
deferred to the autopilot backlog.

## Decisions (settled with Evan)

- Shared, agent-driven browser that the user can take over (not preview-only, not headless).
- Engine: `WKWebView` in the Mac app. No Chromium, no CDP.
- Cookies/storage: one persistent store per agent.
- Multiple tabs per agent are in scope.
- Exposure: the daemon gets a **generic client-tools relay** and knows nothing
  about browsers. Connected apps declare tools; agents see them only while a
  providing app is connected. Terminal-only users see no new tools and pay no
  context cost.

## Architecture

Two repos change:

1. **leo daemon** (`~/.leo/agents/leo`, Go): the client-tools relay. Ships as a
   PR reviewed and merged by the `leo` agent.
2. **Leo Mac app** (this repo): declares the browser tools, and adds the
   executor that serves them, the browser pane, and the port-forward manager.

Flow: app connects → registers its tool definitions → each agent's MCP server
sends `tools/list_changed` → agent calls `browser_*` → daemon parks the call
→ publishes `client_tool.request` on the SSE bus → the owning app runs it
→ posts the result → daemon settles the parked call → tool returns.

## Daemon: client-tools relay

### Registration

- An app subscribes to the event stream with `?client_tools=1`. The daemon
  assigns the subscription a `client_id`, returned in `hello`.
- `POST /api/v1/client-tools` `{client_id, group, tools:[{name, description,
  input_schema, timeout_s}]}` registers a group of tools (here `group: "browser"`).
  `timeout_s: 0` means no timeout.
- Registrations live only as long as the subscription. When it closes, its tools
  are withdrawn.
- Validation: names must match `^[a-z][a-z0-9_]{0,63}$` and must not collide with
  a built-in leo tool or another client's group. Collisions are rejected with 409.
  Schemas must be valid JSON Schema objects. At most 64 tools per daemon.
- When two clients register the same group with identical tool definitions,
  the tools are listed once and both clients are providers.

### Exposure to agents

- Each agent's `leo mcp-server` lists the built-in tools plus every currently
  registered client tool. It watches for `client_tools.changed` and sends MCP
  `notifications/tools/list_changed` when the set changes.
- **Harness parity is required.** Every harness Leo spawns (Claude Code, Codex,
  opencode) must be able to use client tools that appear mid-session.
- Plan step 0 is an empirical probe: a test MCP server that registers a tool
  after connect and sends `list_changed`, run against the installed version of
  each harness. The result is recorded per harness in the daemon
  (`honorsToolListChanged`).
- Harnesses that honor it get native tools, as above.
- Harnesses that don't get two fixed fallback tools instead: `leo_app_tools`
  (lists the currently registered client tools with their descriptions and
  schemas) and `leo_app_call {tool, args}` (same call path and result content as
  a native call). Their tool list never changes mid-session.
- The fallback tools are listed only once any app has registered client tools
  with this daemon at least once (a persisted flag), so terminal-only users
  never see them.
- Registered client tools count as known tools for leo's permission allowlist
  (`leotools.IsKnownTool`) while registered.

### Calls

- `POST /api/agent/{name}/client-tools/call` `{tool, args}` (from the MCP server).
  The daemon creates `{id, agent, group, tool, args, owner}`, keeps it in memory
  (not SQLite), publishes `client_tool.request`, and blocks until it settles or
  times out.
- Ownership is per (agent, group): the first provider to claim
  (`POST /api/v1/client-tools/requests/{id}/claim`) owns that agent's group.
  Later requests carry `owner`, and only the owner may claim them; others get 409.
  Ownership is released when the owner's subscription closes.
- `POST /api/v1/client-tools/requests/{id}/result` with `{ok, content?, error?}`.
  `content` is a list of MCP content blocks (text, image), passed through
  unchanged. Only the claimant may post, and a second result gets 409.
- `GET /api/v1/client-tools/requests?pending=1` lists unsettled requests so a
  reconnecting client (or one that saw `gap`) can pick them up.
- The tool was withdrawn, or no provider is connected → fail immediately with
  `no_client` ("No connected Leo app provides this tool").
- A parked request is cancelled when its timeout elapses, the agent's MCP call is
  cancelled, or the agent stops.

## Mac app

### Browser tools (declared by the app, group `browser`)

All take optional `tab` (tab id; default = active tab) except where noted.
Timeout is 30 s unless noted.

| Tool | Args | Returns |
|---|---|---|
| `browser_navigate` | `url` | final URL, title (waits for load) |
| `browser_back` / `browser_forward` / `browser_reload` | — | URL, title |
| `browser_snapshot` | — | text tree of the page with element refs, truncated at 50 000 chars with a note |
| `browser_click` | `ref` | ok |
| `browser_type` | `ref`, `text`, `submit?` | ok |
| `browser_press` | `key` (e.g. `Enter`, `Escape`, `Meta+a`) | ok |
| `browser_screenshot` | `full_page?` | PNG image block, max 1600 px wide |
| `browser_wait` | `text?` or `ms?` (≤ 25 000) | ok / timeout |
| `browser_eval` | `js` | JSON-serialised result |
| `browser_console` | `since?` | console messages captured since last call |
| `browser_tabs` | — (no `tab`) | list `{id, url, title, active}` |
| `browser_tab_new` | `url?` | new tab id (becomes active) |
| `browser_tab_select` | `tab` (required) | ok |
| `browser_tab_close` | `tab` (required) | ok |
| `browser_handoff` | `message` (no `tab`); timeout 0 | `done` or `declined`; blocks until Evan answers |

The app registers this group with every connected machine's daemon. The
browser feature can be switched off in Settings, which withdraws the group.

### Agent browser

- One `LeoAgentBrowser` per (machine, agent), created on the first request for
  that agent or when Evan opens it from the row. It holds up to 10 tabs
  (`tab_new` beyond 10 fails with `tab_limit`).
- Each tab is a `WKWebView` sharing the agent's
  `WKWebsiteDataStore(forIdentifier:)`. The identifier is a UUIDv5 of
  `machine id + agent name`, so the store survives agent restarts and app
  relaunches with no lookup table.
- `target=_blank` links and `window.open` open a new tab in the same browser
  (counts against the cap).
- Allowed schemes: `http`, `https`, `about:blank`. Others fail with `scheme_not_allowed`.
- The browser closes when the agent stops or Evan closes the pane. The data store is kept.

### Pane UI

- A new content case in `LeoRowPane` beside editor tabs: an inner tab strip,
  URL bar, back/forward/reload, and a control pill (**Agent driving** /
  **You have control**).
- When the agent first opens the browser, the pane opens without taking focus,
  and the sidebar row shows a globe badge while the browser exists.
- Takeover: any user mouse or keyboard input in a web view, or clicking the
  pill, switches to **You have control**. While it is on, agent actions that
  change the page (`navigate`, `back`/`forward`/`reload`, `click`, `type`,
  `press`, `eval`, `tab_new`/`select`/`close`) fail with `user_has_control`
  ("The user has control of the browser; wait or call browser_handoff").
  `snapshot`, `screenshot`, `tabs`, `console` and `wait` still work. **Give back**
  returns control.
- Handoff: `browser_handoff` shows a banner with the agent's message and
  **Done** / **Decline**, switches to **You have control**, and posts a local
  notification through the existing attention notification path. Done or
  Decline settles the request and gives control back.

### Executor

- Claims `client_tool.request` events in group `browser` for agents on that
  machine, runs them, and posts results.
- `snapshot`: an injected script walks the DOM (role, accessible name, value,
  visible interactive elements) and tags each element with a ref. Refs stay
  valid until the next snapshot or navigation in that tab; a stale ref fails
  with `stale_ref`.
- `click`/`type`/`press`: scroll the element into view, then deliver real
  input events to the web view so pages treat them as user input. **This must
  work while the pane is hidden or another row is selected**; the plan must
  prove the chosen mechanism in that state.
- `screenshot`: `WKWebView.takeSnapshot`. `console`: an injected script buffers
  the last 500 messages per tab.
- Errors are returned as `{ok:false, error:{code, message}}` with the codes above
  plus `navigation_failed`, `timeout`, `js_error`.

### Port forwarding

- Only for remote machines, and only when a URL's host is `localhost`,
  `127.0.0.1` or `[::1]`. The local machine never forwards.
- The forward runs over the machine's existing ControlMaster
  (`ssh -O forward -L`). If the plan finds that doesn't work with the current
  ssh config, fall back to one `ssh -N -L` process per forward, reusing
  `LeoSSHCommand`.
- The local port matches the remote one when it's free, so origin, cookies and
  OAuth redirects match. Otherwise a free port is chosen and the URL rewritten.
  URLs reported to the agent are always in remote terms (rewritten back).
  Accepted limitation: a page with absolute links to the remote port breaks
  when the ports differ.
- Forwards close when the agent's browser closes or the machine disconnects.

## Out of scope (v1)

iOS executor (backlog), downloads/uploads, network-request logs, deleting a
pruned agent's data store, file:// URLs, a browser on the daemon host, other
client-tool groups.

## Security

- Only authenticated daemon clients (the existing socket/bearer auth) can
  register tools or post results.
- `browser_eval` runs arbitrary JS, but only in that agent's own isolated store.
- Agent identity comes from the MCP server's `LEO_PROCESS_NAME`, the same as the
  existing chat tools; an agent able to spoof it could drive another agent's
  browser. Accepted, consistent with chat.
- The forward binds to loopback only: `127.0.0.1` and `[::1]` (both, so `localhost`
  resolves to the forward whichever family the OS picks).

## Testing

- Daemon (Go): registration validation and collisions; withdrawal on disconnect;
  `list_changed` emitted on change; park/settle; per-tool timeout and timeout 0;
  `no_client`; ownership + 409 on a second claimant and on a second result;
  release on subscriber disconnect; pending-list recovery; cancellation on agent
  stop; image content pass-through; native vs fallback listing chosen by
  harness; fallback hidden until the first registration, shown after it (persisted).
- Harness probe (step 0) re-runnable as a script, so a harness upgrade can be
  rechecked.
- Mac (Swift Testing): executor op mapping and error codes against a fake web
  view protocol; takeover state machine; tab cap and popup → tab; forward
  manager against a fake ssh runner (same-port, fallback port, URL rewrite both
  ways, teardown); snapshot script in a real `WKWebView` loading a local HTML
  fixture.
- End to end: a real agent on a remote machine runs a dev server, navigates to
  `localhost:<port>`, snapshots, clicks, opens a second tab, and hands off.
  Verified by a windowed capture of the pane.

## Success criteria

1. On a daemon that has never had an app register tools, an agent's tool list
   contains no `browser_*` or `leo_app_*` tools. Connecting the app makes the
   browser usable in an already running agent on each of Claude Code, Codex and
   opencode, with no restart: natively where the harness honors `list_changed`,
   via `leo_app_call` otherwise. Exception: the very first registration on a
   daemon, for a harness that ignores `list_changed`, needs one agent restart
   (its fixed list was sampled before the flag existed).
2. An agent on Dionysus opens its own `localhost:5173` dev server in the pane
   and clicks through it using snapshot refs.
3. Evan clicks into the page; the agent's next click returns `user_has_control`;
   Give back restores it.
4. `browser_handoff("Log in please")` blocks until Evan presses Done.
5. Two tabs: the agent lists, switches and closes them; a `target=_blank` link
   lands as a new tab.
6. Quitting the app while an agent holds the tools makes the next call fail
   with `no_client` and withdraws the tools.
