# Plan: Portable CI tests (host-only tier)

Spec: `docs/superpowers/specs/2026-11-01-portable-ci-tests.md` (source of truth). Branch `ci/portable-tests`. Platform: **Mac only**, as the spec says. Build with `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`. Wrap full suites and xcodebuild runs in `heavy` and start them in the background.

## What the hosted logs show

| Run | Outcome |
|---|---|
| 41363975795, 41368878560 | Hung in `LeoChatCopyTests.commandCCopiesSelectedChatText` (60 s time limit, then the 900 s script kill). Also failed: `LeoAgentMenuSheetTests.delete…` (awaitCondition, `LeoTestSupport.swift:16`), `LeoFirstAttachWindowSizeTests` (:221 and :280, sidebar off by 8 pt), `LeoRowLayoutCloseTests:37`, `LeoRowLayoutKeepTests:106`, `LeoSidePaneTitlebarStyleTests` (:49–99, ink geometry) |
| 41366841194 | Crashed in `LeoEnvironmentActionsTests.escapeClosesTheEditOrderSheet` (:109, `sheetWindow.cancelOperation`). It also hit the same AgentMenuSheet failure. |

- **Hosted runners do have a window server.** About 280 suites that create windows, surfaces and sheets passed. The failures come from key focus, real event delivery, titlebar and screen metrics, and slow real surfaces.
- **118 test files never ran**, because the hang stopped the run first. Step 5 gets results for them.
- **There are no `XCTestCase` classes in `macos/Tests`.** The spec's `XCTSkip` helper is unnecessary, so it's dropped.

## Gate design (step 1)

- `LeoTestTier` is a value type built from `[String: String]`. It turns host tests on only when `LEO_HOST_TESTS` is exactly `1`. `LeoTestTier.current` reads `ProcessInfo`.
- `.hostOnly` is defined as `extension Trait where Self == ConditionTrait { static var hostOnly }`, built with `.enabled(if: LeoTestTier.current.runsHostTests, "host tier: set LEO_HOST_TESTS=1")`.
  - `ConditionTrait` is already both a `TestTrait` and a `SuiteTrait`, so no custom trait is needed. That avoids the rc=6 discovery crash.
  - If someone later writes a custom trait anyway, it must conform to `TestTrait` and `SuiteTrait`.
- `.requiresActiveHost` becomes host tier first, then the focus probe. On CI no probe window is ever created. When the host tier is on and the probe fails, it still skips with the existing `focus-gate-skip:` warning.
- `LeoWKTestHost.hasWindowServer` is deleted. Its 6 suites switch to `.hostOnly`.
- The ad-hoc "needs the app's Ghostty.App" / `hasGhostty` / `hasLiveGhosttyApp` gates are folded in per file in the batches below. The test host always has `Ghostty.App`, so those gates never actually skip anything.
- Snapshot suites keep their own env gates (`LEO_CARD_SNAPSHOTS`, `LEO_SETTINGS_SNAPSHOTS`), and `Benchmarks` keeps `.enabled(if: false)`. Those are tools, not tiers, so they stay as they are.

## Classification table (every environment-dependent file)

**H = host-only** (adds `.hostOnly`; the behaviour under test is the real AppKit, Ghostty, WebKit or process interaction). **P = make portable** (injection named). **OK = portable as is** (an offscreen window or view tree, the `AppDelegate` menu, fake binaries or in-process sockets; green on hosted). **W2 = never reached on hosted**, classified after step 5 (expected class in brackets).

