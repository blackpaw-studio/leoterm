# Leo Plugin Platform: Implementation Plan

Spec: `docs/superpowers/specs/2026-11-10-plugin-platform.md` (source of truth) · Consumer check: `docs/superpowers/specs/2026-11-10-github-plugin.md`
Platform call: **Mac only.** The LeoKit `Plugins` code stays platform-neutral (Foundation and JavaScriptCore only) so an iOS host can reuse it. iOS plugins go to the backlog as an idea (M6.4).

## Conventions

- LeoKit code: `Packages/LeoKit/Sources/LeoKit/Plugins/`. Tests: `Packages/LeoKit/Tests/LeoKitTests/Plugins/`. LeoKit is a single target, so "module" here means a folder. Every app file that uses it needs its own `import LeoKit` (MemberImportVisibility).
- Mac app code: `macos/Sources/Features/Leo/Plugins/{Host,Manager,Install,Render,Slots,Settings}/`. App tests: `macos/Tests/Leo/Plugins/`.
- Swift Testing. A suite trait that is only a `SuiteTrait` crashes the test host, so every custom trait also conforms to `TestTrait`.
- LeoKit test command: `swift test --package-path Packages/LeoKit --filter <Suite>`
- App build (run from `macos/`, as a background command): `heavy xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -packageAuthorizationProvider netrc`
- App test command: `xcodebuild test-without-building … -only-testing:GhosttyTests/<Suite>` (same flags as the build).
- Toolchain: Xcode 26.3. No Zig changes and no daemon changes.
- Every step starts from a failing test unless it says "TDD exception". Each step commits on its own.

---

## M0: Spike (gates M2; run alongside M1)

**0.1 Per-plugin XPC process and sandboxed JSC proof.** This is throwaway code on a spike branch and is not merged.
- An app-embedded XPC service (`ServiceType = Application`) normally gives **one process per app**, shared by every connection to it. The spec needs **one process per plugin**.
- Prove the following:
  - (a) Info.plist `XPCService._MultipleInstances = true` plus a unique instance per `NSXPCConnection` gives separate PIDs. WebKit uses this key, but it is undocumented.
  - (b) A `JSContext` runs inside the sandboxed service with hardened runtime on and **without** `com.apple.security.cs.allow-jit`, falling back to the LLInt interpreter.
  - (c) `NSXPCConnection.processIdentifier` plus `proc_pid_rusage(RUSAGE_INFO_V4)` returns CPU time and `ri_phys_footprint` for that PID, and `kill(pid, SIGKILL)` triggers the connection's interruption handler.
- Output: a decision note committed as `docs/plans/2026-11-10-plugin-platform-spike.md`, covering PIDs per plugin, the JIT result, and the watchdog reads.
- Fallback if (a) fails: a sandboxed helper executable in `Contents/Helpers/`, started by `posix_spawn` and talking over a `socketpair` with length-prefixed JSON. The spec says "XPC service", so this fallback needs Evan's OK. See open question Q1.
- Verify: one ad-hoc-signed (`CODE_SIGN_IDENTITY=-`) build with 2 plugins shows 2 PIDs in `ps`. `codesign -d --entitlements -` on the service shows `app-sandbox` only.

---

## M1: LeoKit models, permission engine, bridge protocol (pure, `swift test`)

**1.1 Manifest model and validation**: `LeoPluginManifest.swift`, `LeoPluginManifestValidator.swift`
- Codable model for `id`, `name`, `version`, `apiVersion`, `main`, `permissions{network, secrets, agents}`, and `contributes{views, rowAccessories, commands, sidebarSections}`.
- Strict decoding: unknown keys at any level, unknown permissions, or `apiVersion > LeoPluginAPI.supported (1)` produce `.refused(reason)` with a readable reason.
- Other checks:
  - reverse-DNS `id`
  - semver `version`
  - `main` is relative, has no `..`, and is not absolute
  - contribution ids are unique per kind and match `[a-z0-9-]{1,40}`
  - SF Symbol names are non-empty
- Test: `LeoPluginManifestTests` covers a good manifest, each bad field, a future `apiVersion`, an unknown key, and `main` escape attempts.

**1.2 Host patterns and permission engine**: `LeoPluginHostPattern.swift`, `LeoPluginPermissionEngine.swift`
- Host matching:
  - An exact host matches case-insensitively, after removing a trailing dot.
  - `*.suffix` matches strict subdomains only, not the bare suffix.
  - URLs with userinfo are rejected.
  - Fetch is https only (Q8).
