# Account Usage plugin: implementation plan

Spec: `docs/superpowers/specs/2026-11-21-usage-plugin.md`. If this plan and the spec disagree, the spec wins.
Platform: Mac only, as the spec says. iOS has no plugin host, so there is no iOS backlog item.
Mockups (`docs/designs/usage-plugin/`) are not needed to start. They only refine the renderer styling in Step 4 and the tree layout in Step 13. The props are the ones the spec defines.

## Answers to the brief

**(a) Dev mode and Install from URL.** Both work end-to-end today, and neither needs a code change to load `plugins/usage/`.
- "Load local folder…" path: `LeoPluginsSettingsView.swift:64` → `LeoPluginsSettingsModel.loadLocalFolder` → `LeoPluginInstallFlow.stageDev` → approval sheet → `registry.registerDev`.
  - Works in every build type. Debug builds only change the store root, to `~/Library/Application Support/Leo-Debug/Plugins/`.
  - `LeoPluginDevWatcher` reloads on manifest or `main` changes.
  - The app reads `main` itself and sends the source to the sandboxed host (`LeoPluginManager.swift:300`), so the folder can live anywhere.
- Install from URL is wired through `LeoPluginGitInstaller` (resolves the ref to a SHA, shallow fetch, checks HEAD). No live-URL test exists, but this work doesn't need one.
- Minimum to load the plugin: a committed `plugins/usage/dist/main.js`, because Leo runs no build step. The only real blocker is that the v2 manifest is refused until Step 1 lands.

**(b) Plugin state storage.** No plugin key-value store exists. `registry.json` (`LeoPluginStore`) holds app-owned records only.
- Plugin state uses `leo.secrets` JSON (key `state`, 16 KB value cap, service `leo.plugin.studio.blackpaw.usage`).
- That requires `permissions.secrets: true`, but the spec's manifest says `secrets: false`. See Q1.
- Credential grants are app-owned. Per the spec they go in the plugin store, as a new `LeoPluginRecord.credentialGrants` field.

**(c) apiVersion gating.** Today the only gate is `LeoPluginAPI.supported = 1`, checked by `LeoPluginManifestValidator` (pre-decode "too new" check at :37 and the semantic check at :57). The permissions decode rejects unknown keys.
- Raise `supported` to 2.
- Add `credentials` to `LeoPluginPermissions` with a default of `[]`, so v1 manifests decode unchanged.
- The validator refuses a non-empty `credentials` when `apiVersion < 2`, with the reason "requires API version 2".
- Node kinds arrive from JS, not from the manifest. So `Group` and the value-form `Meter` are gated at frame decode: pass the plugin's apiVersion through `JSONDecoder.userInfo` in `Host/LeoPluginWire.swift`.
- `credentials.*` bridge calls are refused for v1 plugins by the permission check.

**Spec vs code conflict on `Meter`.** v1 already has a `Meter` node: segments, `max`, `LeoPluginTone` (`LeoPluginNode.swift:172`).
- The spec's Meter (`value` from 0 to 1, `valueText`, `detail`, tone neutral/success/warning/failure) becomes a second wire form of `"type":"Meter"`, selected by the `value` key.
- It decodes to a new case, `.valueMeter`, allowed in v2 only. Sending both `value` and `segments` is an error.
- The v1 form is unchanged.

**(d) Gesture proof.** The gesture never reaches the host. The router's `LeoPluginCallbackRegistry` keeps each callback's gesture under an unguessable, session-scoped ref, valid once for 30 s.
- The existing follow-up mechanism is reused, extended to direct bridge calls:
  - The prelude sets `activeGestureRef` only while a `callback` handler (or a `command` handler) is running synchronously, cleared in a `finally`.
  - `credentials.add/authorize` send that ref. A call made after an `await` sends null and is rejected with `gestureRequired`, which the plugin docs will state.
- The app runs a new `spendCredentialPrompt(ref)`: gesture present, within 30 s, at most once per record. It does **not** redeem the ref, so the callback's one follow-up action still works.
- Commands carry no gesture today (`LeoPluginBridge.swift:197`). The spec has commands "Add Claude Account…" and "Add Codex Account…", so palette selection must mint a gesture and send an optional `ref` on `.command`. Old plugins ignore the extra field.
- I did not take the explore agent's suggestion to make add a follow-up action: it would break the spec's `Promise<Handle|null>` shape.

