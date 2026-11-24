# Plugin credentials on remote machines

Status: draft for Evan's approval (2026-11-24)
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
- `POST /credentials/fetch` takes `{kind, dir, url, method, headers, body?}` and returns `{status, headers, body}` or `{error}`. The error reasons are the app's existing ones: `credentialHostMismatch`, `credentialHeaderConflict`, `credentialNeedsAuthorization`, `credentialUnavailable`.

### Rules, mirroring the app's fetcher exactly
- `dir` must be one listed by `/credentials/accounts`. There are no arbitrary paths.
- Each kind has a fixed bound host: `claude-code` → `api.anthropic.com`, `codex` → `chatgpt.com`. HTTPS only.
- Every redirect hop must stay on the bound host, or the request fails with `credentialHostMismatch`.
- Injected headers are the same as the app's. That includes `User-Agent: claude-cli/2.1.0 (external, cli)` for Claude, from the pending app change d0e4a4d7e.
- A caller header that collides with an injected one, compared case-insensitively, fails with `credentialHeaderConflict`.
- Response bodies are capped at 5 MB and requests time out at 30 s.
- There is no token refresh and no writes to CLI-owned files or Keychain items.

### Token source
- Codex reads `<dir>/auth.json`.
- Claude reads `<dir>/.credentials.json` first, then the Keychain item `Claude Code-credentials[-sha8]`.
- The Keychain read must never block on a UI prompt. If it would need one, the daemon returns `credentialNeedsAuthorization`. See open question 1.

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

## Open questions

1. **Claude Keychain access from the daemon on Dionysus.** A headless read through `/usr/bin/security` would prompt "security wants to access…". Clicking Always Allow there would let any process read the item through `security`, which is too broad. Two options:
   - **(a)** The daemon reads through Security.framework (cgo), so the Keychain approval names the leo binary. The cost: a re-sign on each leo update re-prompts.
   - **(b)** Rely on `.credentials.json`, if Claude Code on Dionysus stores custom-dir logins there.

   The planner verifies which store the Dionysus accounts actually use before choosing.
2. Does the app reach remote daemons through a forwarded Unix socket or through the HTTPS `/api` with a bearer token? This decides which daemon mux the routes go on. The planner confirms.