- `check(url:hop:)` runs once per redirect hop.
- Agent permission gates: `read` for `agents.list`, `send` for `sendToAgent`, `spawn` for `spawnAgent`.
- `LeoPluginPermissionDiff(old,new)` lists only increases: added hosts, `secrets` turned on, added agent verbs.
- Test: `LeoPluginPermissionEngineTests` covers wildcards, apex rejection, mixed case, a redirect chain where hop 2 leaves the allowlist, and the diff.

**1.3 Rate limiter**: `LeoPluginRateLimiter.swift`
- Sliding window of 60 requests per minute and at most 4 in flight. The clock is injected.
- Test: `LeoPluginRateLimiterTests` with a fake clock checks that request 61 is rejected, request 5 waits or is rejected while 4 are in flight, and a slot frees after completion.

**1.4 Component tree and restricted Markdown**: `LeoPluginNode.swift`, `LeoPluginMarkdown.swift`
- Codable `indirect enum` for `List`, `Detail`, `Form`, `Accessory`, `EmptyState`, `Loading`, `Error`.
  - `List`: sections with items. Each item has a required `id`, `title`, `subtitle`, `sfSymbol`, `accessories`, and `actions`.
  - `EmptyState`: `{title, message?, sfSymbol?, actions?}`.
  - `Error`: `{message, retry: callback}`.
  - Form fields: `text`, `textArea`, `picker`, `checkbox`, and `submit`, each with an id.
- Limits:
  - depth 8 and 2,000 nodes
  - `Accessory`: text ≤ 8 characters, `color ∈ {neutral, success, warning, failure, running}`
- A Markdown subset (headings, emphasis, code, links, lists) parses to a platform-neutral AST. Links must be https. HTML and images are dropped as plain text.
- The root's shape (one node or a stack) is open question Q5.
- Tests: `LeoPluginNodeDecodingTests` and `LeoPluginMarkdownTests` decode each component, reject unknown types, and enforce the limits and the link scheme.

**1.5 Tree diff**: `LeoPluginTreeDiff.swift`
- Keyed by item id, so the renderer keeps selection and scroll and updates rows in place.
- Test: `LeoPluginTreeDiffTests` covers insert, delete, move, update, and a whole-tree replacement when the type changes.

**1.6 Actions and gate**: `LeoPluginAction.swift`, `LeoPluginActionGate.swift`
- Actions: `callback(id,payload)`, `pushView(node)`, `openURL` (https only), `copy`, `sendToAgent(agent,text)`, `spawnAgent{repo,branch,base?,prompt,machine?}`.
- `agent` is `{machine, name}` for top-level agents only (Q16).
- The gate accepts send and spawn only with a `LeoPluginGesture` token, which only the renderer's click and keyboard paths can mint, plus the matching manifest permission.
- Test: `LeoPluginActionGateTests` checks that send and spawn without a gesture are refused, that a missing permission is refused, and that `openURL http:` is refused.

**1.7 Bridge protocol and slot ids**: `LeoPluginBridge.swift`, `LeoPluginSlotID.swift`
- Host → app (`LeoPluginHostRequest`, Codable): `render(slot, node)`, `fetch(id, url, init)`, `secretsGet/Set/Delete`, `agentsList`, `timerStart(id, sec≥60)`, `timerStop`, `log`.
- App → host (`LeoPluginEvent`): `activate`, `agentsChanged`, `viewOpened(agent, slot)`, `command(id, slot?)`, `callback(id, payload, gesture?)`, `timerFired`, plus replies.
- The protocol has **no** send or spawn request case.
- `LeoPluginSlotID`: `view(viewID, agent)`, `accessory(id, agent)`, `section(id)`, `palette(commandID)`. The event payload carries the slot, so plugin code never builds one itself (Q3).
- Test: `LeoPluginBridgeTests` covers round-trip coding, and a raw `{"call":"sendToAgent"}` message decoding to `.unsupported`.

---

## M2: XPC JSC host and bridge (depends on M0, 1.7)

**2.1 JS runtime (in LeoKit, testable in-process)**: `Plugins/Runtime/LeoPluginJSRuntime.swift`
- `import JavaScriptCore`. Builds a `JSContext` exposing only the `leo` object:
  - `render`
  - `on`
  - `fetch` (returns a Promise)
  - `secrets.get/set/delete`
  - `agents.list`
  - `timer`
- `sendToAgent` and `spawnAgent` exist only as action constructors in the SDK and return plain JSON.
- Requests go out through an injected `send(LeoPluginHostRequest)`. Promises resolve when replies arrive.
- The runtime asserts that no `fetch`, `XMLHttpRequest`, `require`, or `process` globals exist.
- Test: `LeoPluginJSRuntimeTests` with inline JS strings covers:
  - `render` reaching the sink
  - `fetch` resolving and rejecting with a reason
  - `on('callback')` delivery
  - an uncaught exception reported as a handler error
  - no forbidden globals