| File(s) | Class | Why / injection | Step |
|---|---|---|---|
| `LeoTestHostActivation.swift`, `AgentBrowser/LeoWKTestSupport.swift` | support | gate rewrite | 1 |
| `LeoChatCopyTests` | H | real ⌘C through `NSApp.sendEvent` and a real surface (B-318). This is the hang. Menu-sync logic is already covered by `LeoStandardEditShortcutsTests`. | 2 |
| `LeoEnvironmentActionsTests` | P | **Sheet presenter seam:** inject `present/dismiss` into `LeoEnvironmentsSheetSession` (default `beginSheet`/`endSheet`). Tests assert the presented controller and the daemon calls, not `window.attachedSheet`. Drives `confirm` and `cancelOperation` on the controller with no window. This is the crash. | 3 |
| `LeoAgentMenuSheetTests`, `LeoNewAgentMenuSheetTests`, `LeoSpawnAgentSheetPresenterTests` | P | same sheet seam. Replace the real surface or terminal controller with a plain stand-in. | B1 |
| `AgentBrowser/LeoWKBrowserPageTests`, `LeoWKBrowserPageProtocolTests`, `LeoAgentBrowserHostTests`, `LeoAgentBrowserTests`, `LeoAgentBrowserParkingWindowTests` | H | real WKWebView (was `hasWindowServer`) | 1 |
| `AgentBrowser/LeoAgentInputDeliveryTests`, `LeoTerminalControlCTests`, `LeoContentFocusTests`, `GhosttyAttachContentHostFocusTests` | H | real key status and `sendEvent` (was `.requiresActiveHost`) | 1 |
| `LeoLaunchFocusTests` | H | asserts real key and first responder at launch | B2 |
| `LeoSidePaneTitlebarStyleTests`, `LeoSidebarTitlebarStyleTests` | H | measures drawn ink in real titled windows; AppKit titlebar metrics differ on hosted | B2 |
| `LeoRowLayoutCloseTests`, `LeoRowLayoutKeepTests`, `LeoRowLayoutFixture` (support) | H | real shells' `needsConfirmQuit`, a 15 s eventually on the child process | B2 |
| `LeoLivePoolIntegrationTests`, `LeoTerminalRowsIntegrationTests`, `LeoTerminalRowMenuIntegrationTests`, `LeoContentSwapIntegrationTests`, `LeoCloseConfirmationIntegrationTests`, `Editor/LeoRowPaneCloseTests`, `LeoTitleIntegrationTests`, `LeoStartScreenIntegrationTests`, `LeoTerminalRestoreIntegrationTests`, `LeoLaunchPlaceholderIntegrationTests`, `GhosttyAttachContentHostRebirthTests`, `LeoEnvironSnapshotTests`, `LeoRuntimeFileDropTests`, `LeoFolderOpenStrayWindowTests` | H | real Ghostty surface or child process is the subject. Some are green on hosted today; see the coverage note. | B2 |
| `LeoFirstAttachWindowSizeTests` | P + H | **Screen frame injection:** first-content sizing takes the `visibleFrame` as a parameter (default `window.screen`). The size-math cases run in CI against a fixed 1440×900 frame. Cases that need `fixture.fill()` with a real surface get `.hostOnly`. | B3 |
| `Files/LeoSSHEndToEnd` | H | real ssh. Keep the host-variable gate and add `.hostOnly`. | B2 |
| `LeoChatQuestionsCardSnapshots`, `LeoChatSenderSnapshots`, `LeoSettingsSnapshots` | OK (opt-in tool) | already env-gated. The `UserDefaults.standard` write at `CardSnapshots:175` only runs under `LEO_CARD_SNAPSHOTS` and is restored afterwards. | — |
| `LeoSSHCommandTests`, `LeoSSHCommandForwardTests`, `LeoPortForwardRunnerTests`, `LeoProcessRunnerTests`, `LeoServiceSettingsModelTests`, `Managed/LeoOutsideDaemonTests`, `LeoBundledGhosttyCLITests`, `LeoControlSocketTests`, `UnixSocketTestServer` | OK | fake binaries on PATH, the bundle's own CLI, in-process sockets; green on hosted | — |
| `AgentBrowser/LeoAgentBrowserToolbarTests`, `LeoHandoffTests`, `LeoHandoffReturnKeyTests`; `Editor/` PaneLayout, PaneMarkdownToggle, QuitReview, TabsViewController, WindowTeardown, RowPaneAgentBrowser, RowPaneContainer; `LeoAboutMenuTests`, `LeoAttachCoordinatorTests`, `LeoCannotStartAlertTests`, `LeoChatFileViewerTests`, `LeoDelegationMatrixScrollTests`, `LeoDispatchAttachTests`, `LeoDispatchPlacementLiveTests`, `LeoLocalDaemonIsolationTests`, `LeoMachineRegistryTests`, `LeoMachinesSettingsLayoutTests`, `LeoNewSurfaceRouterTests`, `LeoNoTabBarTests`, `LeoPickerPresentationTests`, `LeoRingMeterGeometryTests`, `LeoRowClickCatcherTests`, `LeoRowSplitIntoShellTests`, `LeoSettingsPaneStateTests`, `LeoSettingsWindowCloseTests`, `LeoShortcutHintsTests`, `LeoSidebarButtonBarTests`, `LeoSidebarCommandClickTests`, `LeoSplitViewRepresentableTests`, `LeoDisconnectedStateTests`, `LeoGhosttySurfaceHostTests`, `LeoPlaceholderCloseDecisionTests`, `LeoRuntimeConnectionTests`, `Onboarding/LeoOfferAlertPresenterTests`, `ServerMode/LeoServerModeTests`; support `LeoMenuXib`, `LeoUndoTestSupport` | OK | offscreen window or view tree, or the app's own menu; no key, no real surface; green on hosted | — |
| `Browser/LeoWorkspaceBrowserDragOutTests`, `…SessionTests`, `…ViewTests`; `LeoSidebarReturnKeyTests`, `LeoSidebarTerminalScrollTests`, `LeoTerminalsViewportTests`, `LeoSidebarHeaderLayoutTests`, `LeoSidebarRowSpacingTests`, `LeoSidebarContentMinimumTests`, `LeoSidebarFeedActivityCoalescingTests`, `LeoSplitViewRepresentableUpdateTests`, `LeoStartScreenButtonsTests`, `LeoStartTitleTests`, `LeoTitleSourceTests`, `LeoTaskHistoryViewTests`, `LeoWindowPickerRouterTests`, `LeoWindowSessionRegistryTests`, `Editor/LeoTerminalControllerEditorCloseTests`, `Update/UpdateDriverPermissionTests` | W2 [OK expected] | never reached on hosted | 5 |
| `LeoSingleInstanceQuittingHolderTests`, `LeoUnixSocketTransportTests` | W2 [OK, or P with a temp-dir socket and lock path] | never reached on hosted | 5 |
| Upstream `Ghostty/SurfaceViewAppKitTests`, `MenuShortcutManagerTests`, `Surface View/SurfaceView+SearchStateTests`, `NSScreenTests`, `QuickTerminalScreenStateCacheTests` | W2 [OK expected; H only if hosted fails] | upstream files; touch them as little as possible | 5 |

