# Plugin install links: implementation plan

Spec: `docs/superpowers/specs/2026-11-22-plugin-install-links.md` (the spec wins if this plan disagrees with it). Branch: `feat/plugin-install-links`.
**Platform: Mac only.** The plugin host runs only on Mac. All the pure logic goes in LeoKit anyway, because that is where the plugin code already lives. Nothing goes to iOS.

## Facts this plan relies on (checked)

- `LeoPluginGitSource.validatedURL(_:allowedSchemes:)` already refuses non-https URLs, URLs with credentials, whitespace and a leading `-`. `validatedRef(_:)` turns an empty ref into `"HEAD"` and trims whitespace. It allows only `[A-Za-z0-9._/+-@]`, at most 200 characters, with no leading `-` and no `..`.
- **The Install-from-URL flow already takes a ref.** `LeoPluginInstallSourceSheet` (`LeoPluginsSettingsView.swift:215`) has a "Branch or tag" field, and `LeoPluginsSettingsModel.install(url:ref:)` passes it on. What's missing is a way to open that sheet with the fields already filled. Its `@State url/ref` start out empty.
- `LeoPluginApprovalRequest` has no source enum, only `sourceDescription` and `isDev`. It is built in three places: `LeoPluginInstallFlow.stage`, `LeoPluginUpdater.check` (around line 63), and `init?(reviewing:)`. The sheet itself is `LeoPluginApprovalSheet` (`macos/Sources/Features/Leo/Plugins/Install/LeoPluginApprovalSheet.swift`).
- `LeoPluginsSettingsModel` is created per view (`@StateObject` in `LeoPluginsPane`). `isBusy` stays true for the whole install or update run, including the time the approval sheet is waiting. `isAskingInstallSource` is true while the URL sheet is up.
- The Mac app uses `macos/Ghostty-Info.plist`, which has no `CFBundleURLTypes` entry. The pbxproj defines `LEO_DAEMON_LABEL` per configuration (lines 768, 1174 for Debug, 1233) and the plist reads it as `$(LEO_DAEMON_LABEL)`. A new `LEO_URL_SCHEME` follows the same pattern.
- `AppDelegate` implements `application(_:openFile:)` and nothing for URLs. **Implementing `application(_:open urls:)` would stop AppKit from calling `openFile:`**, so the link handler must be an Apple Event handler for `kAEGetURL`, installed in `applicationWillFinishLaunching` (line 355) so it also catches the URL that launches the app.
- Settings opens through `LeoRuntime.settingsWindow.show(_ entry: LeoSettingsEntry)`. `LeoSettingsEntry` has no `.plugins` case yet, while `LeoSettingsSidebarItem.plugins` already exists. The plugin system starts late, in `LeoRuntime.startPlugins()` around line 630, after the daemon flavor is detected.

## Commands

- Before the first build: `export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`
- LeoKit: `swift test --package-path Packages/LeoKit --filter <Suite>`
- Mac build, run in the background under `heavy`, from `macos/`:
  `heavy xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
- Mac tests:
  `timeout 600 xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<Suite>`
- Lint: run `swiftlint lint --strict` in `Packages/LeoKit` and in `macos/`.
- Tests use Swift Testing (`@Suite`/`@Test`, `#expect`).

## Phase 1: Unverified-source warning (Part A)

### Step 1. `LeoPluginSourceTrust` (LeoKit)

- **New file:** `Packages/LeoKit/Sources/LeoKit/Plugins/Install/LeoPluginSourceTrust.swift`
  - `public enum LeoPluginSourceTrust: Equatable, Sendable { case verified, unverified, notApplicable }`
  - `public static func classify(_ source: LeoPluginSource) -> LeoPluginSourceTrust`
  - `static let trustedHost = "github.com"` and `static let trustedOwner = "blackpaw-studio"`
- **Rule:**
  - `.bundled` and `.dev` return `.notApplicable`.
  - `.git(url:…)` goes through `validatedURL(url, allowedSchemes: ["https"])` first. A failure returns `.unverified`.
  - It is `.verified` only if the lowercased host equals `github.com` exactly, there is no port, and the first non-empty path segment, lowercased, equals `blackpaw-studio`.