**(e) JS tests.** Each plugin package uses Vitest 3.2.4 + TypeScript 5.9.3 + esbuild 0.25.10 on Node 22.
- Layout follows `plugins/status/`: `src/`, `test/*.test.ts`, and `test/stubLeo.ts` as the bridge double.
- CI runs `npm ci`, typecheck, test, build, then `git diff --exit-code` on the bundle (`leo-ci.yml:62-95`).
- `plugins/usage/` copies this pattern. No JSC harness is needed.
- The prelude's own JS is tested through `LeoPluginJSRuntimeTests` (LeoKit).

**(f) Keeping the plugin out of the app bundle.** The "Bundle Leo plugins" phase (`project.pbxproj:588`) runs `macos/scripts/leo-bundle-plugins.sh`, which copies only `macos/Bundled/Plugins/<id>/`. Status's esbuild writes straight into that folder.
- Usage's esbuild `--outfile` is `dist/main.js` inside its own folder.
- Guard 1: the CI job asserts `macos/Bundled/Plugins/studio.blackpaw.usage` does not exist.
- Guard 2: the E2E step checks `Leo.app/Contents/Resources/Plugins/`.

## Toolchain notes

- Mac builds use Xcode 26.3. **26.5 breaks Zig linking**, so set `DEVELOPER_DIR` per `leo-ci.yml:109-116`.
- Build GhosttyKit first: `zig build -Demit-macos-app=false -Dversion-string=<build.zig.zon version>`.
- `.github/scripts/leo/run-unit-tests.sh` (needs `DERIVED_DATA`, `DEVELOPER_DIR`) has no test filter and runs the whole Mac bundle. Wrap it as `heavy …`, in the background, at the integration gate only.
- So keep logic in LeoKit, where `swift test --filter` is fast, and keep Mac code to thin glue.
- LeoKit: `cd Packages/LeoKit && swift test --filter <Suite>`. Lint: `swiftlint lint --strict`.
- JS: `cd plugins/usage && npm ci && npm run typecheck && npm test`.

## Steps

🔒 marks a security-sensitive step. These diffs go to `review.security`.

### 0. 🔒 Spike: Keychain read with no UI (throwaway script in the scratchpad, never committed)
- Confirm which SecItem option makes `SecItemCopyMatching` fail fast with `errSecInteractionNotAllowed` instead of showing the legacy ACL dialog, on an item another app owns ("Claude Code-credentials…"). Candidates:
  - `kSecUseAuthenticationContext` with `LAContext.interactionNotAllowed = true`
  - `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`
  - deprecated `SecKeychainSetUserInteractionAllowed(false)`
- Read only `kSecReturnAttributes`, never data, so no secret is materialized.
- Also confirm the 5 verified service names by listing attributes only.
- Record the result in Step 6's commit message. If no option suppresses the dialog, stop and raise it (R1).

### 1. Manifest v2 (LeoKit)
- Files: `LeoPluginManifest.swift`, `LeoPluginManifestValidator.swift`, `Install/LeoPluginApproval.swift:62`, `Registry/LeoPluginRegistry.swift:154` (`upgradeDiff`).
- `LeoPluginAPI.supported = 2`.
- `enum LeoPluginCredentialKind: String { claudeCode = "claude-code", codex }`, with `boundHost` (`api.anthropic.com` / `chatgpt.com`).
- `LeoPluginPermissions.credentials: [LeoPluginCredentialKind] = []`.
- Validator rules:
  - credentials need v2
  - no unknown kinds
  - no duplicates
  - each kind's bound host must appear exactly (not via wildcard) in `network`
- The approval sheet gets a credentials line. `upgradeDiff` reports added kinds.
- Failing tests first (`LeoPluginManifestTests`, `LeoPluginApprovalReviewTests`, `LeoPluginRegistryTests`):
  - v1 manifest still valid
  - v1 with `credentials` refused, with the reason
  - v2 with unknown kind refused
  - v2 kind without its bound host refused
  - apiVersion 3 refused
  - upgrade that adds `codex` shows in the diff
