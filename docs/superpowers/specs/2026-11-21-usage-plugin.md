# Account Usage plugin (Mac)

Status: approved (Evan pre-approved recommendations, 2026-11-21; calls below are the orchestrator's, open for veto)
Platform: **Mac only.** The plugin platform exists only on Mac; iOS has no plugin host. No iOS backlog item until iOS gets plugins.

## Goal

A separately-installed Leo plugin (not in the app bundle) that shows Claude Code and Codex rate-limit usage for **many accounts at once**, CodexBar-style, native and HIG-compliant.

- Claude account = one Claude config dir (`~/.claude` or any `CLAUDE_CONFIG_DIR`).
- Codex account = one `CODEX_HOME` (default `~/.codex`).
- Accounts are local to the Mac running Leo. Remote machines' accounts are out of scope.

## Shape

Two parts:

1. **Platform additions (in the app, LeoKit + macos/)**: generic, reusable by any plugin, gated behind manifest `apiVersion: 2`. Old apps refuse v2 manifests (existing validator behaviour).
2. **The plugin** (`plugins/usage/` in this repo, id `studio.blackpaw.usage`): JS bundle + `leo-plugin.json`. **Not** copied into the app bundle. Installed via Settings → Plugins → "Load local folder…" (dev mode) or "Install from URL…" once it has its own repo (publishing that repo needs Evan's approval and is not part of this work).

## Platform addition 1: `credentials` permission

Manifest: `permissions.credentials: ["claude-code", "codex"]` (any subset). Each kind is a host-defined adapter with a **fixed** host binding:

| Kind | Account key | Token source (read fresh on every use) | Bound host | Injected headers |
|---|---|---|---|---|
| `claude-code` | config dir path | Keychain generic password, service `Claude Code-credentials` for `~/.claude`, else `Claude Code-credentials-<first 8 hex of sha256(absolute dir path, no trailing slash)>` (verified on this Mac against 5 dirs); JSON `claudeAiOauth.accessToken`. Fallback: `<dir>/.credentials.json`, same shape. | `api.anthropic.com` | `Authorization: Bearer …`, `anthropic-beta: oauth-2025-04-20` |
| `codex` | `CODEX_HOME` path | `<dir>/auth.json` → `tokens.access_token`, `tokens.account_id` | `chatgpt.com` | `Authorization: Bearer …`, `ChatGPT-Account-Id: …` |

Bridge API (v2):

- `leo.credentials.add(kind) → Promise<Handle | null>` — **gesture-only** (from a callback that came from a user action). Host shows an NSOpenPanel (hidden files visible, starting at `~`) to pick the dir, validates it (Claude: a token is readable; Codex: `auth.json` parses), and persists the grant. The first Keychain read happens here, so the macOS "Leo wants to access…" prompt only ever appears in response to the user. `null` on cancel.
- `leo.credentials.list() → Handle[]`; `leo.credentials.remove(id)`.
- `Handle = {id (opaque), kind, label (dir basename, e.g. "claude-blackpaw-leo"), path (display only, ~-abbreviated)}`.
- `leo.fetch(url, {credential: id, …})` — the host injects the headers above **only** when every hop's host equals the kind's bound host. On a hop to any other host it rejects with `credentialHostMismatch` (no silent stripping). The plugin must also list the bound host under `permissions.network`.
- Tokens never enter the plugin process. Plugin-supplied `Authorization` / `ChatGPT-Account-Id` headers are rejected when `credential` is set.
- Background reads use no-UI Keychain lookups. If one would need UI, reject with `credentialNeedsAuthorization`. The plugin shows a "Grant access" action, which retries via `leo.credentials.authorize(id)` (gesture-only, UI allowed).
- **No token refresh, no writes** to CLI-owned files or Keychain items (refreshing would rotate tokens out from under the CLI). On an expired token the API returns 401 and the plugin shows the expired state.
- Grants are stored per plugin in the plugin store. Uninstalling the plugin or revoking the permission deletes them. Settings → Plugins shows granted accounts under the plugin's permissions, each removable.

## Platform addition 2: `Meter` component

`Meter {label, value (0…1, clamped), valueText?, detail?, tone: neutral|success|warning|failure}`, rendered natively. It is a thin rounded capsule track with a semantic tint, label leading, `valueText` trailing (monospaced digits), and `detail` as secondary text below. It's usable as a slot-root element and as a child of a new `Group {title, subtitle?, sfSymbol?, accessory?, children: [Meter|Accessory], actions?}` container. VoiceOver reads it as "label, valueText, detail". It follows light/dark mode and Increase Contrast.

## The plugin

Manifest: apiVersion 2; `network: ["api.anthropic.com", "chatgpt.com"]`; `credentials: ["claude-code", "codex"]`; `secrets: false`. It contributes:

- **Sidebar section "Usage"** (glanceable, all accounts): one compact `Group` per account showing the label and kind glyph, then the account's **highest** current window as a Meter (`"Session 42%"`, detail `"resets in 2h 14m"`). A header accessory shows the overall worst tone. An "Add Account…" action is always present.
- **Command "Show Account Usage"**: pushes the full view, with one `Group` per account and every window as a Meter:
  - Claude: Session (`five_hour`), Weekly (`seven_day`), plus Weekly Opus / Weekly Sonnet when present (`seven_day_opus`, `seven_day_sonnet`).
  - Codex: Session (`rate_limit.primary_window`), Weekly (`secondary_window`).
  - Group subtitle: path + "Updated 3m ago". Actions: Refresh, Rename (Form), Remove, Grant access (when needed).
- **Commands** "Add Claude Account…", "Add Codex Account…", "Refresh Usage".

Data:
- Claude: `GET https://api.anthropic.com/api/oauth/usage`. Each window has `utilization` (0–100) and `resets_at` (ISO8601). Unknown or null windows are skipped.
- Codex: `GET https://chatgpt.com/backend-api/wham/usage`. Each window has `used_percent`, `reset_at` (epoch s), and `limit_window_seconds`.
- Parsers are pure functions, tolerant of missing fields. A response with no recognised window reads as "No usage data".
- Polling: every 5 min via `leo.timer(300)`, plus on activate and manual Refresh. Requests are sequential, staying well under the 60 req/min cap. On 429, back off that account to 15 min.
- Tone thresholds: below 75% success, 75% to below 90% warning, 90% and up failure.
- States per account: loading (first fetch only), ok, stale (last good values plus a "Couldn't refresh" detail), expired (401: "Signed out — run `claude` (or `codex`) with this account to refresh"), needsAuthorization, error.
- Plugin state (account order, custom labels, last good snapshot) persists via the existing plugin storage mechanism if one exists, else via `leo.secrets` JSON (planner to confirm). It never stores tokens.

## Non-goals (v1)

Token refresh; cookie, web, or PTY scraping fallbacks; cost/token accounting from local JSONL; remote-machine accounts; mapping agents to accounts (row accessories); notifications at thresholds; iOS; publishing the plugin repo.

## Testing

- LeoKit unit tests (TDD): manifest v2 validation (credentials kinds, Meter/Group nodes), Keychain service-name derivation (default dir, custom dir, trailing slash, `~` expansion), credential host binding (match, mismatch on redirect, header-override rejection), grant persistence and removal on uninstall. Keychain and filesystem sit behind injected clients.
- Plugin JS: parser and tone/formatting tests with recorded fixture JSON for both providers (redacted).
- Renderer: snapshot or screenshot of the sidebar section and full view in light and dark, with 3 Claude and 1 Codex fixture accounts.
- Live E2E on this Mac: load the plugin in dev mode in a debug build, add `~/.claude-blackpaw-leo` and `~/.codex`, and confirm real percentages match `claude /usage`. Screenshots are inspected before posting.