- **Failing test first:** new `Packages/LeoKit/Tests/LeoKitTests/Plugins/LeoPluginSourceTrustTests.swift`
  - `blackpawRepoIsVerified`: `https://github.com/blackpaw-studio/leo-plugin-usage` and `https://GitHub.com/Blackpaw-Studio/x.git` both give `.verified`.
  - `spoofsAreUnverified`, a parameterized test over the four spoofs in the spec (as https URLs) plus `https://www.github.com/blackpaw-studio/x`: each gives `.unverified`.
  - `nonHTTPSIsUnverified`: a `file:///…` URL gives `.unverified`.
  - `localSourcesHaveNoLabel`: `.bundled` and `.dev(path:)` give `.notApplicable`.
- **Verify:** `swift test --package-path Packages/LeoKit --filter LeoPluginSourceTrustTests`

### Step 2. Carry the trust value on the approval request (LeoKit)

- **Files:** `Install/LeoPluginApproval.swift`, `Install/LeoPluginInstallFlow.swift`, `Install/LeoPluginUpdater.swift`.
- **Change:** add `public let trust: LeoPluginSourceTrust` to `LeoPluginApprovalRequest` as a **required** init parameter, so the compiler catches every place that builds a request. Add `public var isUnverified: Bool { trust == .unverified }`.
  - `stage` classifies `.git(url: result.url, ref: result.ref, sha: result.sha)`.
  - The updater classifies the record's git source.
  - `init?(reviewing:)` classifies `info.source`.
  - `stageDev` passes `.notApplicable`.
- **Failing tests first:**
  - In `LeoPluginApprovalReviewTests`: `reviewingGitSourceCarriesTrust`. A `needsApproval` info with a source of `.git(url: "https://evil.com/blackpaw-studio/x", …)` gives `request.trust == .unverified`. The same info with a `.bundled` source gives `.notApplicable`.
  - In `LeoPluginUpdaterTests`: `pendingUpdateCarriesUnverifiedTrust`. A `.needsApproval` outcome for a non-Blackpaw URL gives `pending.request.trust == .unverified`.
  - Install flow: a test asserting that `stage` on a non-Blackpaw URL gives `.unverified`. Put it in the existing install-flow suite; if there isn't one, put it in `LeoPluginGitInstallerTests`, which has a fake git.
- **Then:** fix every existing test that builds a request so it compiles.
- **Verify:** `swift test --package-path Packages/LeoKit --filter 'LeoPluginApprovalReviewTests|LeoPluginUpdaterTests|LeoPluginGitInstallerTests|LeoPluginSourceTrustTests'`

### Step 3. Banner and row label (Mac UI)

- **Files:**
  - `macos/Sources/Features/Leo/Plugins/Install/LeoPluginApprovalSheet.swift`
  - `macos/Sources/Features/Leo/Settings/Plugins/LeoPluginRow.swift`
  - `macos/Sources/Features/Leo/Settings/Plugins/LeoPluginsSettingsView.swift`
- **Changes:**
  - **Approval sheet:** when `request.isUnverified`, show a warning banner under the title. It uses `exclamationmark.triangle.fill` and `LeoSettingsStatus.warning.color`, with exactly this text: "Not from Blackpaw Studio. Only install plugins from people you trust." It must not disable the confirm button. The same view serves install and update, so both get the banner.
  - **Row model:** add `let isUnverified: Bool` to `LeoPluginRow`, set from `LeoPluginSourceTrust.classify(info.source) == .unverified`.
  - **Row view:** `LeoPluginRowView` shows a small secondary "Unverified" capsule next to the name.
- **Failing test first:** in `macos/Tests/Leo/LeoPluginsSettingsModelTests.swift`, add `unverifiedGitRowIsLabelled`. A fake manager publishes one git plugin from `https://github.com/someone/x` and one from `https://github.com/blackpaw-studio/y`. Assert that `rows.map(\.isUnverified) == [true, false]`, and that bundled and dev rows give `false`.
- **Verify:** Mac build, then `-only-testing:GhosttyTests/LeoPluginsSettingsModelTests`. Banner styling counts as UI styling under the TDD exceptions, so its check is the screenshot in Step 9.

## Phase 2: `leo://` install link (Part B)

### Step 4. `LeoPluginInstallLink.parse` (LeoKit)

