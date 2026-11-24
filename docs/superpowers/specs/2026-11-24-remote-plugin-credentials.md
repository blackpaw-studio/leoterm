# Plugin credentials on remote machines

Status: approved by Evan 2026-11-24. Orchestrator amendments after planning are marked (amended).
Platform: **Mac app + leo daemon.** iOS has no plugin host.

## Goal

A plugin's `credentials` grant can name an account that lives on another Leo machine, such as Dionysus. The request runs on that machine and the token never leaves it. Evan then doesn't need to keep Claude and Codex logins on the laptop just so the Usage plugin can see accounts his agents use on Dionysus.

This is a general platform ability ("act as account X on machine Y"). Leo learns nothing about usage. Windows, percentages and the usage URL stay in the plugin.

## How it works

1. A grant gains a `machine` field. Today's grants become `local`.
2. When a plugin calls `leo.fetch(url, {credential})` and the grant is local, nothing changes.
3. When the grant is remote, the app sends the request to that machine's daemon through the existing remote daemon client. The daemon reads the token locally, applies the same rules the app applies today, makes the request, and returns `{status, headers, body}`.
4. The plugin sees the same promise result and the same rejection reasons either way.

## Daemon (leo repo, Go; PR reviewed and merged by the `leo` agent)

### New routes
The routes go on the operator-authenticated API, never on routes agents or paired devices can call.
- `GET /credentials/accounts` lists the accounts this machine knows: `[{kind, dir, label}]`.
  - It includes the default `~/.claude` and `~/.codex`, plus every `CLAUDE_CONFIG_DIR` / `CODEX_HOME` named in `environments:` config.
  - `label` is the environment name, or the dir's basename.
  - It returns no tokens and no token metadata.
- `POST /credentials/check` takes `{kind, dir}` and returns `{ok}` or `{error}`. It only resolves the token, which is the same validation local adds do today, so Leo holds no plugin-owned probe URL. (amended)
- `POST /credentials/fetch` takes `{kind, dir, url, method, headers, bodyBase64?}` and returns `{status, headers, bodyBase64}` or `{error: {reason, message}}`. The error reasons are the app's existing ones, using `credentialInvalid` where an earlier draft said `credentialUnavailable` (amended). The exact JSON is in the plan.
- Routes are on the daemon's Unix-socket mux only, the one the Mac app reaches over its SSH socket forward. They are never on the web `/api` mux, so agent and device tokens cannot reach them. (amended)

### Rules, mirroring the app's fetcher exactly
- `dir` must be one listed by `/credentials/accounts`. There are no arbitrary paths.
- Each kind has a fixed bound host: `claude-code` → `api.anthropic.com`, `codex` → `chatgpt.com`. HTTPS only.
- Every redirect hop must stay on the bound host, or the request fails with `credentialHostMismatch`.
- Injected headers are the same as the app's. That includes `User-Agent: claude-cli/2.1.0 (external, cli)` for Claude, from the pending app change d0e4a4d7e.
- A caller header that collides with an injected one, compared case-insensitively, fails with `credentialHeaderConflict`.
- Response bodies are capped at 5 MB and requests time out at 30 s.
- There is no token refresh and no writes to CLI-owned files or Keychain items.

### Token source (amended)
- Codex reads `<dir>/auth.json`.
- Claude reads the Keychain item `Claude Code-credentials[-sha8]` first, matching the app. It falls back to `<dir>/.credentials.json` only when the item is missing (`security` exit 44). On Dionysus every config dir has a fresh Keychain item, and the `.credentials.json` copies are stale or absent.
- The read shells out to `/usr/bin/security find-generic-password -a $USER -s <svc> -w`, with an absolute path, no shell, a 5 s timeout, and stdout never logged. Any other failure maps to `credentialNeedsAuthorization`. Non-darwin builds read the file only.
- Using the `security` CLI was confirmed on 2026-11-23: the same command on Dionysus returned the token with no dialog. It also grants nothing new, because same-user processes can already run it.

