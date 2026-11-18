# Leo test suite speed and prune plan (2026-11-18)

**Spec (from the brief):** make the Mac unit-test step (`run-unit-tests.sh`, 900 s timeout) fast at the cause. Prune duplicate and low-value tests across Mac, LeoKit and iOS. Don't raise the timeout. House rules apply: test behaviour through public interfaces, no trivial tests, no real sleeps, mock only at boundaries.

## 0. Baseline and data
- Passing run 44350273062 (main 40086a9ed) had 5,047 tests in 527 suites and took **760.2 s**. LeoKit ran separately: 1,939 tests in 5.8 s, which isn't the problem.
- Passing runs upload no `leo-test-log` artifact (only failures do), so per-test timings come from the failing run 44317626451. That runner was slower: 4,493 tests completed, summing to 887 s, before it was killed inside `LeoWKBrowserPageTests`.
- Parsed timings are in `/private/tmp/claude-501/-Users-evan--leo-agents-leoterm/f3c0cdfe-1004-4739-93b2-0f7501408f3f/scratchpad/test-timings.tsv` (suite, seconds, test).
- **Shape of the cost.** 483 tests at ≥0.3 s account for 793 of the 887 s. The 25 slowest suites account for 636 s. The remaining ~4,000 tests together cost about 94 s. The time is in tests that build windows or surfaces, not in the long tail.
- **Execution is effectively serial.** At most 2 suites were ever open at once. Nearly every slow suite is `@MainActor`, often `.serialized`.
- **`LeoAppEventQueueTests` (76 s) is not a separate cost.** It is a `.serialized` container (`LeoSidebarCommandClickTests.swift:10`) holding `LeoSplitViewRepresentableTests` (74 s) and `LeoSidebarCommandClickTests` (2 s). Don't count it twice.
- The host tier (`.hostOnly`) is off in CI ("host tier: off", 180 skipped). The 15 s wait in `LeoTerminalRowMenuIntegrationTests:424` is therefore already skipped and saves nothing.

