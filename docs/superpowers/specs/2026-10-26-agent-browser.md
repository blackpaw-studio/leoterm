# Agent Browser — spec

Date: 2026-10-26 · Status: draft, awaiting approval

## Goal

A browser inside the Leo Mac app that a Leo agent drives through MCP tools and
that Evan can watch and take over. A dev server on a remote agent's
`localhost` opens in it through a port forward on that machine's ssh connection.

Platform call: **Mac only** for v1. The request protocol client and the
snapshot script live in LeoKit so iOS can adopt them; the iOS executor is
deferred to the autopilot backlog.

## Decisions (settled with Evan)

- Shared, agent-driven browser that the user can take over (not preview-only, not headless).
- Engine: `WKWebView` in the Mac app. No Chromium, no CDP.
- Cookies/storage: one persistent store per agent.
- Multiple tabs per agent are in scope.

## Architecture

Two repos change:

1. **leo daemon** (`~/.leo/agents/leo`, Go). Adds MCP tools and a generic
   "client request" channel. Ships as a PR reviewed and merged by the `leo` agent.
2. **Leo Mac app** (this repo). Adds the browser pane, the executor that
   serves requests, and the port-forward manager.

Flow: agent calls `browser_*` → stdio MCP server → daemon parks the call →
daemon publishes `browser.request` on the SSE bus → the owning Mac app runs it
against the agent's `WKWebView` → app POSTs the result → daemon settles the
parked call → tool returns.

## Daemon

### Client request channel

- `POST /api/agent/{name}/browser` (from the MCP server) with `{op, tab?, args}`.
  The daemon creates a request `{id, agent, op, tab, args, owner}`, keeps it in
  memory (not SQLite), publishes `browser.request`, and blocks until it is settled
  or times out.
- Capability: an SSE subscriber opts in with `?capabilities=browser`. The
  daemon assigns each subscription a `client_id` (returned in `hello`).
- Ownership: each agent's browser has at most one owner client. The first
  browser-capable client to claim a request (`POST /api/v1/browser/requests/{id}/claim`)
  becomes the owner for that agent. Later requests for that agent carry
  `owner`, and only the owner may claim them (others get 409). Ownership is
  released when the owner's SSE subscription closes.
- Result: `POST /api/v1/browser/requests/{id}/result` with `{ok, value?, error?}`.
  Only the claimant may post; a second result gets 409.
- Recovery: `GET /api/v1/browser/requests?pending=1` lists unsettled requests so
  a client that reconnects (or saw `gap`) can pick them up.
- No browser-capable client subscribed when a request arrives → fail
  immediately with `no_browser_client` ("No Leo app with a browser is connected").
- Timeouts: 30 s default per op; `browser_wait` capped at 30 s; `browser_handoff`
  has no timeout. Any parked request is cancelled when the agent's MCP call is
  cancelled or the agent stops.

### MCP tools

All take optional `tab` (tab id; default = active tab) except where noted.

| Tool | Args | Returns |
|---|---|---|
| `browser_navigate` | `url` | final URL, title (waits for load, ≤30 s) |
| `browser_back` / `browser_forward` / `browser_reload` | — | URL, title |
| `browser_snapshot` | — | text tree of the page with element refs, truncated at 50 000 chars with a note |
| `browser_click` | `ref` | ok |
| `browser_type` | `ref`, `text`, `submit?` | ok |
| `browser_press` | `key` (e.g. `Enter`, `Escape`, `Meta+a`) | ok |
| `browser_screenshot` | `full_page?` | PNG as MCP image content, max 1600 px wide |
| `browser_wait` | `text?` or `ms?` | ok / timeout |
| `browser_eval` | `js` | JSON-serialised result |
| `browser_console` | `since?` | console messages captured since last call |
| `browser_tabs` | — (no `tab`) | list `{id, url, title, active}` |
| `browser_tab_new` | `url?` | new tab id (becomes active) |
| `browser_tab_select` | `tab` (required) | ok |
| `browser_tab_close` | `tab` (required) | ok |
| `browser_handoff` | `message` (no `tab`) | `done` or `declined`; blocks until Evan answers |

Tool names are added to `leotools.IsKnownTool`.

## Mac app

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

- Subscribes with `capabilities=browser` on each machine's event stream, claims
  `browser.request` events for agents on that machine, runs them, and posts results.
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
pruned agent's data store, file:// URLs, a browser on the daemon host.

## Security

- `browser_eval` runs arbitrary JS, but only in that agent's own isolated store.
- Agent identity comes from the MCP server's `LEO_PROCESS_NAME`, the same as the
  existing chat tools; an agent able to spoof it could drive another agent's
  browser. Accepted, consistent with chat.
- The forward binds to `127.0.0.1` only.

## Testing

- Daemon (Go): park/settle, timeout, `no_browser_client`, ownership + 409 on
  second claimant and on second result, release on subscriber disconnect,
  pending-list recovery, cancellation on agent stop.
- Mac (Swift Testing): executor op mapping and error codes against a fake web
  view protocol; takeover state machine; tab cap and popup → tab; forward
  manager against a fake ssh runner (same-port, fallback port, URL rewrite both
  ways, teardown); snapshot script in a real `WKWebView` loading a local HTML
  fixture.
- End to end: a real agent on a remote machine runs a dev server, navigates to
  `localhost:<port>`, snapshots, clicks, opens a second tab, and hands off.
  Verified by a windowed capture of the pane.

## Success criteria

1. An agent on Dionysus opens its own `localhost:5173` dev server in the pane
   and clicks through it using snapshot refs.
2. Evan clicks into the page; the agent's next click returns `user_has_control`;
   Give back restores it.
3. `browser_handoff("Log in please")` blocks until Evan presses Done.
4. Two tabs: the agent lists, switches and closes them; a `target=_blank` link
   lands as a new tab.
5. With no Mac app connected, a browser tool fails immediately with `no_browser_client`.