## Mac app (LeoKit plus macos/)

- **Grant:** `{id, kind, path, machine}`, where `machine` is a `LeoHostID`. Stored grants with no `machine` decode as `.local`.
- **Handle to JS:** a new field `machine: string` with the display name, `"This Mac"` for local grants. It is additive, so the apiVersion stays at 2.
- **Fetch routing:** remote grants go through `LeoDaemonClient` for that host.
  - The per-plugin rate limit, in-flight cap and manifest network check still run in the app, before forwarding.
  - The bound-host and header checks also run in the app first, so a bad request never leaves the Mac.
- **`leo.credentials.add(kind)`:** shows a small sheet in place of the bare NSOpenPanel. Keep it gesture-only, as today.
  - The sheet opens with a machine pop-up: "This Mac" plus each connected machine.
  - "This Mac" shows "Choose Folder…", the existing panel.
  - A remote machine shows its `/credentials/accounts` list for that kind, with matching kinds only.
  - The grant is saved only after one successful probe fetch to `/credentials/fetch`. The probe uses a kind-specific harmless URL, the same validation as local adds today.
- **Machine offline:** fetch rejects with a new reason, `credentialMachineUnavailable`.
- **Settings → Plugins:** account rows show `kind · machine · ~/path`.

## Usage plugin (leo-plugin-usage, v0.2.0)

- The group subtitle shows the machine for remote accounts: `Dionysus · ~/.claude-blackpaw-leo · Updated 3m ago`.
- `credentialMachineUnavailable` maps to the stale or error state: "Dionysus is offline · values from …".
- The expired copy becomes "Token expired — use this account in Claude Code (on Dionysus) to renew". It is not "Signed out".
- Copy Sign-in Command stays as an action.

## Non-goals

- Token refresh or renewal, either way. Accounts on Dionysus stay fresh because agents use them. A daemon-side `claude` renew is a possible follow-up.
- Syncing tokens between machines.
- Plugins running on the daemon.
- Account discovery beyond the default dirs plus `environments:`.
- iOS.

## Security

- The new routes act as the operator, so they sit behind the same auth as other operator routes. Agent tokens are refused. An agent could otherwise use another account's token.
- Tokens never appear in responses, logs or errors.
- Treat it as a security-sensitive diff on both sides (`review.security`).

## Testing

- **Daemon (Go, TDD):**
  - account listing from config
  - dir allowlist
  - bound host on the first hop and on redirects
  - header conflict
  - body cap
  - needs-authorization path
  - agent token refused

  The token sources and HTTP transport are faked.
- **LeoKit:**
  - grant decoding (legacy to `.local`)
  - routing: local stays in-process, remote goes to the daemon client
  - local pre-checks run before forwarding
  - machine-unavailable mapping
- **Plugin:** subtitle, offline and expired copy.
- **Live E2E:** the laptop app adds `Dionysus · ~/.claude-blackpaw-leo` and `Dionysus · ~/.codex`. The numbers match `claude /usage` on Dionysus, and the laptop has no login for those accounts.

## Resolved questions
1. Keychain on Dionysus: use the `security` CLI (see Token source). cgo / Security.framework is rejected because it costs CGO_ENABLED=0 and adds re-prompts.
2. The app reaches remote daemons through an SSH-forwarded Unix socket (`LeoSocketDaemonClient`), so the routes go on the socket mux.
3. A remote daemon without these routes returns 404. The app maps that to `credentialMachineUnavailable` with the message "<machine>'s Leo is too old to share accounts".
4. The JS handle includes `machine` only for remote grants. Local handles omit it, so the plugin never matches on a "This Mac" string. Settings and the add sheet still show "This Mac".
5. Accepted risk: a same-user process on the remote machine can open the 0600 socket. That is no new privilege, since it can already spawn agents and run `security`.
