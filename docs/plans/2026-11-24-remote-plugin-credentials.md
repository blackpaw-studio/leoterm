# Plan: plugin credentials on remote machines

Spec: `docs/superpowers/specs/2026-11-24-remote-plugin-credentials.md`. The spec wins if the two conflict.
Planner run: d-303d74e5e777. The orchestrator's decisions are at the end.

## Cross-repo contract
These routes live on the daemon's Unix-socket mux only, with no `/api` prefix.

**`GET /credentials/accounts?kind=claude-code`**
- Returns `{"accounts":[{"kind":"claude-code","dir":"/abs/path","label":"ENV_NAME"}]}`.
- `kind` is optional.

**`POST /credentials/check`**
- Request: `{"kind","dir"}`.
- Returns `{"ok":true}` or `{"error":{reason,message}}`.

**`POST /credentials/fetch`**
- Request: `{"kind","dir","url","method","headers":[["n","v"]],"bodyBase64"?}`.
- Returns `{"status":200,"headers":[["n","v"]],"bodyBase64":"…"}`, or `{"error":{"reason":R,"message":"…"}}`.

**Status codes:** credential and validation errors come back as HTTP 200 with an `error` body. 4xx/5xx is only for malformed JSON.

**Reasons (`R`):**
- `credentialHostMismatch`
- `credentialHeaderConflict`
- `credentialNeedsAuthorization`
- `credentialInvalid`: the dir isn't listed, there's no login, or the token is bad
- `invalidRequest`
- `bodyTooLarge`
- `networkError`

`credentialMachineUnavailable` is produced by the app only: offline, socket missing, timeout, or a 404 from an older daemon.

**Secrets:** messages never contain token bytes.

## Daemon PR (`/Users/evan/.leo/agents/leo`, Go)
Review with `review.security`. The `leo` agent merges it.

**D1 `internal/credentials/accounts.go`: `Accounts(cfg, home) []Account`**
- Lists the defaults `~/.claude` and `~/.codex`, plus literal `CLAUDE_CONFIG_DIR` / `CODEX_HOME` values from `environments:`.
- Skips secret refs.
- Expands paths with `config.Expander`, runs `filepath.Clean` on them, and dedups by (kind, dir).
- Labels each account with its env name, falling back to the basename.
- Starting test: `TestAccountsFromEnvironments`.

**D2 `keychain_darwin.go` / `keychain_other.go`: `TokenSource.Resolve(ctx, kind, dir)`**
- `ServiceName(dir)` is the first 8 hex chars of sha256 over the standardized absolute path. Bare `~/.claude` uses no suffix.
- Test vector: `/Users/evan/.claude-blackpaw-leo` → `4d74f2ae`.
- Reads the secret with `/usr/bin/security find-generic-password -a $USER -s <svc> -w`.
  - The runner is injected.
  - 5 s timeout, no shell.
  - Stdout is never logged.
- Exit codes:
  - 44 → fall back to `<dir>/.credentials.json`.
  - Timeout or any other non-zero code → `credentialNeedsAuthorization`.
- Codex reads `<dir>/auth.json` (`tokens.access_token`, `tokens.account_id`).
- Rejects non-ASCII tokens.
- The non-darwin build reads files only.

**D3 `fetch.go`: `Fetcher{Source, Transport, Clock}`**
- Mirrors the request validation in `LeoPluginFetcher.makeRequest`:
  - method allowlist
  - ≤50 headers
  - forbidden and `proxy-*` headers rejected
  - no CR, LF or NUL
  - 8 KB per header value
  - ≤5 MB body
  - no body on GET/HEAD
- HTTPS only, and the host must equal the kind's bound host.
- Reserved headers, compared case-insensitively, fail with `credentialHeaderConflict`:
  - Claude: `authorization`, `anthropic-beta`, `user-agent`
  - Codex: `authorization`, `chatgpt-account-id`
- Injected headers:
  - Claude: `anthropic-beta: oauth-2025-04-20` and `User-Agent: claude-cli/2.1.0 (external, cli)`
  - Codex: `ChatGPT-Account-Id`
- `CheckRedirect` re-checks the bound host on every hop.
- 30 s timeout. The response body is capped at 5 MB.
- Tests:
  - host mismatch, on the first hop and on a redirect
  - header conflict
  - body cap
  - needs-auth
  - dir not listed
  - errors never contain the token

**D4 `internal/daemon/credentials_routes.go`**
- Registers the three routes on the socket mux in `server.go`.
- Loads config per call.
- httptest coverage for each route.
- `TestWebMuxHasNoCredentialRoutes` checks that operator, agent and device tokens all get a 404.