## 1. Timing table (failing-run seconds; per-case cost is ~15% lower on a normal runner)
| # | Suite | s | Dominant cause (evidence) |
|---|---|---|---|
| 1 | LeoTerminalRowsIntegrationTests | 149.4 | Each test builds a real `TerminalController` and Ghostty surface (`makeFixture` :56). `newShell()` with no command spawns the default login shell (:108). `closingTabsAsksForABusyHiddenShell` takes 27.5 s over 3 cases: two fixtures each, tab group, sheet wait `eventually(10s)` :1385. Fixed negative sleeps of 100–200 ms at :218 :246 :296 :396 :422 :475 :521 :663 :940 :958 :1175 :1241 :1388. |
| 2 | LeoSplitViewRepresentableTests | 74.4 | `resizeWindow(stepwiseTo:step:)` :991 steps 5 pt at a time with a main-queue hop and full layout per step (~33 ms per step). About 1,300 steps across `besideTheEditorAlone…` (9 cases, 16.2 s, :406), `wideningBack…` (8.3 s), `aSidebarTheUserHidStaysHidden` (7.9 s), `narrowingFurther…` (5.5 s), `theSqueezedEditor…` (3 s). |
| 3 | LeoSidebarTitlebarStyleTests | 49.4 | 10 tests × 4 styles, about 40 fixtures. Each writes a config and builds a **new `Ghostty.App`** (`StyleConfig.app` :328–337), then a window, toolbar and header probe (`settledHeader` :384, 200 ms re-probe). |
| 4 | LeoTerminalRowMenuIntegrationTests | 48.1 | Real `/bin/cat` surfaces. `closeFromMenuOnABusyRowAsks` takes 11.75 s over 2 cases (waits for `needsConfirmQuit`, then a 150 ms negative sleep at :355). |
| 5 | LeoTerminalControllerEditorCloseTests (Editor/) | 39.8 | `aCloseThatCantAskKeepsATabWithUnsavedEdits` takes 16.3 s. Each iteration shows and activates a placeholder window (`leoNewPlaceholderWindow`, `TerminalController.swift:98–127`) and does real sandbox file I/O. **Where the time goes is unexplained; trace it.** |
| 6 | LeoLaunchPlaceholderIntegrationTests | 37.6 | Shown windows with real surfaces and a 30 s `settleTimeout` (:32). Needs a trace. |
| 7 | LeoCrossWindowMoveTests | 24.9 | Two windows per test with real surfaces, plus undo/redo moves. |
| 8 | LeoLivePoolIntegrationTests | 24.7 | Real `/bin/cat` agents. Negative sleeps at :108 :166 :196 :275. |
| 9 | LeoSidebarTerminalScrollTests | 23.2 | A window per test with 40 agents and 6 terminals. Waits are counted turns (:619), not wall time. |
| 10 | LeoTextCleanerMatcherTests | 16.8 | A 4,000-run random corpus (:110) checked against a reference matcher that runs from every scalar (:117, :129). |
| 11 | LeoRowSplitIntoShellTests | 16.7 | `/bin/sh -c 'pwd -P > cwd.txt; exec cat'` per test, with file polling (:64, :97). |
| 12 | LeoAgentBrowserTests | 16.1 | A WKWebView per test. Loops exit early. |
| 13 | LeoSidebarHeaderLayoutTests | 12.7 | `buttonBarSitsBelowTheList…` takes 9 s over 8 cases (2 widths × 4 connectivity values), one window each (:99, :132). |
| 14 | LeoTitleIntegrationTests | 11.7 | Fixed `Task.sleep(250ms)` at :45 and a poll loop with no deadline (:49). |
| 15 | LeoReplacedLaunchWindowReleaseTests | 11.1 | Window release waits (30 s caps at :50 and :53, on the pass path). Needs a trace. |
| 16 | LeoFirstAttachWindowSizeTests | 10.9 | Window per test. |
| 17 | LeoSyntaxHighlighterAdversarialTests | 10.7 | `everyAttackOnLinesAtTheLimit…` (:75) builds **4** lines of 4,096 × 52 units × 3 languages, run through two matchers. |
| 18 | LeoSidebarContentMinimumTests | 10.7 | Window per test, stepped resizes. |
| 19 | LeoSettingsWindowEntryTests | 10.7 | Settings window per test. |
| 20 | LeoBrowserFindScriptTests | 9.2 | `scrollsAMatchDeep…` builds a 3,200-line `<pre>` (:12–16), 6.1 s. |
| 21 | LeoRowPaneCloseTests / LeoRowLayoutKeepTests | 7.5 / 7.4 | Real shells in `LeoRowLayoutFixture` (`eventually` 5 s at :176). One test waits for a real login-shell prompt (:107). |
| 22 | LeoTerminalRestoreIntegrationTests | 6.8 | Window and surface restore. |
| 23 | LeoSidebarFeedDispatchTests | 6.7 | Per-file copy of the `pump`/`until` helpers. Fine individually. |
| 24 | LeoRuntimeManagedStartTests | 6.6 | 43 tests at ~0.15 s each. Acceptable. |
| 25 | LeoTunnelLifecycleTests | 6.5 | `onExitFires…` (4.5 s) starts `/usr/bin/python3` as a fake ssh (`LeoTunnelTestSupport.swift:13`). |

**Cross-cutting.** There are about 30 copies of `eventually`, `waitUntil`, `pump` and `nextTurn` across `macos/Tests/Leo`, plus 7 in iOS. `LeoTestSupport.swift:6 awaitCondition` is the only shared one. Polling helpers cost nothing on a pass, but every **fixed negative sleep** always costs its full duration.

## 2. Speed fixes (seconds are failing-runner estimates)
**S1. Measure fixture cost first (Lane A, step 1).**
- Add a temporary `ContinuousClock` phase trace to four fixtures: `LeoTerminalRowsIntegrationTests.makeFixture`/`close`, `LeoRowLayoutFixture`, the Editor-close `makeTab`/`tearDown`, and `LaunchPlaceholder` setup.
- Run the 5 slowest tests locally and record build, first frame, sheet, close and release times.
- Decide S2–S4 from the numbers. Remove the trace before committing.

**S2. Turn off window, sheet and resize animation in the test host.** Pass `-NSAutomaticWindowAnimationsEnabled NO -NSWindowResizeTime 0.001` in the injected argv in `run-unit-tests.sh`, and mirror it for local runs, e.g. a `TEST_RUNNER_` env or a test-bundle load hook. Every window test pays for these animations on open, close and sheet. Estimate **20–60 s** across ~400 window tests; confirm with S1.