**2.2 XPC service target.** TDD exception: project configuration. Verified by build and codesign.
- New folder `macos/LeoPluginHost/` with `main.swift`, `LeoPluginHostService.swift`, `Info.plist`, and `LeoPluginHost.entitlements`.
- Add it to `Ghostty.xcodeproj` as its own `PBXFileSystemSynchronizedRootGroup`. Do **not** put it under `Sources/`: that synced group compiles into the app.
- Target settings:
  - product type `com.apple.product-type.xpc-service`, named `LeoPluginHost`
  - bundle id `$(LEO_APP_BUNDLE_ID).pluginhost`, so the debug and release ids stay distinct
  - links the LeoKit package product
  - `ENABLE_HARDENED_RUNTIME=YES`, the same team, and automatic signing
- Entitlements: `com.apple.security.app-sandbox = true` and **nothing else**: no network client, no file access, no allow-jit (Q2).
- Info.plist: `XPCService { ServiceType = Application; _MultipleInstances = true }`, following M0.
- App target:
  - a target dependency on the service
  - a Copy Files phase "Embed XPC Services" (`dstSubfolderSpec = 16`, path `$(CONTENTS_FOLDER_PATH)/XPCServices`, CodeSignOnCopy)
- Release workflows (`.github/workflows/release-tag.yml` around line 229, and `release-tip.yml`): add `codesign -f -s "$MACOS_CERTIFICATE_NAME" -o runtime --entitlements macos/LeoPluginHost/LeoPluginHost.entitlements …/Contents/XPCServices/LeoPluginHost.xpc` before the app's own signing step, next to the Sparkle lines.
- Verify:
  - The app build succeeds.
  - `Ghostty.app/Contents/XPCServices/LeoPluginHost.xpc` exists.
  - On an ad-hoc signed build, `codesign -d --entitlements - <xpc>` shows sandbox only.

**2.3 XPC glue**: `LeoPluginHostProtocol` (in LeoKit, `@objc` with JSON `Data` payloads), `macos/LeoPluginHost/LeoPluginHostService.swift`, and `Plugins/Host/LeoPluginHostConnection.swift` in the app.
- The app sends `load(source: Data, manifest: Data)`. **The app reads the JS bundle and sends its bytes**, because the sandboxed host cannot read Application Support.
- The service builds a `LeoPluginJSRuntime` per connection.
- Two-way traffic: `deliver(event)` from the app to the host, and `request(...)` from the host to the app through the exported object.
- Test: `LeoPluginHostConnectionTests` (app-hosted, real XPC) loads a minimal fixture JS and gets `render` back after `activate`.

**2.4 Watchdog**: `Plugins/Host/LeoPluginWatchdog.swift`
- While any handler is in flight, poll `proc_pid_rusage` every 250 ms. If CPU time used since the handler started exceeds 2 s, send SIGKILL.
- Check `phys_footprint` every 1 s. Above 256 MB, send SIGKILL.
- Every kill reports `.crash(reason)`.
- The rusage reader and clock are injected. JSC's private execution-time-limit API is not used.
- Test: `LeoPluginWatchdogTests` with a fake reader covers 1.9 s (ok), 2.1 s (kill), wall time with no CPU (no kill), and 257 MB (kill).

**2.5 Crash supervisor (LeoKit)**: `LeoPluginSupervisor.swift`
- Pure state machine: restart after 1 s, then 5 s, then 30 s. A third crash within 5 minutes moves to `.disabled(reason)`. The clock is injected.
- Test: `LeoPluginSupervisorTests` covers the backoff sequence, the window rolling over, and disabling.

**2.6 Host integration tests** (app-hosted): `LeoPluginHostIntegrationTests` with fixtures in `macos/Tests/Fixtures/Plugins/{echo,spin,leak}/`.
- Cases:
  - bridge round-trip
  - an infinite loop killed by the watchdog and counted as a crash
  - an external SIGKILL causing a restart after 1 s
  - three crashes leading to disabled
- The test runs with time scaled through the injected clock, so it has no real sleeps beyond the process restart.
- Note: `CODE_SIGNING_ALLOWED=NO` builds don't enforce the sandbox. Sandbox enforcement is checked by the signed-build step in 2.2.

---

## M3: Manager, install, dev mode (depends on M1 and 2.3; 3.2, 3.3 and 3.5 can start alongside M2)