**Verify:** `go test -race ./internal/credentials/ ./internal/daemon/ ./internal/web/ -run Credential`, and `make test` at the gate.

## LeoKit and app (leoterm, branch `feat/remote-plugin-credentials`)
Mac only: iOS has no plugin host.

**A0** Merge `fix/plugin-claude-user-agent` (d0e4a4d7e) into this branch first.

**A1 `LeoPluginCredentialGrant.swift`**
- Add `machine: LeoHostID`. When the field is missing on decode, it defaults to `.local`.
- `addGrant` dedups by (kind, path, machine).
- The JS handle includes `machine` (the display name) only for remote grants.
- Tests:
  - legacy decode
  - round-trip
  - handle shape for local and for remote

**A2 `LeoDaemonClient` + `LeoSocketDaemonClient`**
- Adds `credentialAccounts(kind:)`, `credentialCheck(kind:dir:)`, and `credentialFetch(_:)` with a 35 s timeout.
- Tests: encoding and decoding over a fake transport.

**A3 Fetch routing**
- Adds a `LeoPluginRemoteCredentialForwarding` seam, `(LeoHostID) -> LeoDaemonClient?`.
- For a remote grant, checks run in this order before the request is forwarded:
  1. URL check
  2. manifest network engine
  3. bound host
  4. header checks
  5. rate limiter
- No `source.resolve()` call on the Mac.
- Daemon errors map to the existing JS reason strings.
- These outcomes all become `credentialMachineUnavailable: <name> is offline`:
  - nil client
  - unavailable host
  - socket missing
  - transport error
  - timeout
- A 404 becomes "<name>'s Leo is too old to share accounts".
- Tests:
  - local grants never touch the forwarder
  - remote grants forward
  - a bad host or header conflict is rejected before forwarding (forward count 0)
  - the rate limit applies to remote requests
  - offline and 404 mappings

**A4 Add sheet** (replaces the bare `LeoPluginCredentialPicker`)
- A machine pop-up with "This Mac" plus the connected `LeoMachineClients` hosts.
- Choosing "This Mac" opens the existing NSOpenPanel.
- Choosing a remote host lists `credentialAccounts(kind)`. A remote grant is saved only after `credentialCheck` succeeds.
- The gesture is spent once, up front.
- The model is tested. The UI is checked with a screenshot (a TDD exception).

**A5 Settings rows** show `kind · machine · ~/path`, with "This Mac" for local. Test: `LeoPluginsSettingsModelTests`.

**Verify:**
- `cd Packages/LeoKit && swift test --filter LeoPlugin`
- macOS model tests under `heavy`
- one screenshot of the sheet

## Plugin (`/Users/evan/.leo/agents/leo-plugin-usage` → v0.2.0)

**P1 `src/api.ts`**
- Add `Handle.machine?: string`.
- Add `credentialMachineUnavailable` and `credentialInvalid` to the reasons.
- Machine unavailable maps to a new `offline` outcome.

**P2 State and copy**
- `offline` shows as stale when there are values, error otherwise.
- Copy:
  - **offline:** "<machine> is offline · values from …"
  - **expired:** "Token expired — use this account in Claude Code (on <machine>) to renew". Codex reads "in Codex". Drop "(on <machine>)" when the account is local.
  - **subtitle:** `machine · path · Updated …` when `machine` is present.
- Copy Sign-in Command stays.

**P3** Bump to 0.2.0 and rebuild `dist/`. Tagging needs Evan's approval.

**Verify:** `npm run typecheck && npm test && npm run build && git diff --exit-code dist/`

## Order
- D, A (after A0) and P run in parallel against the contract.
- Live E2E needs these steps in order:
  1. leo release
  2. Dionysus daemon update
  3. leoterm bump PR
  4. app build
  5. plugin release
- Then, from the laptop, add Dionysus `~/.claude-blackpaw-leo` and `~/.codex`. The numbers should match `claude /usage` there, and the laptop should need no login.

## Orchestrator decisions on the planner's open items
1. Token source is the `security` CLI, Keychain first, falling back to the file. D0 is already satisfied: on 2026-11-23 the same `security … -w` call on Dionysus returned the token with no dialog. The spec has been amended to match.
2. `/credentials/check` replaces the "harmless probe URL" from the spec, and `credentialInvalid` replaces `credentialUnavailable`. Both are amended in the spec.
3. Routes are socket-only. Same-user access to them is an accepted risk.
4. A 404 from an older daemon maps to `credentialMachineUnavailable` with the "too old" message. There is no new reason.
5. Local handles omit `machine`, so there is no matching on a "This Mac" string.
6. A stuck SecurityAgent dialog is bounded by the 5 s timeout and returns needs-auth. Accepted.