**S3. Stop spawning login shells where no prompt is asserted.**
- Change the default of `newShell()` (RowsIntegration :108) and the `LeoRowLayoutFixture` shell to `/bin/cat`, and replace the python fake ssh with `/bin/sh`.
- Keep a real shell only where the test asserts shell-integration behaviour.
- Estimate **10–30 s** plus 2–3 s for the tunnel test.

**S4. Replace negative sleeps with a deterministic barrier.**
- Add `drainMainQueue(turns:)` to `LeoTestSupport.swift`: a counted-turns helper like the existing `turnsUntil`/`nextTurn`.
- Use it in place of `Task.sleep` at the sites listed in rows 1, 4, 8 and 14.
- Estimate **3–5 s**. It also removes timing flakiness.

**S5. Split view: 40 pt steps.**
- Default `Harness.resizeStep` to 40 and add `step: 40` to the five stepwise tests.
- Keep exactly one 5 pt live-resize case per behaviour family: floor-holds, widen-back and oscillation (`jigglingAtTheCollapseEdge` stays at 5 pt).
- Turn the 3×3 argument cross-product at :406 into explicit pairs (see the prune list).
- Estimate **30–35 s**. Check that the collapse assertions hold at 40 pt; that is the B-023 regression.

**S6. Titlebar: one `Ghostty.App` per style.**
- Cache it in a `@MainActor static` dictionary, so the suite builds 4 instead of ~40.
- Fold the read-only per-style asserts (`everyStyleOpens…`, `theUpdatePill…`, toolbar order) into one test per style that reuses one fixture.
- Estimate **25–30 s**.

**S7. Shrink oversized data while keeping the property provable.**
- Syntax adversarial: 1 line at the 4,096 limit instead of 4 (~7 s).
- TextCleaner: corpus 4,000 → 1,000 runs, scaling the `> 30000` assertion at :121 (~5 s).
- FindScript: 3,200 → 400 lines, still more than 10 viewports (~3–4 s).

**S8. Editor-close and LaunchPlaceholder.** Apply S1's finding. If the time is the shown and activated placeholder, inject a non-activating presenter into the test or reuse one window across iterations. Estimate **10–20 s** (unverified).

## 3. Prune list (high/medium confidence; seconds = CI time saved)
| Target | Suite | Test | Reason | Conf | s |
|---|---|---|---|---|---|
| Mac | LeoSplitViewRepresentableTests:406 | besideTheEditorAlone… 9 cases → 3 (one 5 pt path, one 40 pt path, one jump) | shrink-params; B-023 stays covered | high | ~11 |
| Mac | LeoSplitViewRepresentableTests:1035 | aPreviewKeepsThePanesWidths png/pdf/bin → one non-movie case | shrink-params; same split path; movie case stays (B-278) | med | ~3 |
| Mac | LeoTerminalRowsIntegrationTests:1356 | closingTabsAsksForABusyHiddenShell, drop the "Close Other Tabs" case | shrink-params; the two kept cases cover acting==closing and acting≠closing; B-057 kept | med | ~9 |
| Mac | LeoTerminalRowsIntegrationTests:452 | closingATerminalTwiceIsHarmless, drop the `shown` case | shrink-params; keep hidden + hidden-after-exit (B-057) | med | ~2 |
| Mac | LeoTerminalRowMenuIntegrationTests:336 | closeFromMenuOnABusyRowAsks, drop the `hidden` case | covered-by `closeFromMenuOnAHiddenBusyRowClosesOnceConfirmed` :362 | med | ~6 |
| Mac | LeoSidebarHeaderLayoutTests:99 | buttonBarSitsBelowTheList… 8 → 2 (one connectivity per width) | shrink-params | med | ~6.5 |
| Mac | LeoSidebarHeaderLayoutTests:120 | sidebarChromeMetricsAreTheSingleSourceOfSpacing | trivial (relations between constants) | med | <0.1 |
| Mac | LeoRowSplitIntoShellTests:200 | rowMenuSplitGoesStraightToAShell | covered-by :22 `commandDOnATerminalRowSplits…`; keep only if the menu entry has its own routing (check the menu action calls the same method) | med | 2.6 |
| Mac | LeoSidebarTitlebarStyleTests | everyStyleOpensALeoAgentWindow ×4 | folded into the per-style test (S6); the type check is implied by the other asserts | high | ~5 |
| LeoKit | LeoDaemonVersionTests:40 | exposesComponents | trivial getters; implied by the parse tests | med | – |
| LeoKit | LeoStatsStyleTests:6 / :18 | capsulesIsTheDefault + unknownStoredValueFallsBack… → keep :18 | duplicate | med | – |
| LeoKit | LeoStatsStyleTests:11 | storedValueRoundTripsEveryStyle | trivial unless the key is persisted (check; keep if it is a UserDefaults key) | med | – |
| LeoKit | LeoPluginNodeDecodingTests:124 | roundTrips | duplicate-of :258 textRoundTrips | med | – |
| LeoKit | LeoPluginBridgeTests:53 | slotIDsRoundTripAndHaveDistinctKeys, round-trip half | duplicate-of LeoPluginWireTests:76; keep the distinct-keys assert | med | – |
| LeoKit | LeoFakeServiceTests:61, :68; LeoFakeConfigClientTests:354, :361, :374; LeoFakeDelegationTests:238 | fake bookkeeping | tests the test double, not the product. Keep the fake tests that pin daemon 409/422/428 contract | med | – |
| LeoKit | LeoFakeConfigClientTests:96 | aMissingIfMatchIsRevisionRequired | duplicate-of LeoConfigClientTests:160 | med | – |
| iOS | LeoFeaturesTests/ConfigSingletonTests:56 | clientDefaultHostPicksFromHosts | duplicate-of LeoKit LeoDaemonPaneTests:12 | med | – |
| iOS | LeoFeaturesTests/AgentDisplayNameTests:6 | anObservedAgentCarriesItsDisplayName… | duplicate-of LeoKit LeoAgentDisplayNameTests | med | – |

