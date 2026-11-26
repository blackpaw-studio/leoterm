# Plugin API key credentials

Status: draft, awaiting Evan's approval.
Platform: **Mac only.** iOS has no plugin host.

## Goal

A plugin can ask the user to paste an API key for a service the plugin's manifest names. Leo keeps the key in the Keychain and adds it to requests for that service's host. The plugin never sees the key.

The first user is the Usage plugin's DeepSeek balance row. The feature is generic: OpenRouter, Moonshot and similar services can use it later with no Leo change.

## Manifest

A new credential kind, `api-key`, declared per provider:

```json
"credentials": [
  { "kind": "api-key", "provider": "deepseek", "label": "DeepSeek", "host": "api.deepseek.com" }
]
```

- `provider`: a lowercase slug, unique within the plugin.
- `host`: a single exact hostname. HTTPS only. No wildcards and no IP literals.
- The host must also be in the manifest's network allowlist, or the manifest is rejected.
- The existing `claude-code` and `codex` kinds are unchanged.

## Adding a key: `leo.credentials.add("api-key", {provider})`

- Gesture-only, like today's add.
- Leo shows a sheet that says "<Plugin> wants an API key for <label>. It will only be sent to <host>." It has a secure text field, an optional account name (defaults to the label), and Add / Cancel.
- Leo trims the key. It must be non-empty, ASCII, ≤ 512 bytes, and contain no whitespace.
- Leo stores the key in the login Keychain as a generic password: service `Leo Plugin API Key`, account `<pluginID>/<grantID>`.
- The grant stores `{id, kind: "api-key", provider, name, machine: local}`. The grant never holds the key itself.
- The JS handle is `{id, kind: "api-key", provider, name}`.
- Leo does not validate the key against the service. The plugin's first fetch does that, and a 401 shows as a bad key in the plugin.

## Fetching

- `leo.fetch(url, {credential: handle})`. The URL host must equal the provider's `host`. Every redirect hop must stay on that host, or the fetch fails with `credentialHostMismatch`.
- Leo adds `Authorization: Bearer <key>`. If the caller already set `authorization` (compared case-insensitively), the fetch fails with `credentialHeaderConflict`.
- All existing checks still run first: manifest network allowlist, header rules, rate limit and in-flight cap.
- A missing Keychain item fails with `credentialInvalid`.

## Removing and listing

- Settings → Plugins → account rows show `API key · <name> · <host>`.
- Removing a grant deletes its Keychain item.
- Uninstalling the plugin deletes all of that plugin's API key items.
- Leo never shows a key again after it's added. To change a key, remove the grant and add it again.

## Usage plugin (leo-plugin-usage)

- New command: **Add DeepSeek Key…**, which calls `credentials.add("api-key", {provider: "deepseek"})`.
- It polls `GET https://api.deepseek.com/user/balance` using the same refresh and backoff rules as the other accounts.
- It parses `is_available` and `balance_infos[]` (`currency`, `total_balance`, `granted_balance`, `topped_up_balance`). Numbers may come as strings; parse them defensively.
- **Sidebar:** the account's icon and name, then one line: `$12.40 left` (or `¥…`), with no bar. If there are several currencies, show each, joined with " · ".
- **Tone:**
  - Red, labelled "Out of credit", when `is_available` is false.
  - Orange when the USD total is below $5, or the CNY total is below ¥35.
  - Neutral otherwise.
- **Full view:** the total, plus granted and topped-up on a second line.
- A 401 shows "Key rejected · remove and add it again".
- The pane header's highest-% summary ignores balance accounts.
- Not included: spend history and daily snapshots.

## Security

- The key leaves the Mac only in the Authorization header to the declared host.
- It never appears in JS, logs, errors or Settings.
- A plugin can name any host for its key. The sheet shows that host, and the user decides whether to paste.
- This is security-sensitive, so it goes to `review.security`.

## Testing

- **LeoKit (test first):**
  - manifest validation: host format, host must be in the network allowlist, unknown fields
  - grant encoding: no key bytes in the grant
  - fetch: bound host on the first hop and on redirects, header conflict, the Authorization header is injected, a missing Keychain item gives `credentialInvalid`
  - remove and uninstall delete the Keychain items
- **Mac:** a model test for the sheet, plus one screenshot.
- **Plugin:** the balance parser (strings or numbers, several currencies, missing fields), each tone threshold, the 401 copy, and the header ignoring balance accounts.
- **Live:** paste a real DeepSeek key and confirm the balance matches platform.deepseek.com.