**Coverage note:** about 10 H-class surface suites pass on hosted today. Under the spec they leave CI. Step 6 keeps them running on the self-hosted job until the runners retire.

## Steps

Each step is one implementer pass that ends in its own commit.

**1. Gate trait, runner passthrough, skip listing** (`implement`, effort medium)
- **Failing test first:** `macos/Tests/Leo/LeoTestTierTests.swift`. Unset, `"0"`, `""` and `"true"` mean off; `"1"` means on. `requiresActiveHost` runs no probe when the tier is off (inject the probe factory and assert it's never called).
- **Then:**
  - Rewrite `LeoTestHostActivation.swift` with `LeoTestTier` and `.hostOnly`.
  - Replace `hasWindowServer` in the 6 AgentBrowser files and delete it from `LeoWKTestSupport`.
  - Add `.hostOnly` to the files already marked H at step 1.
- **Script changes:**
  - `run-unit-tests.sh`: pass `LEO_HOST_TESTS="${LEO_HOST_TESTS:-}"` into the `env` call explicitly, and echo `host tier: on|off` before the run.
  - `check-test-log.sh`: print every `➜ (Suite|Test) … skipped` line inside `::group::Skipped tests (N)`, plus a `::notice::` with the count.
  - **Failing case first** in `.github/scripts/leo/tests/` (the check-test-log test): a log containing skip lines must list them by name.
- **Verify:** the new test target (command A); `.github/scripts/leo/run-tests.sh`; and a host-tier-off run of the gated suites shows them as skipped.

**2. Hang culprit** (`implement`, effort low; can run alongside 3)
- Add `.hostOnly` to `LeoChatCopyTests`.
- **Verify:** command A with the filter `LeoChatCopyTests`. Tier off: skipped in about 0 s. Tier on, on the dev box: passes.

**3. Crash culprit: sheet presenter seam** (`implement`, effort medium; can run alongside 2)
- **Reproduce first:** run command A with the filter `LeoEnvironmentActionsTests` with another app frontmost. If it doesn't reproduce locally, write that down and go ahead anyway; the seam removes the window dependency regardless.
- **Failing test first:** a test that calls `escapeClosesTheEditOrderSheet` through an injected recording presenter. It expects one present and one dismiss and an empty `daemon.calls`. It fails until the seam exists.
- Convert all 5+ sheet cases in the file. Keep one end-to-end `beginSheet` case as `.hostOnly`.
- **Verify:** command A (filter `LeoEnvironmentActionsTests`), tier off then tier on.

**4. Hosted workflow** (`implement`, effort low; can run alongside 2 and 3)
- Run `git checkout origin/ci/hosted-runner-bench -- .github/workflows/leo-ci-hosted-bench.yml`.
- Retarget the `push` trigger to `ci/portable-tests` and keep `workflow_dispatch`.
- Upload `leo-tests.log` with `if: always()`.
- Add a final step that writes the cache hits and each step's duration to `$GITHUB_STEP_SUMMARY`, using the existing "Cache report" values plus `date +%s` marks.
- Leave `LEO_HOST_TESTS` unset.
- **Verify:** `actionlint` on the file. The hosted run itself happens at step 5.

**5. Hosted wave 2** (orchestrator, after steps 1–4 are merged on the branch)
- Push the branch; this needs your approved push. Run E.
- Classify every W2 row from the log as OK or failing. Failures become batch B4 in the same P/H style.
- **Expected:** no hang (`LeoChatCopyTests` skipped) and no crash. The six known failures are only fixed by B1–B3, which can run before this step.

**B1. Sheet suites** (`implement`, effort medium; after 3)
- Files: `LeoAgentMenuSheetTests`, `LeoNewAgentMenuSheetTests`, `LeoSpawnAgentSheetPresenterTests`, plus their production sheet-presentation call sites.
- **Failing test:** `deletePresentsItsSheetOnATerminalWindowAndAsksTheFakeDaemonForItsPlan` rewritten against the recording presenter. It fails before the call site takes the seam.
- **Verify:** command A on those 3 suites.

**B2. Host-only moves** (`implement`, effort low; mechanical; parallel with 3, B1 and B3)
- Add `.hostOnly` to every row marked B2. Remove the redundant `hasGhostty` gates in those files.
- **Verify:** command B lists each B2 suite as skipped. Command C runs them and they pass.
- This is a pure test-metadata change: no failing test is needed. Write that in the commit.

**B3. Screen frame injection** (`implement`, effort medium; parallel with B1 and B2)
- Files: `LeoFirstAttachWindowSizeTests` and the first-content sizing helper in `macos/Sources` that it exercises. The implementer finds it from `applyFirstContentSize`.
- **Failing test:** `aNarrowConfiguredTerminalOpensWideEnoughForTheStoredSidebar` as pure size math, with an injected 1024×768 `visibleFrame`, asserting the sidebar keeps its stored width (±1 pt). This reproduces the hosted 8 pt clamp.
- Cases that need `fill()` get `.hostOnly`.
- **Verify:** command A on that suite.

**B4. Wave 2 fixes** (`implement`, effort depends on findings; split into passes of 2–6 files with no file overlap)
- Each failing test is the hosted failure from step 5, reproduced locally where possible.

**6. Keep host coverage, write the docs** (`implement`, effort low; after B2)
- In `leo-ci.yml`'s self-hosted `test-macos` job, set `env: LEO_HOST_TESTS: "1"` so the self-hosted runner keeps running the host tier until it retires. The runner swap itself remains separate, as the spec says. This step also meets acceptance item 2.
- Create `macos/Tests/README.md`, about 25 lines: the portable rule, when to use `.hostOnly`, and commands C and D.

**7. Acceptance runs** (orchestrator)
- **Hosted:** three green runs in a row on one SHA. Clear this branch's caches before the first so it starts cold, then `gh run rerun` twice for the warm runs. Record the summary timings.
- **Self-hosted:** run D, or `leo-ci.yml` on the branch with the host tier on. Every H file must run and pass.
- Then the review gate runs on `git diff main...HEAD`, at a P1 bar: anything that hangs, crashes or drops coverage.

## Parallelism

- **Step 1 runs alone first.** Every later step depends on the trait.
- **Then steps 2, 3, 4, B2 and B3 can run in parallel.** No two of them touch the same file. B2 must not touch `LeoChatCopyTests`, `LeoEnvironmentActionsTests` or `LeoFirstAttachWindowSizeTests`.
- **B1 runs after step 3**, because it uses the seam step 3 creates.
- **Step 6 runs after B2. Step 5 runs after 1–4. B4 runs after step 5.**
- **Don't run more than 2 xcodebuild runs at once.** The `heavy` queue only runs 2. Each implementer runs only its own filtered suites; the full suite runs only in steps 5 and 7.

## Commands

All of these run from the repo root with `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`.

- **A. Targeted:** `heavy xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/dd-pct -skipMacroValidation CODE_SIGNING_ALLOWED=NO -only-testing:GhosttyTests/<Suite>`
  - Add `TEST_RUNNER_LEO_HOST_TESTS=1` in front for tier on; xcodebuild forwards `TEST_RUNNER_`-prefixed variables into the test process.
  - If `xcodebuild test` hangs on a locked console, run B or C instead.
- **B. Local run simulating hosted** (host tier off, which is the only path CI takes now that the window-server gate is gone): `DERIVED_DATA=/tmp/dd-pct LOG=/tmp/pct-off.log heavy .github/scripts/leo/run-unit-tests.sh`
  - Run it with another app frontmost so any focus dependency that isn't gated shows up the way it does on hosted.
  - It can't reproduce hosted's screen and titlebar metrics. E is the authority for those.
- **C. Host tier, local:** `LEO_HOST_TESTS=1 DERIVED_DATA=/tmp/dd-pct LOG=/tmp/pct-on.log heavy .github/scripts/leo/run-unit-tests.sh`
- **D. Self-hosted host tier:** C on the self-hosted runner, or the `leo-ci.yml` run once step 6 is in.
- **E. Hosted:** `workflow_dispatch` only works once the workflow file is on `main`, so on this branch the push is what triggers it.
  - Push `ci/portable-tests`.
  - Watch it: `gh -R blackpaw-studio/leoterm run list -w leo-ci-hosted-bench.yml -b ci/portable-tests`, then `gh -R blackpaw-studio/leoterm run watch <id>`.
  - Warm reruns: `gh -R blackpaw-studio/leoterm run rerun <id>`.
  - After the workflow reaches `main`: `gh -R blackpaw-studio/leoterm workflow run leo-ci-hosted-bench.yml --ref ci/portable-tests`.
  - Cold start: `gh -R blackpaw-studio/leoterm cache list --ref refs/heads/ci/portable-tests`, then delete only those keys. This is destructive to caches, so confirm first.
- **Scripts:** `.github/scripts/leo/run-tests.sh`

## Out of scope (follow-ups)

Moving `leo-ci.yml` and the other `leo-*` workflows off self-hosted runners, rewriting the `Task.sleep` and `awaitCondition` waits (53 files use wait helpers), the iOS suite, and running the host tier in the release workflow.