**3.1 Registry**
- LeoKit `LeoPluginRegistry.swift`: a pure model. Each entry holds:
  - `id`, `source` (`bundled`, `git(url, ref, sha)`, or `dev(path)`)
  - `enabled`, `approvedPermissions`, `hiddenSections`, `disabledReason`
- App `LeoPluginStore.swift`: JSON persisted at `<root>/registry.json`, with `root` injected. The default is `~/Library/Application Support/Leo/Plugins/` (Q15 covers the debug app).
- Test: `LeoPluginRegistryTests` covers enable and disable, an approval that stores permissions, and the upgrade diff requiring re-approval.

**3.2 Discovery and bundled plugins**: `Plugins/Manager/LeoPluginDiscovery.swift`
- Scans three places:
  - `Bundle.main.resourceURL/Plugins/*`
  - `<root>/<id>/<sha>/`
  - registered dev folders
- Bundled plugins are enabled and pre-approved for the permissions they ship with. A higher permission after an app update gets the diff sheet (Q11).
- Build phase: a "Bundle Leo plugins" script (`macos/scripts/leo-bundle-plugins.sh`) copies every `macos/Bundled/Plugins/<id>/` that has a `leo-plugin.json` into `$UNLOCALIZED_RESOURCES_FOLDER_PATH/Plugins/`.
- v1 ships the folder with only `.gitkeep`. The GitHub plan adds its built bundle there.
- Test: `LeoPluginDiscoveryTests` with temp dirs: an invalid manifest is listed as refused with its reason, and a duplicate id across sources resolves dev → installed → bundled.

**3.3 Git installer**: `Plugins/Install/LeoPluginGitInstaller.swift`, using the existing `LeoProcessRunner` (injected).
- Accept `https://` URLs only (Q12 covers ssh).
- Resolve the ref:
  - A 40-hex SHA is used as is.
  - Otherwise run `git ls-remote <url> <ref>`.
- Clone into `<root>/.staging/<uuid>` with:
  - `GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null -c protocol.allow=never -c protocol.https.allow=always`
  - `init` + `fetch --depth 1 origin <sha>` + `checkout FETCH_HEAD`
  - no submodules
- Then:
  1. Verify `HEAD == sha`.
  2. Validate the manifest.
  3. Resolve `main` with symlinks resolved. It must be a regular file inside the folder and ≤ 10 MB (Q19).
  4. Remove `.git` and move the folder to `<id>/<sha>/`.
- Nothing is enabled until approval (3.4).
- If `/usr/bin/git` is missing (CLT not installed), report a clear error (Q12).
- Tests: `LeoPluginGitInstallerTests` with a fake runner covers argument shape, SHA mismatch, a symlinked `main` escaping, and staging cleanup on failure. One real-git test uses a local bare repo, with `file` allowed through injected config.

**3.4 Approval and updates**: `Plugins/Install/LeoPluginApprovalSheet.swift`, `LeoPluginUpdater.swift`
- The sheet shows the plugin name, id, SHA, and permissions. On an update it shows the diff from 1.2.
- "Check for updates" runs `ls-remote` on the stored ref. A new SHA is staged and validated, and is re-approved only if permissions increased. The old SHA folder is removed after the swap.
- Test: `LeoPluginUpdaterTests` covers same SHA (no-op), new SHA with equal permissions (swaps without a sheet), and new SHA with added permissions (sheet required, nothing swapped before approval). The sheet itself is a TDD exception (UI).

**3.5 Bridge services**: `Plugins/Manager/LeoPluginFetcher.swift`, `LeoPluginSecrets.swift`, `LeoPluginAgentsSnapshot.swift`, `LeoPluginTimers.swift`
- Fetcher:
  - an ephemeral `URLSession` with no cookies or cache
  - the delegate's `willPerformHTTPRedirection` re-runs the engine on every hop
  - the body is streamed and capped at 5 MB
  - goes through the rate limiter
  - passes headers through, so ETags and 304 work
  - errors become rejected promises with a reason and are logged under the OSLog subsystem's `leo.plugins` category
- Secrets: generic-password Keychain item with service `leo.plugin.<id>` and account `<key>`, so ids and keys can never collide. Uninstall matches the service exactly. The key must match `[A-Za-z0-9._-]{1,64}`. The Keychain is behind a protocol for tests.
- Agents snapshot: builds `{name, machine, status, repo, branch, hasWorktree}` from the sidebar feeds across machines. No worktree path is exposed. Requires `agents:read`.
- Timers: interval ≥ 60 s, stopped when the host stops.
- Tests:
  - `LeoPluginFetcherTests` uses `URLProtocol` stubs: a disallowed redirect hop is rejected, a 5 MB + 1 body is rejected, the rate limit applies, and a 304 passes through.
  - `LeoPluginSecretsTests` checks the namespace and key validation.
  - `LeoPluginAgentsSnapshotTests` checks there is no path field and that `read` is required.