**No whole suite was found redundant** by the first sampled audit, which covered about 40% of the Mac Leo files. Each lane below finishes a **full-read audit of its own files** using these criteria:
- duplicate (name the kept test);
- trivial getter or wiring;
- guaranteed by the type checker;
- covered by a cheaper or higher-level test;
- parameter cross-products that prove one property.

Keep any test whose introducing commit (`git log -S'<name>' --format='%h %s' -- <file> | tail -1`) is a fix or B-xxx regression, unless an identical assertion survives elsewhere. Each lane reports its prunes as a table like the one above in its commit body.

## 4. Lanes (disjoint files; A, B and C run in parallel; D runs after they merge)
**Lane A: terminal and window integration plus test-host animation (`implement`, high effort).**
- Files:
  - `.github/scripts/leo/run-unit-tests.sh`
  - `macos/Tests/Leo/LeoTestSupport.swift`
  - `LeoTerminalRowsIntegrationTests`, `LeoTerminalRowMenuIntegrationTests`, `LeoLivePoolIntegrationTests`, `LeoTitleIntegrationTests`, `LeoRowSplitIntoShellTests`
  - `LeoRowLayoutFixture`, `LeoRowLayoutKeepTests`, `LeoRowPaneCloseTests`
  - `LeoLaunchPlaceholderIntegrationTests`, `LeoReplacedLaunchWindowReleaseTests`, `LeoCrossWindowMoveTests`, `LeoContentSwapIntegrationTests`, `LeoCloseConfirmationIntegrationTests`, `LeoTerminalRestoreIntegrationTests`
  - everything in `macos/Tests/Leo/Editor/`
- Steps:
  1. S1 trace, recording numbers in the commit body.
  2. S2: the animation argv in the script plus the local-run mechanism. Re-time the 5 slowest tests.
  3. S3 shells.
  4. S4: add `drainMainQueue` and replace the negative sleeps in the owned files.
  5. S8.
  6. Lane A rows of the prune table.
  7. Full-read audit of `Editor/` and the owned files.
- Verify each suite:
  ```
  cd macos && DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/dd-a -skipMacroValidation -packageAuthorizationProvider netrc CODE_SIGNING_ALLOWED=NO -only-testing:GhosttyTests/<Suite>
  ```
  Run more than two suites at once, or the whole lane, under `heavy` in the background.
- Run each touched suite 3× to check flakiness. Record the before and after seconds.