- **New file:** `Packages/LeoKit/Sources/LeoKit/Plugins/Install/LeoPluginInstallLink.swift`
  - The spec's `(source, ref?)` tuple becomes a struct so it can be `Equatable`: `public struct LeoPluginInstallLink: Equatable, Sendable { public let url: URL; public let ref: String? }`
  - `public static let schemes: Set<String> = ["leo", "leo-debug"]`
  - `public static func parse(_ link: URL) -> Result<LeoPluginInstallLink, LeoPluginInstallLinkError>`
  - `public enum LeoPluginInstallLinkError: Error, Equatable, LocalizedError` with cases `wrongScheme`, `wrongTarget` (host or path), `unknownKey(String)`, `duplicateKey(String)`, `missingURL`, `invalidURL(String)` (carries the reason from `validatedURL`), and `invalidRef(String)`. Each case's `errorDescription` is a sentence a user can read.
- **Rules:**
  - The scheme, lowercased, must be in `schemes`. The host, lowercased, must be `plugin`. The path must be exactly `/install`.
  - The link must have no user, password, port or fragment.
  - Read keys from `URLComponents.queryItems`. Keys are case-sensitive, and only `url` and `ref` are allowed, each at most once.
  - `url` is required and goes through `validatedURL(_, allowedSchemes: ["https"])`.
  - If `ref` is present, it must be non-empty, already trimmed, and pass `validatedRef`.
- **Failing test first:** new `LeoPluginInstallLinkTests.swift`
  - `parsesLinkWithRef`: `leo://plugin/install?url=https%3A%2F%2Fgithub.com%2Fblackpaw-studio%2Fleo-plugin-usage&ref=v0.1.0` gives `.success` with that URL and the ref `"v0.1.0"`.
  - `parsesLinkWithoutRef`: gives `ref == nil`.
  - `acceptsDebugScheme`.
  - A parameterized `rejects` test with one failure case each for:
    - a wrong scheme (`ghostty://`)
    - a wrong host (`leo://plugins/install`)
    - a wrong path (`/install/`)
    - an unknown key (`&foo=1`)
    - a duplicate `url`
    - a duplicate `ref`
    - a missing `url`
    - an `http://` URL
    - `https://u:p@github.com/x`
    - each bad ref: `-x`, `a..b`, `a b`, an empty value, and `ref=%0A`
  - Each case asserts the specific error enum case.
- **Verify:** `swift test --package-path Packages/LeoKit --filter LeoPluginInstallLinkTests`

### Step 5. Register the URL scheme per configuration (config, no test)

- **Files:** `macos/Ghostty.xcodeproj/project.pbxproj` and `macos/Ghostty-Info.plist`.
- **Changes:**
  - Add `LEO_URL_SCHEME` next to every `LEO_DAEMON_LABEL`: `leo-debug` in the Debug configuration (line 1174), `leo` in the others.
  - In the plist, add `CFBundleURLTypes` with one entry: `CFBundleURLName = $(PRODUCT_BUNDLE_IDENTIFIER).plugin-install`, `CFBundleURLSchemes = [$(LEO_URL_SCHEME)]`.
- **Verify:** after the Mac build, `plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw build/DD/Build/Products/Debug/*.app/Contents/Info.plist` prints `leo-debug`. For Release, check that `xcodebuild -showBuildSettings -configuration Release | grep LEO_URL_SCHEME` shows `leo`.

### Step 6. `LeoSettingsEntry.plugins`

- **File:** `macos/Sources/Features/Leo/Settings/Sidebar/LeoSettingsSidebarItem.swift`
- **Change:** add `case plugins`, and make `item(remembered:configurations:)` return `.plugins`.
- **Failing test first:** in `macos/Tests/Leo/LeoSettingsSidebarItemTests.swift`, add `pluginsEntryLandsOnPlugins`, asserting `LeoSettingsEntry.plugins.item(remembered: .machine(.local), configurations: []) == .plugins`.
- **Verify:** `-only-testing:GhosttyTests/LeoSettingsSidebarItemTests`

### Step 7. Link router and filled-in Install sheet (Mac)

- **New file:** `macos/Sources/Features/Leo/Plugins/Install/LeoPluginInstallLinkRouter.swift`, a `@MainActor final class LeoPluginInstallLinkRouter: ObservableObject`.
  - Its dependencies are injected: `openPluginsSettings: @MainActor () -> Void`, `showError: @MainActor (String) -> Void`, and a `Logger`.
  - `@Published private(set) var pending: LeoPluginInstallLink?`
  - `var isInstallUIOpen = false`, which the settings model sets.
  - `func receive(_ url: URL)`
  - `func markReady()`
  - `func take() -> LeoPluginInstallLink?`
