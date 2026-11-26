# Plan: plugin API key credentials

Spec: `docs/superpowers/specs/2026-11-25-plugin-api-key-credentials.md`. The spec wins if the two conflict. Planner run: d-35f17778a760. Mac only.

## Contract
**Manifest** (apiVersion 2): `permissions.credentials` mixes string kinds and `api-key` objects.

```json
"network": ["api.deepseek.com"],
"credentials": ["claude-code", {"kind":"api-key","provider":"deepseek","label":"DeepSeek","host":"api.deepseek.com"}]
```

- The object form is only allowed for `api-key`. Object keys are exactly `kind`, `provider`, `label` and `host`.
- `provider` matches `^[a-z0-9][a-z0-9-]{0,31}$` and is unique within the plugin.
- `label` is 1–40 characters with no control characters.
- `host` is a lowercase hostname: no scheme, port, path, wildcard or IP literal. It must appear exactly in `network`.
- Bare `"api-key"`, unknown keys and apiVersion 1 are all rejected.

**JS:** `leo.credentials.add("api-key", {provider})` returns a `Handle`, or `null` if the user cancels. It is gesture-only. `provider` is required for `api-key` and forbidden for other kinds.
- The handle is `{id, kind:"api-key", provider, name}`. Account handles are unchanged.

**Fetch:** `leo.fetch(url, {credential: handle.id})`, using the existing id-string contract.

**Grant JSON:** `{id, kind:"api-key", provider, name, machine:"local"}`. Account grants encode byte-for-byte as they do today.

**Keychain:** a generic password with service `Leo Plugin API Key` and account `<pluginID>/<grantID>`.

**Reasons:**
- `gestureRequired`
- `credentialPermissionDenied`: unknown or unapproved provider
- `unknownCredential`
- `credentialInvalid`: missing item, or a bad stored key
- `credentialNeedsAuthorization`: a read would need Keychain UI. Call `authorize` from a click.
- `credentialHostMismatch`: checked on the first hop and on every redirect
- `credentialHeaderConflict`: the caller set `authorization`, in any case

The existing denials all still run first.

## Design
- **Permissions:** `permissions.credentials: [Kind]` stays as it is. Add `permissions.apiKeys: [LeoPluginAPIKeyProvider]`. Both decode from and encode to the single `credentials` array.
- **Grant:** `subject: .account(kind, path) | .apiKey(provider, name)`, with custom Codable keyed on `kind`.
- **Bound host:** always taken from the record's *approved* permissions.
- **Vault:** a new LeoKit `Plugins/Services/LeoPluginAPIKeyVault.swift`.
  - It's injected with `reader: LeoPluginCredentialKeychain` (allowUI flag) and `writer: LeoPluginKeychain`. Tests use the existing fakes. Only `LeoPluginSystem.swift:56-64` passes the real Keychain.
  - API:
    - `normalize`: trim, then require non-empty printable ASCII, ≤512 bytes and no whitespace
    - `save`
    - `credential(pluginID:grantID:host:allowUI:)`
    - `delete`
    - `deleteAll`
- **Key in memory:** `LeoPluginAPIKeyEntry{key,name}` has a redacted description and mirror. It is never stored past `vault.save`.
- **Uninstall:** delete the item for each API-key grant on the record, then sweep orphans with a new `LeoPluginKeychain.deleteAll(service:accountPrefix:"<pluginID>/")`. Both run *before* the record is removed, so a failed delete can be retried.

## Leoterm
LeoKit steps verify with `cd Packages/LeoKit && swift test --filter LeoPlugin`.

- **L1 Manifest/validator/approval/diff**
  - Files: `LeoPluginManifest(+APIKeyProvider)`, `LeoPluginManifestValidator.swift:176-195`, `LeoPluginPermissionEngine` (`check(apiKeyProvider:)`), `Install/LeoPluginApproval.swift:89`.
  - Diff: a new provider *or a changed host/label* counts as added, which forces re-approval.
  - Approval line: "API keys: <label>, sent only to <host> (you paste it; it stays in Leo)".
  - Tests: `LeoPluginManifestCredentialsTests`.
- **L2 Vault** plus `deleteAll` on every keychain fake.
  - Tests: `LeoPluginAPIKeyVaultTests`: normalize rules, save/read, missing → invalid, UI → needsAuthorization, `Bearer` header bound to host, the prefix sweep only touches this plugin, no key bytes in the description.
- **L3 Grant subject/registry/store**
  - Files: `LeoPluginCredentialGrant`, `LeoPluginRegistry.swift:124-130,184-186`, `LeoPluginCredentialServices`, `LeoPluginRemoteCredentialFetcher`, `LeoPluginCredentials`. The account resolver ignores api-key grants.
  - `addAPIKeyGrant`. `approve()` and reinstall drop grants whose provider was removed or whose host changed.
  - Tests: `LeoPluginCredentialGrantTests`.