**Lane B: layout and chrome (`implement`, medium effort).**
- Files: `LeoSplitViewRepresentableTests`, `LeoSidebarTitlebarStyleTests`, `LeoSidebarHeaderLayoutTests`, `LeoSidebarTerminalScrollTests`, `LeoSidebarContentMinimumTests`, `LeoFirstAttachWindowSizeTests`, `LeoSettingsWindowEntryTests`, `LeoSidebarOffscreenAttentionScrollTests`, `LeoToolbarInsetTests`, `LeoSidebarCommandClickTests`.
- Steps:
  1. S5, S6 and the Lane B prune rows.
  2. Full-read audit of every top-level `macos/Tests/Leo/LeoS*`–`Z*` file not owned by Lane A.
- Verify: the same command with `-derivedDataPath /tmp/dd-b`, suites `LeoAppEventQueueTests` (which contains the split view), `LeoSidebarTitlebarStyleTests`, `LeoSidebarHeaderLayoutTests`, and so on. Run each 3×.

**Lane C: logic, browser, LeoKit, iOS (`implement`, medium effort).**
- Files:
  - `LeoSyntaxHighlighterAdversarialTests`, `LeoTextCleanerMatcherTests`, `LeoBrowserFindScriptTests`
  - `LeoTunnelTestSupport.swift` and `LeoTunnelLifecycleTests`
  - all of `Packages/LeoKit/Tests/`, `ios/LeoTests/` and `ios/LeoFeatures/Tests/`
- Steps:
  1. S7 and the tunnel fake.
  2. LeoKit and iOS prune rows.
  3. Replace the ~25 `Task.yield()` settle loops in LeoKit and iOS (list in the audit: LeoPluginManagerTests:93, LeoClientToolsSessionTests:246–458, LeoBrowserExecutorTests:717–807, LeoTerminalAttachTests:65 and :208, and others) with `awaitCondition` on the real condition.
  4. Merge the 7 iOS 5 ms poll copies into one test-support helper per target.
  5. Full-read audit of top-level `macos/Tests/Leo/A*`–`LeoR*` and all `macos/Tests/Leo` subdirectories except `Editor/` that Lane A doesn't own.
- Verify:
  - LeoKit: `cd Packages/LeoKit && swift test` (fast, no `heavy`).
  - iOS: the repo's iOS test command, `xcodebuild test` for LeoFeatures and the Leo scheme on an iOS simulator.
  - Mac suites: the same command with `-derivedDataPath /tmp/dd-c`.

**Lane D (after A, B and C merge; `implement`, low effort): helper consolidation.**
- Move the ~30 copies of `eventually`, `waitUntil`, `pump` and `nextTurn` in `macos/Tests/Leo` onto the `LeoTestSupport.swift` helpers (`awaitCondition(timeout:)`, `turnsUntil`, `drainMainQueue`).
- This removes drift, not time. It's sequenced last because it touches every lane's files.

**Integration gate (orchestrator).**
- Run the full `run-unit-tests.sh` locally under `heavy`, then push a branch and read the CI "Unit tests" time.
- Fresh-context `review` of each lane's diff. Severity bar: any lost regression coverage, or a new flake, is P1.

## 5. Expected end state and risk
- **Savings (failing-runner seconds):**
  - S5 + S6: 55–65
  - S2 + S3: 30–90 (S1 decides)
  - S8: 10–20
  - S7: 15
  - S4: 3–5
  - prunes: ~45, some overlapping S5/S6
  - Net: about **150–250 s**.
- **Target:** "Unit tests" at **≤ 550 s** on a normal hosted runner (from 760), and ≤ 650 s on the slow runner that hit 900. Test count drops by about 40–80 cases, plus whatever the lane audits remove.
- **If CI is still above 600 s after the merge**, the next lever is structural: shard the injected run into two Leo processes split by suite. That needs per-process defaults and single-instance isolation, so it is a separate decision for Evan, not this plan.
- **Risks:**
  1. S2/S3 estimates are unmeasured until S1 runs. If animation and shell turn out not to dominate, the target slips by about 50 s.
  2. 40 pt steps could hide a collapse-edge bug that only 5 pt stepping shows. One 5 pt case per family plus `jigglingAtTheCollapseEdge` stay as the guard.
  3. Shared `Ghostty.App` per style lets state leak between tests. Fixtures still build a fresh controller and window each time.
  4. The audits read only test code. A test that looks duplicated may guard a different production path; the git-log rule covers the known cases.
  5. Doc drift: `macos/Tests/README.md` says `test-macos` sets `LEO_HOST_TESTS=1`, but CI runs with the host tier off. Fix the README in Lane A.