- **Behavior of `receive`:**
  - A parse failure calls `showError(reason)` and does nothing else.
  - If `isInstallUIOpen` is true, or a link is already pending, the router logs "ignored plugin install link: sheet open" and drops the link.
  - Otherwise it stores `pending`, and if the router is ready it calls `openPluginsSettings()`.
- **Behavior of `markReady`:** marks the router ready, and if a link is pending, calls `openPluginsSettings()`. This is how cold launch works.
- **`LeoPluginsSettingsModel` changes:**
  - New init parameter `links: LeoPluginInstallLinkRouter?`.
  - `@Published private(set) var installPrefill: (url: String, ref: String)?`, as an Equatable struct.
  - On init, and whenever `links.$pending` changes: if the model is not busy and the URL sheet is not up, it calls `take()`, sets `installPrefill`, and sets `isAskingInstallSource = true`.
  - Whenever `isBusy || isAskingInstallSource` changes, the model writes that value to `links.isInstallUIOpen`.
- **`LeoPluginInstallSourceSheet` changes:** it takes `initialURL` and `initialRef` to seed its `@State`. The prefill clears when the sheet is dismissed. The user still has to press Continue, and the review sheet still follows.
- **Failing tests first:**
  - New `macos/Tests/Leo/LeoPluginInstallLinkRouterTests.swift`:
    - `badLinkShowsErrorAndDoesNotOpen`
    - `linkWhileInstallUIOpenIsIgnored`: set `isInstallUIOpen = true`, call `receive`, and assert `pending == nil` and that settings was not opened.
    - `linkBeforeReadyIsHeldUntilMarkReady`: no open before `markReady()`, then exactly one open after it.
  - In `LeoPluginsSettingsModelTests`:
    - `pendingLinkPrefillsInstallSheet`: the router holds a link with a URL and ref, the model is created, and the test asserts `isAskingInstallSource == true` and that `installPrefill` equals the URL and ref. It also asserts that the fake installer's `stage` was **not** called.
    - `linkArrivingDuringUpdateIsIgnored`: start `checkForUpdates` with an approval closure that suspends, deliver a link, and assert `router.pending == nil` and that the prefill is unchanged.
- **Verify:** `-only-testing:GhosttyTests/LeoPluginInstallLinkRouterTests -only-testing:GhosttyTests/LeoPluginsSettingsModelTests`

### Step 8. Wire it into the app (glue, no unit test)

- **`AppDelegate.swift`:**
  - Own a lazy `LeoPluginInstallLinkRouter`. Its `openPluginsSettings` closure calls `leoRuntime.settingsWindow.show(.plugins)`, which also activates the app. Its `showError` closure shows an `NSAlert` titled "Can't open plugin link".
  - In `applicationWillFinishLaunching`, register `NSAppleEventManager.shared().setEventHandler(_:andSelector:forEventClass: kInternetEventClass, andEventID: kAEGetURL)`. The handler reads `keyDirectObject` and calls `router.receive(url)`.
- **`LeoRuntime.startPlugins()`:** after `plugins = system`, call `router.markReady()`. Pass the router in through the `LeoRuntime` init rather than as a global.
- **`LeoPluginsSettingsModel(system:)`:** thread `links` through. Give the router to `LeoRuntime` or `LeoPluginSystem` so this convenience init can reach it.
- **Verify:** the Mac build, then the live check in Step 9.

### Step 9. Live check (the done criterion)

1. Launch the debug build. Use the scratch-agent and keystroke-safety rules in memory: send no blind Return.
2. Run `open 'leo-debug://plugin/install?url=https%3A%2F%2Fgithub.com%2Fsomeone%2Ffork&ref=main'`. Expect Leo to come to the front on Settings → Plugins with the URL sheet filled in. Continue to the approval sheet and screenshot the banner, then Cancel.
3. Repeat with a `blackpaw-studio` repo: the sheet must have no banner. Until the repo from Phase 3 exists, use any public `blackpaw-studio` repo that has a plugin manifest, or stop at the clean review sheet.
4. Run `open 'leo-debug://plugin/install?url=http%3A%2F%2Fx'`: expect the error alert.
5. Open a link while the approval sheet is up: expect no second sheet and a log line, checked with `log show --predicate 'subsystem == "…"'`.
6. Cold launch: quit, `open` a link, and expect the sheet to appear once plugins start.
7. Inspect every screenshot before posting it.