**3.6 Manager, router, slot store**: `Plugins/Manager/LeoPluginManager.swift`, `LeoPluginBridgeRouter.swift`, `LeoPluginSlotStore.swift`
- The manager owns a host connection and supervisor per enabled plugin.
- The router validates each request against the manifest, then calls the matching 3.5 service.
- The slot store is `@MainActor`, `ObservableObject`, keyed by `LeoPluginSlotID`. States are `loading`, `tree`, `error(retry)`, and `disabled(reason)`.
- Events:
  - `activate` on launch and enable
  - `agentsChanged` from the sidebar feeds, debounced
  - `viewOpened` and `command` from slots
- Retry on an `Error` slot re-sends the event that produced it, or restarts a disabled host after the user re-enables it.
- Test: `LeoPluginManagerTests` with a fake connection covers:
  - every slot starts as `loading`
  - a render produces a tree
  - a crash shows the error state in every slot of that plugin
  - disabled shows the notice
  - a render for an undeclared contribution id is refused

**3.7 Action executor and confirmation sheet**: `Plugins/Manager/LeoPluginActionExecutor.swift`, `Plugins/Slots/LeoPluginConfirmSheet.swift`
- `sendToAgent` opens a sheet with the target agent and machine, editable text, and the plugin name. On confirm it calls `client(for: host).message(name, text:)`.
- `spawnAgent` opens a sheet with editable repo, branch, base, prompt, and a machine picker defaulting to Leo's default. On confirm it calls `spawn(LeoSpawnRequest(...), host:)`.
- Tests: `LeoPluginActionExecutorTests` with a fake daemon client checks:
  - no daemon call happens before confirm
  - the edited text and fields are what is sent
  - cancel sends nothing
  - a missing gesture or permission is refused
- The sheet layout is a TDD exception (UI).

**3.8 Dev mode**: `Plugins/Install/LeoPluginDevWatcher.swift`
- "Load local folder…" registers the folder in place.
- A `DispatchSource` watches `main`'s directory, which handles atomic-rename writes, with a 300 ms debounce, then reloads the host.
- The registry marks the plugin `dev` so the UI can badge it.
- Test: `LeoPluginDevWatcherTests` with an injected file-event source: a burst of writes produces one reload.

**3.9 Uninstall**
- Move `<id>/` to the Trash (recoverable), delete the `leo.plugin.<id>.*` Keychain items, and drop the registry entry.
- Test: covered in `LeoPluginManagerTests`.

---

## M4: Renderers, the four slots, palette (4.1 needs only M1 and can run alongside M2/M3; 4.2–4.5 need 3.6)

**4.1 AppKit renderers**: `Plugins/Render/`
- Views: `LeoPluginListView` (NSTableView with sections), `LeoPluginDetailView` (a read-only NSTextView using an `NSAttributedString` built from the 1.4 AST), `LeoPluginFormView`, `LeoPluginAccessoryView`, `LeoPluginEmptyStateView`, `LeoPluginLoadingView`, `LeoPluginErrorView`, and a `LeoPluginNodeView` dispatcher that applies the 1.5 diff.
- List behavior:
  - context menu equals the item's actions
  - ⌘↩ opens an action panel popover
  - Return runs the first action
  - every click and key path mints the `LeoPluginGesture`
- Test: `LeoPluginListInteractionTests` drives the presentation model (Return runs action 0, ⌘↩ lists every action, the context menu matches) plus the Markdown-to-attributed conversion.
- Styling is a TDD exception.

**4.2 Slot 1, agent view picker**
- Adds `LeoRowPane.Content.plugin(LeoPluginViewRef)` in `Editor/LeoRowPanes.swift`.
- New `Plugins/Slots/LeoPluginPaneViewController: LeoRowPaneChild` hosted by `LeoRowPaneContainerViewController`.
- Entries go in the agent toolbar menu (`Toolbar/LeoAgentToolbarMenu.swift`) and the row context menu, next to Browser and Editor (Q9).
- Opening a view sends `viewOpened(agent, slot)`.
- Test: `LeoRowPaneContentTests` checks that choosing a plugin view sets the content and sends `viewOpened` once, and that switching rows keeps each row's child.

**4.3 Slot 2, row accessory**
- `Plugins/Slots/LeoPluginAccessoryPresentation.swift` (pure), wired into `Sidebar/LeoAgentRowContent.swift`.
- Rules:
  - SF Symbol allowlist (`LeoPluginSymbolAllowlist`)
  - text clamped to 8 characters
  - semantic colours mapped through `LeoTint`
  - one accessory per plugin per row, ordered by plugin id
  - beyond N visible (Q10), they collapse into one "+N" glyph