- **L4 Bridge/router/prelude/fetch** (after L1–L3)
  - Files: `LeoPluginBridge.swift:47,98,171`, `LeoPluginJSPrelude.swift:166-170`, `LeoPluginBridgeRouter(+Credentials)`.
  - Picker: `pickAPIKey(provider, pluginName) async -> LeoPluginAPIKeyEntry?`.
  - Add flow: check the approved provider → spend the gesture → picker → normalize → new id → `vault.save` → `addAPIKeyGrant` (on failure, `vault.delete`) → handle.
  - Remove: delete the grant, then the item.
  - Authorize reads with allowUI.
  - Fetch uses `boundHost = approved.host` and reads the key only after a rate-limit permit.
  - Tests in BridgeRouterCredentials, Fetcher and JSRuntime: handle shape, vault account format, no key bytes in the registry, cancel → null, no gesture, unknown provider, Bearer header, host mismatch on the first hop and on a redirect, `AUTHORIZATION` conflict, missing item, prelude option validation.
- **L5 Manager cleanup** in `LeoPluginManager.swift:189-245`: remove, dropped grants and uninstall all delete items. Tests in `LeoPluginManagerTests` check that the items are gone and that other plugins' items survive.
- **M1 Sheet:** new `macos/.../Plugins/Manager/LeoPluginAPIKeySheet.swift` and `LeoPluginAPIKeySheetModel`, presented by `LeoPluginCredentialPicker` through `LeoPluginSheetPresenter`.
  - Contents: copy per the spec, a `SecureField`, a name field (default label, ≤64 characters), Add/Cancel.
  - Tests: `LeoPluginAPIKeySheetModelTests`, plus one screenshot.
- **M2 Settings:** `LeoPluginRow.swift:51-54,88,145`. Rows read `API key · <name> · <host>`; the summary reads `API keys: DeepSeek`. Tests: `LeoPluginsSettingsModelTests`.
- **M3 Wiring:** `LeoPluginSystem.swift:56-64` and `LeoPluginSystemKeychain.deleteAll`. Confirm the items are not synchronizable.
- **D1 SDK:** `plugins/sdk/leo.d.ts` and the README: the handle union, `add(kind, options?)`, the reasons.

macOS tests run under `heavy`: `TEST_RUNNER_LEO_HOST_TESTS=1 xcodebuild test … -only-testing:GhosttyTests/<Suite>` (`macos/Tests/README.md:29-31`).

## Plugin (leo-plugin-usage)
Verify with `npm run typecheck && npm test && npm run build`, and commit `dist/`.

- **P1** `src/parse/deepseek.ts`: `parseDeepSeekBalance` takes string or number values, skips bad entries, and handles several currencies.
- **P2** `src/balance.ts`: `formatBalance` (`$12.40 left`, `¥…`, unknown currencies as `12.40 XYZ left`, joined with " · ") and `toneForBalance`.
  - Red, labelled "Out of credit", when `!isAvailable`.
  - Orange when *any* of USD <5 or CNY <35.
  - Neutral otherwise.
- **P3** `src/state.ts`: `balance?`. A failure keeps the last balance as stale. A 401 shows "Key rejected · remove and add it again".
- **P4** `src/api.ts`: the handle union and `add(kind, options?)`. Re-vendor `sdk/leo.d.ts`. The poller keys providers by `api-key:deepseek`.
- **P5** `src/views.ts`:
  - Sidebar: icon, name, then the balance line with no meter.
  - Full view: the total, then "granted … · topped up …".
  - The header skips balance accounts.
  - Use an allowlisted symbol.
- **P6** `leo-plugin.json`: the host, the credential object, and an `add-deepseek` command, "Add DeepSeek Key…". In `src/plugin.ts`, `add` stays the first call before any await.

## Order
Leoterm runs as one implementer: L1–L5, then M1–M3 and D1. The plugin runs in parallel against this contract. Then `review.security` on both diffs, the full LeoKit suite and the targeted macOS suites. Release Leo first, then the plugin. Last, a live check against platform.deepseek.com.

## Orchestrator decisions
1. Q1: fetch takes the handle id. This is the existing contract; the spec's `{credential: handle}` was shorthand.
2. Q2: a changed host revokes the grant and deletes the key.
3. Q3: several keys per provider are allowed, with no dedupe.
4. Q4: names are ≤64 characters with no control characters.
5. Q5: there is no minimum-host field. The plugin release is ordered after the Leo release, because an older Leo will refuse the new manifest.
6. Q6: orange if any currency is under its threshold; other currencies stay neutral.
7. Q7: the field names (`is_available`, `balance_infos[].currency/total_balance/granted_balance/topped_up_balance`) are confirmed against api-docs.deepseek.com/api/get-user-balance.
8. Downgrade risk accepted: an older Leo fails on an api-key grant. Leo updates through Sparkle.