- Verify: `swift test --filter 'LeoPluginManifestTests|LeoPluginApprovalReviewTests|LeoPluginRegistryTests'`.

### 2. Value-form Meter and Group nodes, gated by apiVersion (LeoKit)
- Files: `LeoPluginNode.swift` (enum, decode/encode at :360-395, `nodeCount`/`depth` at :340), `LeoPluginTreeDiff.swift:130` (`sameKind`), `Slots/LeoPluginPaneSummaryRules.swift:15`, `Slots/LeoPluginSectionRows.swift:37`, `Host/LeoPluginWire.swift` (userInfo apiVersion), `LeoPluginDecodeBudget.swift`.
- `ValueMeter {label ≤40, value (finite, clamped to 0…1), valueText?, detail?, tone: LeoPluginMeterTone(neutral|success|warning|failure)}`.
- `Group {title, subtitle?, sfSymbol? (existing allowlist), accessory: Accessory?, children: [ValueMeter|Accessory], actions: [LeoPluginAction]?}`. Any other child kind is refused.
- Both work as slot roots or array members, and both count toward the existing budget.
- Failing tests first (`LeoPluginNodeDecodingTests`, `LeoPluginTreeDiffTests`, `LeoPluginSectionRowsTests`, `LeoPluginWireTests`):
  - value 1.7 clamps to 1
  - NaN is refused
  - `value` plus `segments` is refused
  - v1 segments Meter is unchanged
  - Group with a List child is refused
  - Group/ValueMeter refused under apiVersion 1, accepted under 2
  - node budget counts Group children
  - same-kind diff does not replace the Group
- Verify: `swift test --filter 'LeoPluginNodeDecodingTests|LeoPluginTreeDiffTests|LeoPluginSectionRowsTests|LeoPluginWireTests'`.

### 3. Meter accessibility and geometry helpers (LeoKit, pure)
- Add `LeoPluginValueMeterPresentation`:
  - fill fraction
  - VoiceOver label "label, valueText, detail" (nil parts skipped)
  - tone → semantic role
- Failing test: `LeoPluginValueMeterPresentationTests`.
- Verify: `swift test --filter LeoPluginValueMeterPresentationTests`.

### 4. Mac renderers (styling; TDD exception noted)
- Files: new `macos/Sources/Features/Leo/Plugins/Render/LeoPluginValueMeterView.swift` and `LeoPluginGroupView.swift`, plus new cases in `Render/LeoPluginNodeView.swift:144-153` and `Render/LeoPluginSummaryRowView.swift:25-28`.
- Meter: thin capsule track with a system dynamic tint. Label leading; `valueText` trailing in monospaced digits; `detail` below in secondary text. Increase Contrast adds a track stroke.
- Group: Group actions go into the context menu and the ⌘↩ panel, the same as List items.
- Model the code on `LeoPluginMeterView`. The layout follows the mockups once they land.
- Verify: Mac Debug build. Visual check happens in Step 15.

### 5. 🔒 Credential grants in the plugin store (LeoKit)
- Files: `Registry/LeoPluginRegistry.swift`, `Registry/LeoPluginStore.swift`, `Manager/LeoPluginManager.swift:199` (uninstall), `Install/LeoPluginUpdater.swift:62`.
- `LeoPluginCredentialGrant {id: UUID string, kind, path: absolute and standardized, no trailing slash}`.
- `LeoPluginRecord.credentialGrants`, decoded with `decodeIfPresent ?? []`.
- Registry operations: add, remove, list.
- `approve` and update narrowing drop grants whose kind is no longer approved.
- `Handle` projection: `{id, kind, label = basename, path ~-abbreviated}`, with home injected. Paths are not secrets; tokens are never stored.
- Failing tests first (`LeoPluginRegistryTests`, `LeoPluginManagerTests`):
  - an old `registry.json` decodes
  - add/list/remove work
  - an update that drops `codex` revokes codex grants
  - uninstall leaves no grants
  - Handle label/path for `~/.claude-blackpaw-leo`
- Verify: `swift test --filter 'LeoPluginRegistryTests|LeoPluginManagerTests'`.