- Test: `LeoPluginAccessoryPresentationTests` covers a symbol outside the allowlist (dropped), a 9-character text, and overflow.
- Styling is a TDD exception.

**4.4 Slot 4, sidebar section**
- `Plugins/Slots/LeoPluginSidebarSection.swift` is added in `Sidebar/LeoSidebarView.swift` below the agent list, following the `LeoTerminalsSection` pattern.
- Collapsed by default. Collapse state and "Hide section" live in `LeoSidebarPreferences`.
- The first expand sends `activate` for that slot if it has no tree yet.
- Test: `LeoPluginSidebarSectionStateTests` covers default collapsed, hide persisting, and unhide from Settings.

**4.5 Slot 3, palette commands**
- Add one injection seam in `Command Palette/TerminalCommandPalette.swift`: `commandOptions` appends `pluginOptions`, which come from an injected `LeoPluginCommandSource`. Keep the upstream diff minimal.
- `pushView` replaces the palette list with a renderer-hosted view, with Esc going back. This is a small state addition in `CommandPalette.swift`.
- The binding stays upstream's `toggle_command_palette` (⌘⇧P). ⌘K is not touched.
- Test: `LeoPluginCommandSourceTests` checks commands appear with title and symbol, selecting one sends `command(id)`, `pushView` swaps content, and Esc pops.

---

## M5: Settings → Plugins pane (depends on 3.1–3.9)

**5.1** Add `LeoSettingsTab.plugins` and `Settings/LeoPluginsSettingsView.swift` plus a model.
- The list shows:
  - enable toggle
  - name, version, and short SHA
  - source
  - DEV badge
  - a permissions summary
  - the disabled-by-crash notice with Re-enable
  - Uninstall (with a confirm)
  - hidden sections, with Show
- Buttons: "Install from URL…", "Load local folder…", "Check for updates".
- The pane is app-local, not per machine, so it bypasses the machine-target gating in `LeoSettingsPaneState`.
- Test: `LeoPluginsSettingsModelTests` covers the row presentation for each source and state, that install runs nothing before approval, and that re-enable clears the supervisor.
- Layout is a TDD exception.

---

## M6: SDK, fixture plugin, screenshots, backlog

**6.1 SDK**: `plugins/sdk/`
- `leo.d.ts` mirrors 1.4, 1.6 and 1.7 one to one.
- `actions.ts` holds pure constructors, including `sendToAgent` and `spawnAgent`.
- An esbuild template: `package.json` with an exact esbuild version, a `build` script producing a single IIFE bundle, and a sample `leo-plugin.json`.
- README. Not published to npm.
- Verify: `cd plugins/sdk/template && npm ci && npx tsc --noEmit && npm run build`.

**6.2 Kitchen-sink fixture**: `macos/Tests/Fixtures/Plugins/kitchen-sink/`
- Prebuilt JS is committed, so no Node is needed in the Xcode build.
- It contributes every slot, every component, and every action, including send and spawn behind the sheet.
- It is loaded in debug builds only, through `LEO_PLUGIN_DEV_DIRS`, the same launch-environment pattern as `LeoAttentionFixture`.
- It never ships in the bundle.

**6.3 Screenshots**
- Use the isolated daemon recipe, a stub scratch agent, and Peekaboo with `--capture-engine cg`.
- Capture each slot in light and dark:
  - pane view
  - row accessory with "+N"
  - palette list and pushed view
  - sidebar section
  - confirm sheet
  - Settings pane
- Open and audit every image, then post them to Evan through `leo_chat_post`.

**6.4** Run `/idea leoterm: iOS plugin host (reuse LeoKit Plugins)`.

---

## Parallelism