### Step 10. Integration gate

Run the full LeoKit `swift test`, run the Mac unit suite through `.github/scripts/leo/run-unit-tests-retry.sh` in the background under `heavy`, then lint. After that comes a review dispatched by the orchestrator. Use `review.security`, because a URL handler parses untrusted input.

## Phase 3: Usage plugin to its own repo (Part C)

**Gated:** start only after `usage-plugin` merges to main. It has 37 commits and is not merged yet; it is still waiting on Evan's live Keychain check. The orchestrator creates the repo after Evan approves the exact `gh repo create` command. Implementer steps begin only after that.

**What moves** (from `plugins/usage/` in the usage-plugin worktree):
- `leo-plugin.json` (id `studio.blackpaw.usage`, v0.1.0, apiVersion 2)
- `src/`: main, plugin, api, state, poller, views, store, `parse/{claude,codex}`, window, tone, format, clock
- `dist/main.js`, which is committed build output
- `test/`, with `stubLeo.ts` and `fixtures/`
- `package.json`, `package-lock.json`, `tsconfig.json`, `vitest.config.ts`, `.nvmrc`, `.gitignore`

The commands are `npm test` (vitest run), `npm run typecheck` and `npm run build` (esbuild).

**Relative-path dependencies to cut:**
- **The SDK by relative path:** `src/{api,plugin,poller,views,main}.ts` and `test/{stubLeo,plugin}.test.ts` import `../../sdk/leo`, and `tsconfig.json:13` includes `../sdk/leo.d.ts`. Vendor `plugins/sdk/leo.d.ts` into the new repo as `sdk/leo.d.ts`, with a header naming the leoterm commit it was copied from, and rewrite the imports.
- **A test that reads a Swift file:** `test/symbols.test.ts:2` reads `Packages/LeoKit/Sources/LeoKit/Plugins/Slots/LeoPluginSymbolAllowlist.swift?raw`. Either vendor a snapshot of the allowlist (same pinned-commit header) or drop the test. **Decision for Evan or the orchestrator:** a vendored snapshot can drift from the app's real allowlist.

**What else changes in leoterm:**
- Remove `plugins/usage/`.
- Remove the plugin test job (`.github/workflows/leo-ci.yml:102–130`, `working-directory: plugins/usage`) and the bundle guard at `leo-ci.yml:134` (`test ! -e macos/Bundled/Plugins/studio.blackpaw.usage`).
- `macos/Tests/Leo/Plugins/LeoPluginUsageRenderTests.swift:119` reads `plugins/usage/test/fixtures/trees/*.json`. Copy those fixtures into `macos/Tests/Leo/Plugins/Fixtures/` or delete the test. Decide this when the phase starts.
- `macos/scripts/leo-bundle-plugins.sh` needs no change.

**In the new repo:**
- A minimal GitHub Actions workflow that runs `npm ci && npm run typecheck && npm test` and diffs `dist/`.
- A `v0.1.0` tag.
- A README with the install link from the spec.

The tag push and the first release are publish steps that need Evan's approval.

## Risks and open questions

1. **Port and `www.` host.** The plan treats `github.com:443/blackpaw-studio/…` as unverified; the spec says nothing about ports. This is conservative and only produces a false warning.
2. **Ref check is looser than git's.** `validatedRef` checks characters, not full `git check-ref-format`, so it allows things like `foo.lock`, `a//b` and `@{`. The value is passed to git as an argument and resolved through `ls-remote`, so this is safe. It is still looser than the spec's wording.
3. **Second link while one is pending:** the plan drops it, to resist spam. The spec only covers the case where a sheet is open.
4. **Plugins never start.** `startPlugins` runs only after the daemon flavor is detected. If there is no daemon, a link received at cold launch waits indefinitely. That is acceptable, but no alert tells the user.
5. **Spinner never clears (existing bug).** `LeoPluginsSettingsView` reads `system()` once. If Settings opens before plugins start, the pane may sit on "Starting plugins…". `markReady` avoids this for links. Fixing the general case is a separate follow-up.
6. **Must not use `application(_:open:)`.** That method would silently break `openFile:` routing. Use the `kAEGetURL` handler from Step 8.
7. **Both builds parse both schemes.** The release build parses `leo-debug` too, but macOS only routes the scheme a build registers, so this is harmless.