### 6. 🔒 Credential adapters (LeoKit) and Mac Keychain client
- LeoKit file: new `Services/LeoPluginCredentials.swift`.
  - Injected `protocol LeoPluginCredentialKeychain { func password(service: String, allowUI: Bool) throws -> Data }`, with errors `.notFound` and `.needsAuthorization`.
  - Injected file reader with a 64 KB cap.
  - `claudeServiceName(configDir:home:)`: expand `~`, standardize, strip the trailing slash. `<home>/.claude` maps to `Claude Code-credentials`; anything else gets `-` plus the first 8 hex of the sha256 (CryptoKit).
  - Claude: Keychain first, then fall back to `<dir>/.credentials.json`. Read `claudeAiOauth.accessToken`.
  - Codex: `<dir>/auth.json`, reading `tokens.access_token` and `tokens.account_id`.
  - Output: `LeoPluginFetchCredential {boundHost, headers}`. It is internal only and never Codable to the bridge.
  - No write or refresh API exists anywhere on these types.
- Mac file: new `macos/…/Plugins/Manager/LeoPluginSystemCredentialKeychain.swift`, using SecItem with the no-UI option from Step 0 when `allowUI == false`. It is a system boundary, so it is checked by E2E, not unit-tested.
- Failing tests first (`LeoPluginCredentialsTests`):
  - service name for the default dir
  - service name for a custom dir, matching a vector verified on this Mac
  - trailing slash
  - `~` expansion
  - Keychain miss falls back to the file
  - malformed JSON gives `credentialInvalid`
  - `needsAuthorization` is surfaced
  - background calls pass `allowUI: false`
  - Codex reads `account_id`
- Verify: `swift test --filter LeoPluginCredentialsTests`.

### 7. 🔒 Fetch host binding (LeoKit)
- File: `Services/LeoPluginFetcher.swift` (header validation at :184, redirect delegate at :267).
- Add an optional `credential` to the fetch request:
  - Hop 0 with canonical host ≠ `boundHost` → `credentialHostMismatch`.
  - A redirect to any other host fails with `credentialHostMismatch` and is never followed. Credentials are not silently stripped.
  - Plugin headers matching any injected name, case-insensitive (Authorization, ChatGPT-Account-Id, anthropic-beta), → `credentialHeaderConflict`.
  - https only.
  - Errors and OSLog never include header values.
- Failing tests first (`LeoPluginFetcherTests`, existing URLProtocol stub):
  - matching host gets the headers
  - hop-0 mismatch is rejected
  - cross-host redirect is rejected and the second host gets no request
  - same-host redirect keeps the headers
  - plugin `Authorization` with a credential is rejected
  - the token string appears in no error
- Verify: `swift test --filter LeoPluginFetcherTests`.

### 8. 🔒 Bridge API and gesture gate (LeoKit)
- Files: `Runtime/LeoPluginJSPrelude.swift`, `LeoPluginBridge.swift`, `Manager/LeoPluginCallbackRegistry.swift`, `Manager/LeoPluginBridgeRouter.swift`.
- Prelude:
  - `leo.credentials.{add,authorize,list,remove}`.
  - `fetch` init accepts `credential`.
  - `activeGestureRef` is set around the synchronous callback and command handler calls.
- Wire: new requests `credentialsAdd{kind,ref}`, `credentialsAuthorize{id,ref}`, `credentialsList`, `credentialsRemove{id}`. `.command` gains an optional `ref`.
- Registry: add `spendCredentialPrompt`.
- Router:
  - v2 plus the approved-kind gate
  - an injected async `LeoPluginCredentialPicker`
  - add: validate with UI, persist the grant, return the Handle; cancel returns null
  - a grant id from another plugin → `unknownCredential`
  - a background fetch that would need UI → `credentialNeedsAuthorization`, with no UI shown
- Failing tests first (`LeoPluginBridgeTests`, `LeoPluginBridgeRouterTests`, `LeoPluginJSRuntimeTests`):
  - no gesture → `gestureRequired` and the picker is never called
  - ref older than 30 s is rejected
  - a reused ref is rejected
  - a credential prompt still allows the callback's follow-up action
  - a v1 plugin is denied
  - a kind that isn't approved is denied
  - cancel → null
  - add then list
  - a foreign grant id is rejected
  - `add` after an `await` sends a null ref
- Verify: `swift test --filter 'LeoPluginBridgeTests|LeoPluginBridgeRouterTests|LeoPluginJSRuntimeTests'`.