| Lane | Steps | Depends on |
|---|---|---|
| A | 1.1, 1.2, 1.3 | — |
| B | 1.4, 1.5, then 4.1 | — |
| C | 1.6, 1.7, then 2.1 | — |
| D | M0, then 2.2 | — (2.2 waits for M0's verdict) |
| E | 3.3, 3.5 services (behind protocols) | 1.2, 1.3 |
| F | 6.1 SDK | 1.4, 1.6, 1.7 |

Then, in order: 2.3–2.6 → 3.1, 3.2, 3.4, 3.6–3.9 → 4.2–4.5 (four implementers, separate files; 4.5 touches upstream palette files) → M5 → 6.2–6.3.

Landable milestones: M1 alone is inert. M2 and M3 ship disabled behind no UI. M4 and M5 make it user-visible. Run the full suite plus the signed-build sandbox check at the merge gate.

---

## GitHub plugin coverage check

| Need | Covered by |
|---|---|
| Device-flow POST with form body, ETag 304, redirect hosts | 1.2, 3.5 |
| Token in Keychain | `leo.secrets` (3.5) |
| PR status accessory | 4.3 |
| `viewOpened`, `agentsChanged`, 60 s refresh | 1.7, 3.6, `leo.timer` |
| Spawn with `machine` = Leo default | 3.7 |
| Every send through the sheet | 1.6, 3.7 |
| Assigned-issues section | 4.4 |
| 5 commands, Create PR form | 4.5, 1.4 |

**Gaps that need a decision before the GitHub plan:** Q4, Q5, Q6, Q7 below.

---

## Risks and open questions (✱ = not settled by the spec; recommendation given)

- **Q1 ✱** One process per plugin depends on the undocumented `_MultipleInstances`. *Rec:* let M0 decide. If it fails, Evan approves the spawned sandboxed-helper fallback.
- **Q2 ✱** JIT in the sandboxed host. *Rec:* no `allow-jit` (interpreter only, smaller attack surface). Revisit only if measured slow.
- **Q3 ✱** How `render(slotId)` addresses per-agent slots. *Rec:* typed `LeoPluginSlotID` passed inside each event (1.7).
- **Q4 ✱** **Needed by GitHub.** A callback must be able to lead to a send or spawn after async work: "Send failure" fetches the log first, and the batched comments come from Form values. *Rec:* a `callback` handler may resolve to one follow-up action. The app honours it only for gesture-originated callbacks, within 30 s wall time, and still through the confirmation sheet. This adds gate tests in 1.6.
- **Q5 ✱** **Needed by GitHub.** Its view stacks a PR `Detail`, a checks `List`, comments, and a rate-limit banner. *Rec:* a slot root may be an ordered array of components. This adds no new component type.
- **Q6 ✱** **Needed by GitHub.** "Rate limited until HH:MM" needs an accessory tooltip, which the spec's Accessory lacks. *Rec:* add an optional `help` field (≤ 80 characters) to Accessory.
- **Q7 ✱** **Needed by GitHub.** Device-flow polling runs about every 5 s, but `leo.timer` has a 60 s minimum. *Rec:* add a one-shot `leo.after(sec ≥ 1, fn)`, live only while a slot of that plugin is visible.
- **Q8 ✱** Fetch scheme. *Rec:* https only, any port on an allowed host.
- **Q9 ✱** The spec says there is a "Terminal/Chat/Browser/Editor picker", but the toolbar switch is Terminal|Chat only (`LeoViewSwitchPresentation`). Browser and Editor open into the row pane. *Rec:* plugin views go in the toolbar menu and row menu and show in the row pane. No new toolbar segments.
- **Q10 ✱** How many accessories show before "+N". *Rec:* 2.
- **Q11 ✱** First-party plugins "enabled by default". *Rec:* pre-approved for their shipped permissions. Any increase after an app update shows the diff.
- **Q12** `git` needs the Command Line Tools on the user's Mac. v1 surfaces an error. ssh URLs are out (https only).
- **Q13** Test builds use `CODE_SIGNING_ALLOWED=NO`, so the sandbox isn't enforced in CI tests. The signed-build check in 2.2 covers it, and it is part of the merge gate.
- **Q14** The daemon's `repo` is passed through verbatim and may not be `owner/repo`. The GitHub plan must map it.
- **Q15 ✱** The debug app shares `Application Support/Leo/Plugins`. *Rec:* debug uses `Leo-Debug/Plugins`, like the separate debug defaults.
- **Q16 ✱** Agent targets cover top-level agents only, not dispatches.
- **Q17** The watchdog polls, so a runaway handler can overshoot 2 s of CPU by up to 250 ms. Accepted.
- **Q18** 4.5 edits upstream palette files and will conflict on upstream syncs. Keep the seam to two small hunks.
- **Q19 ✱** The bundle size cap (10 MB) is set by this plan, not the spec. Confirm.
- **Q20** The spec says the palette "also contains Leo's built-in commands". Adding new Leo built-ins to it is not in this plan.

---

## Orchestrator decisions (2026-11-10)

All ✱ recommendations above are accepted as written: Q1 (M0 decides; fallback needs Evan), Q2, Q3, Q4, Q5, Q6, Q7, Q8, Q9, Q10 (= 2), Q11, Q15, Q16, Q19 (10 MB). Q4–Q7 and Q9 are folded back into the spec, so implementers treat the spec as the source for them.

### M0 outcome (2026-11-10)

XPC-per-plugin failed. Evan approved the fallback: one sandboxed helper per plugin, spawned with `posix_spawn` from `Contents/Helpers/` and connected over a `socketpair`. Steps 2.2–2.4 and 2.6 use the helper in place of the XPC service:
- The helper gets an embedded Info.plist and its own bundle id.
- The app's socket ends are set `FD_CLOEXEC`.
- The app ignores `SIGPIPE`.
- Process exit is detected with `DispatchSource.makeProcessSource(.exit)`.
- The manager owns restart and backoff, and kills orphaned helpers on launch.
- CPU ticks are converted with `mach_timebase_info`.

Evidence is in `docs/plans/2026-11-10-plugin-platform-spike.md`.

### M1 security review (2026-11-10)

- **Fixed in M1:**
  - Decode budgets now apply to nested `pushView` and callback-result trees and to collections, with a frame byte cap.
  - The Markdown parser is linear-time, with a byte cap.
  - `main` is split on ASCII `/` bytes, and the app checks resolved-path containment wherever it reads a bundle (step 3.3 enforces this too).
  - IDN hosts are matched in canonical ASCII form; numeric and IP hosts are rejected.
  - Keychain items use service `leo.plugin.<id>` with account `<key>` (step 3.5).
- **Accepted risks:**
  - Concurrent gesture redemption. All callers are `@MainActor` in the app, so two racing redemptions can't happen in practice.
  - JS rewriting bridge envelopes through `toJSON`. Step 3.6 must resolve callback refs against live, single-use records scoped to the plugin and its host session, and must never trust the envelope.

### M2 notes for M3 (2026-11-10)

- Step 3.6: the manager calls `LeoPluginHostOrphanReaper` once at launch, before spawning any helper.
- The helper sends a `{"done":1}` frame after each command so the watchdog can time handlers.
- Hardened runtime on the helper relies on the release workflows re-signing it with `-o runtime`, because ad-hoc local builds drop the flag.

### M3 (3.3/3.5) security review (2026-11-10)

- **Fixing now:**
  - A timer interval overflow trapped the app (`leo.timer(id, 1e19)`).
  - A repo could claim an installed plugin's id and inherit its secrets.
  - Reinstalling the same SHA deleted the live folder.
  - Binary fetch bodies came back corrupted.
- **For later steps:**
  - 3.4 must call `install(url:sha:)` with the SHA the user saw.
  - 3.1 and 3.6 enforce that an id is bound to its source URL.
  - The 3.6 router dispatches on a single actor.
- **Accepted risks:**
  - Symlinks other than `main` are kept, because only `main` is ever read.
  - Clone size has no cap, only the 120 s fetch timeout.
  - Custom auth headers follow redirects, but only to hosts on the plugin's own allowlist.
  - A redirect to another port on the same host keeps `Authorization`.
  - The timer cap check has a race, which can't happen while dispatch is on one actor.
  - Secrets use the legacy file keychain with no per-plugin key count limit.
  - The snapshot passes `repo` through without stripping credentials. The daemon supplies `owner/repo` or a path.
- **M3 re-review:** all fixes resolved. In step 3.1, `idClaims` becomes a required installer parameter, the registry supplies it, and a test covers that wiring. Source paths compare case-sensitively, so `Owner/Repo` and `owner/repo` count as different sources. This is accepted because it fails safe.

### M2 security review (2026-11-10)

- **Fixing now:**
  - The memory cap was only polled during handlers. It becomes an always-on 1 s poll, plus a check on every `done` frame and a CPU-growth-while-idle check.
  - A plugin could flood the app with requests. Each handler gets a request and byte quota, the read source applies backpressure, and queued requests are dropped after the helper exits.
  - The socket fd was closed while a read could still be in flight. It is now closed only in the cancel handler.
  - The helper inherited the app's stdin and stdout. Both now point to `/dev/null`.
- **Accepted risks:**
  - The `socketpair`/`FD_CLOEXEC` race with a concurrent fork.
  - The orphan-reaper pid TOCTOU (microseconds wide).
  - An orphaned spinning helper burns a core until the next launch.
  - No EINTR retry on `waitpid`.
  - JSON slash escaping inflates the load frame. This only matters for bundles near the 10 MB cap.
  - A Sparkle mid-run update can pair a new helper with the old app.
  - All helpers share one sandbox container. Plugins get no file access, so this has no effect.
- **M2 re-review:** all four fixes resolved. Follow-up: the idle-CPU budget scales with how much time actually passed in each poll window. A fixed 0.5 s budget could kill a plugin by mistake when App Nap stretches the poll gap, and a backgrounded Leo makes that realistic.