### 9. Mac glue: picker, palette gesture, Settings
- Picker: an NSOpenPanel behind `LeoPluginCredentialPicker`, modelled on `AgentBrowser/LeoBrowserFilePicker.swift:22-67`. Directories only, hidden files shown, starts at `~`.
- Palette: plugin command invocation mints a gesture via `Render/LeoPluginGestureMint.swift`.
- `Manager/LeoPluginSystem.swift`: wire the dependencies.
- Settings:
  - `Settings/Plugins/LeoPluginRow.swift:100` and `LeoPluginsSettingsView.swift:143` list granted accounts under the plugin's permissions, each with a remove button.
  - The model action is `removeGrant`, built on the Step 5 operation.
- Verify: Mac Debug build. The full Mac bundle runs at the gate.

### 10. Plugin scaffold (`plugins/usage/`)
- Files:
  - `leo-plugin.json`: id `studio.blackpaw.usage`, apiVersion 2, network, credentials, `main: dist/main.js`, one sidebar section, commands.
  - `package.json`: esbuild outfile `dist/main.js`.
  - `tsconfig.json`, `vitest.config.ts`, `.nvmrc` (Node 22).
  - `test/stubLeo.ts`: Status's stub plus `credentials`.
- Failing test: `test/manifest.test.ts` (pattern from `plugins/status/test/manifest.test.ts`) checks:
  - apiVersion 2
  - bound hosts in network
  - outfile not under `macos/`
- Verify: `npm ci && npm test`.

### 11. Pure modules: parsers, tone, format (TDD)
- `src/parse/claude.ts`:
  - `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`
  - `utilization` 0–100, `resets_at` ISO
  - null or unknown windows skipped
- `src/parse/codex.ts`:
  - `rate_limit.primary_window` / `secondary_window`
  - `used_percent`, `reset_at` epoch, `limit_window_seconds`
- `src/tone.ts`: below 75 is success, 75 to below 90 is warning, 90 and up is failure.
- `src/format.ts`: "42%", "resets in 2h 14m", "Updated 3m ago", with the clock injected.
- Fixtures: `test/fixtures/{claude,codex}-*.json`, redacted (see Q2).
- Failing tests:
  - full and partial responses
  - empty response → "No usage data"
  - tone boundaries at 74.9, 75, 89.9, 90
  - highest-window selection
- Verify: `npm test`.

### 12. Account state, store, polling
- `src/state.ts` reducer:
  - states: loading (first fetch only), ok, stale (last good values plus "Couldn't refresh"), expired (401 copy from the spec), needsAuthorization, error
  - 429 sets that account's backoff to 15 min
- `src/poller.ts`:
  - sequential queue
  - `leo.timer(300)`, plus on activate and Refresh
- `src/store.ts`:
  - `leo.secrets` key `state`
  - JSON `{order, labels, snapshots}`
  - trims snapshots under 16 KB
  - stores no tokens
- Failing tests:
  - each transition
  - 401 → expired
  - `credentialNeedsAuthorization` → needsAuthorization
  - 429 skips that account until 15 min pass
  - requests never overlap
  - store round-trip and trimming
- Verify: `npm test`.

### 13. Views and wiring
- `src/views.ts`:
  - Sidebar: one Group per account with the highest window's Meter, a worst-tone header Accessory, and "Add Account…".
  - Full view: every window as a Meter. Subtitle is path plus updated time. Actions: Refresh, Rename (Form), Remove, Grant access.
- `src/main.ts`: commands for Show / Add Claude / Add Codex / Refresh.
- Failing tests (`test/plugin.test.ts`):
  - the Add command calls `credentials.add` synchronously
  - Grant access calls `authorize`
  - the tree for 3 Claude + 1 Codex fixtures matches and is written to `test/fixtures/trees/{sidebar,full}.json`
- Build `dist/main.js` and commit it.
- Verify: `npm run typecheck && npm test && npm run build`.

### 14. CI job
- `.github/workflows/leo-ci.yml`: a `plugin-usage` job mirroring `plugin-status` (:62-95). It also runs `test ! -e macos/Bundled/Plugins/studio.blackpaw.usage`.
- Verify: `actionlint` if installed, else a YAML parse.

### 15. Renderer screenshots
- Mac test `macos/Tests/Leo/Plugins/LeoPluginUsageRenderTests.swift`:
  - decodes the Step 13 tree fixtures (path relative to `#filePath`)
  - renders them offscreen in light and dark
  - asserts the fitting size is at least the intrinsic size (no clipping)
  - writes PNGs to `$TMPDIR` for inspection
- Inspect every image before posting.

### 16. Integration gate
- Check load average before heavy runs:
  - full `swift test` (LeoKit)
  - JS suite
  - `heavy run-unit-tests.sh`, in the background
- Reviews:
  - `review.security` on Steps 5–8 and the 🔒 parts of 9
  - `review` on the rest
- Severity bar: fix P0/P1 and anything a real user can hit. Record the rest as accepted risks.

### 17. Live E2E on this Mac
1. Debug build (`heavy xcodebuild … -configuration Debug build`, Xcode 26.3). Confirm `Leo.app/Contents/Resources/Plugins/` has no `studio.blackpaw.usage`.
2. Launch the debug app. Per memory: filter to the scratch agent before any keystroke, and use Peekaboo `--capture-engine cg` for screenshots.
3. Settings → Plugins → Load local folder… → `plugins/usage/`. Approve the sheet; check that it shows the credentials line.
4. Add `~/.claude-blackpaw-leo`: expect the Keychain prompt only at this click. Add `~/.codex`.
5. Compare the percentages against `claude /usage` (`CLAUDE_CONFIG_DIR=~/.claude-blackpaw-leo`) and the Codex `/status`.
6. Relaunch: the next background poll shows no prompt. Remove one account in Settings and confirm it disappears from the plugin.
7. Uninstall: grants and `leo.plugin.studio.blackpaw.usage` items are gone.
8. Screenshots of the sidebar and full view in light and dark, inspected first, then posted via `leo_chat_post` by the orchestrator.

## Risks

- **R1.** Legacy keychain ACLs may ignore the no-UI flag (Step 0). If they do, background reads can't work without a dialog and the `needsAuthorization` flow needs rethinking. That would be raised, not patched around.
- **R2.** "Always Allow" is tied to the code signature, so each new debug signature prompts again. Expect repeat prompts during development.
- **R3.** The Claude service-name hash uses the path as Claude Code saw it. Symlinked or relative `CLAUDE_CONFIG_DIR` values may not match, which shows up as `credentialInvalid` at add time. The paths are not resolved.
- **R4.** Both usage endpoints are undocumented. If their shape drifts, the plugin falls back to "No usage data" and does not crash.
- **R5.** A prompt-spending ref that is valid once for 30 s still lets a plugin open one picker per user click. This is accepted by design.

## Open questions

- **Q1.** State storage needs `secrets: true`, which conflicts with the spec's manifest (`secrets: false`). Recommendation: set it to true; no `leo.storage` gets added (that would be beyond the spec).
- **Q2.** Real fixtures need a live API response, but curl with a token is blocked as credential materialization. Recommendation: start with hand-written fixtures matching the spec fields, then replace them with redacted captures that Evan makes via a supplied `!` command, or confirm the shape in E2E.
- **Q3.** Sidebar sections have no header accessory or standalone button today. Default plan: the worst-tone Accessory is the first root element, and "Add Account…" is in every Group's actions plus an EmptyState when there are no accounts. Change this if the mockups show otherwise.

## Orchestrator decisions (2026-11-21)

- **Q1:** `secrets: true`, with state stored as `leo.secrets` JSON. Spec updated.
- **Q2:** Start from hand-written fixtures matching the spec fields; live E2E confirms the shape. No token curl.
- **Q3:** Planner default stands unless `docs/designs/usage-plugin/design.md` says otherwise. If it does, the design wins on layout, and the spec still wins on props.
- **Execution split:** Lane A (platform, Steps 0–9, this worktree) and Lane B (plugin JS, Steps 10–14, a separate worktree merged locally into `usage-plugin`) run in parallel. Steps 15–17 run after both land.
- **E2E constraint:** the Claude Keychain "Always Allow" prompt needs a human click. Overnight E2E covers Codex plus screenshots only; the Claude-account E2E waits for Evan.
