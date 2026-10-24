# Plan: iOS Settings (phone essentials)

Spec: `docs/superpowers/specs/2026-10-24-ios-settings.md`. It is the source of truth when this plan disagrees with it.
Parent spec: `2026-10-23-in-app-settings.md`. Mac plan: `docs/plans/2026-10-23-in-app-settings.md`.
Branch: `feat/ios-settings` (off `main`). No daemon work: leo 0.59.0 already serves the config API on `/api/v1`.

**Platform call.**
- **Both (K1–K4).** Logic leaves the Mac models for LeoKit. The Mac's behavior does not change, and its existing tests are the safety net.
- **iOS only (I1–I7).** The iOS app gets UI and TCA reducers. The Mac gains no feature.

---

## 0. Conventions

### Commands
- **LK(S):** `cd Packages/LeoKit && DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer swift test --filter 'S'`
- **LKL:** `cd Packages/LeoKit && swiftlint lint --strict`
- **F(S):** `cd ios/LeoFeatures && DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer swift test --filter 'S'`
  - LeoFeatures is UIKit-free, so every reducer test runs on macOS with `swift test`. CI does the same.
- **MB / MT(S…) / ML:** the same as Mac plan B0, on Xcode 26.3.
  - MT runs from `macos/` as `-only-testing:GhosttyTests/<S>`.
  - Worktree prereq, once: `ln -s ~/.leo/agents/leoterm/macos/GhosttyKit.xcframework macos/GhosttyKit.xcframework && ln -s ~/.leo/agents/leoterm/zig-out zig-out`.
  - When the console is locked, use the injected-bundle runner in `LEO.md`.
- **IB:** `cd ios && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer xcodebuild build-for-testing -project Leo.xcodeproj -scheme Leo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DD-ios CODE_SIGNING_ALLOWED=NO`
  - Use Xcode 26.5. Xcode 27 crashes on this code.
  - Commit `Leo.xcodeproj` whenever `project.yml` changes. CI fails on drift.
- **IT(T/S):** the same flags with `test-without-building -only-testing:<T>/<S>`. `T` is `LeoTests` (new, I2) or `LeoUITests`.
- **ISHOT:** `TEST_RUNNER_LEO_SCREENSHOTS=<scratch>/shots` + IT(LeoUITests/LeoSettingsScreensTests).
  - It writes light and dark PNGs. Inspect them at native pixels. The orchestrator posts them to Evan with `leo_chat_post`.

### Discipline
- **Test first.** Write the test, watch it fail, then implement. UIKit layout and styling are TDD-exempt and are verified by ISHOT.
- **Load.** Check `uptime` before any full run. It was ~39 when this plan was written. Above ~30, run only the targeted commands and defer the full suites to the gate.
- **Implementers.** Use Claude-backed `implement` dispatches for any step that runs xcodebuild. Codex cannot write the SwiftPM cache.
- **Swift Testing.** In the new hosted bundle, never give a suite a SuiteTrait-only trait: it crashes the host at discovery.
- **Review.** Each step commits, and each slice (K, I1–I3, I4–I5, I6–I7) gets a fresh-context `review`.
  - Bar: P0/P1, plus anything a realistic edit, network blip or restart can hit.
  - `review.concurrency` takes K1 and K3, since they cover revisions and the restart wait.

### Facts about the iOS test setup
- **Test targets today:**
  - LeoFeatures `swift test`: Swift Testing + TCA `TestStore`, with `DependenciesTestSupport`.
  - The app scheme's `LeoUITests` (XCUITest).
  - There is **no hosted unit-test bundle** for the app target. I2 adds `LeoTests`.
- **Snapshot harness: none.** There is no swift-snapshot-testing dependency and no image diffing.
  - The established pattern is a DEBUG launch-argument fixture plus a UI test that writes PNGs to `TEST_RUNNER_LEO_SCREENSHOTS`.
  - Examples: `-machinesFixture` with `LeoMachinesTests`, `LeoQuestionsCardTests` and `LeoE2ETests`. I7 follows it.
- **Keychain.** Pairing needs a **signed** simulator build (ad hoc is enough). A `CODE_SIGNING_ALLOWED=NO` build fails with "A required entitlement is not present" (Machines S11 gate). Only the real-daemon check needs this.
- **xcode-remote.** It runs a simulator build on Evan's laptop. It is optional, for his own look; every check in this plan runs on this host's iPhone 17 Pro simulator.

---

## 1. What moves into LeoKit, and how iOS avoids each Mac P1

LeoKit stays plain Swift, with no TCA, because the AppKit app consumes it.

The shape is a **functional core**:
- **value-type state with pure transitions**, which the Mac `ObservableObject`s and the iOS reducers both hold;
- **`async` operation functions** over `any LeoConfigClient` that return value outcomes. The Mac shell awaits them inline. The TCA shell runs them in `.run` effects and feeds the outcome back as an action.

Already shared, and used as-is: models, `LeoConfigHTTPClient`, `LeoWebDaemonClient.configClient()`, `LeoConfigDraft`, `LeoConfigValidator`, `LeoConfigFormLayout`, `LeoConfigRevisionTracker`, `LeoCronPreviewer`, `LeoFakeConfigClient`, and `LeoServiceStatus.isRestarted(since:)` / `runningAgentCount`.

### How iOS avoids each Mac P1

**1. Whole-map/list replay** (b9de0fc4d, e142299ed)
- Shared fix: `LeoConfigDraft.patch` / `rebased(onto:)`, already in LeoKit.
- iOS test (`ConfigCollectionTests`):
  - `saveSendsOneEnvEntry`
  - `reloadKeepsTheirSetListEntry`
  - `orderedListReplaysWhole`

**2. Overwrite clobbered another writer's changes** (b23339f9a)
- Shared fix moves to LeoKit (K1): `LeoConfigCollectionOps.overwrite`. It re-reads the item, rebases, sends only when still dirty, and uses the fresh revision.
- iOS test:
  - `overwriteReplaysOverFreshRead`
  - `overwriteSendsNothingWhenTheirsHasMine`

**3. A toggle retry rebased a dirty draft** (e921d465e, 3e160b026)
- Shared fix moves to LeoKit (K1): `LeoConfigCollectionOps.write(retryingConflict:)`. It returns `sentWith`, and the draft is rebased only when `resolve(draft.revision) == sentWith`.
- iOS test (`TaskSettingsTests`):
  - `toggleRetryKeepsDirtyFormOnItsRevision`
  - `secondToggleAfterRetryStillConflicts`

**4. A prompt save landed in the wrong file** (e921d465e)
- Shared fix moves to LeoKit (K2): the decisions on `LeoTaskPromptState`. Before a save it checks the configured file. After a 409 it re-reads which file is served. A form Save that repoints `prompt_file` asks first.
- iOS test:
  - `promptSaveRefusedWhenFileMoved`
  - `prompt409ReReadsServedFile`
  - `formSaveRepointingPromptAsks`

**5. Alert dismiss order** (f8d1ef671, 3e160b026)
- This one is not shared, because it is SwiftUI-specific. On iOS, every `AlertState` / `ConfirmationDialogState` button carries its own payload (`.confirmDelete(name)`, `.leave(.discard)`, `.restart(.agents(count))`). The handler reads only that payload, never `state.alert`, which `ifLet(\.$alert)` has already cleared.
- iOS test: `confirmActsOnAlertPayload`. The test sends the presented action and asserts the write happened and the alert is nil.

**6. Restart drain timeout** (204ec3db7)
- Shared fix moves to LeoKit (K3): `LeoRestartWait`, a pure state machine.
  - It has a 12-minute wall-clock deadline.
  - Only unreachable polls count toward the 60-poll limit.
  - A same-process poll means "waiting for busy agents".
- iOS test (`MachineRestartTests`, with `TestClock` and a controlled `date`):
  - `drainPollsDontSpendBudget`
  - `deadlineGivesUpWithAgentsMessage`
  - `unreachableBudgetGivesUp`

**Also carried over from the Mac review rounds:**
- A reconnect must not drop a dirty pane (0dd975c7f). Test: `disconnectKeepsPaneAndDraft`.
- Run Now must ignore a second press (e921d465e). Test: `runNowIgnoresSecondPress`.

---

## Part K — LeoKit extraction (both platforms; the Mac's behavior is unchanged)

### K1. Collection core
**New files in `Packages/LeoKit/Sources/LeoKit/Config/Panes/`**

**`LeoConfigCollectionState.swift`** (`Equatable, Sendable`)
- **What it holds:** everything `LeoConfigCollectionModel` publishes or keeps privately:
  - `phase`, `items`, `selection`, `draft`, `conflict`, `restartPrompt`, `warning`, `errorMessage`, `confirmation`, `isBusy`;
  - `schema`, `webDocument`, `references`, `revision`;
  - `resourceKey`, `machineHost`, and `webOrigin: URL?` (K4).
- **`autoSelectsFirst: Bool`.** The Mac passes `true`. iOS passes `false`, because selecting an item pushes a screen.
- **Derived:**
  - `title`, `actions`, `isDirty`, `hasUnsavedChanges(extra:)`;
  - `canSave`, `canRestructure`, `sections`, `webLink`;
  - `nameError(_:excluding:)`, `validator`.
- **Pure transitions (the bodies of the Mac methods):**
  - `apply(_:preferring:carrying:rebasing:)`
  - `requestSelect(_:extraUnsaved:)` → sets `.discardChanges(thenSelect:)` or selects
  - `selectNow`, `set`, `revert`, `revertAll`
  - `beginWrite() -> Bool`
  - `finishWrite(_ outcome:)`, which sets the conflict, warning and restart prompt
  - `failed(_:sent:)`, the old `handleSaveFailure`
  - `take(_ confirmation:) -> PendingAction`
- **Explicit targets.** `rename`, `duplicate` and `delete` take an explicit target name. The Mac passes `selection`. iOS passes the row the user acted on.

**`LeoConfigCollectionOps.swift`** (async, stateless)
- `load(resource:client:references:)` reads the schema, the web document, the references and the collection.
- `write(ifMatch:retryingConflict:draftRevision:revisions:operation:)`:
  - retries a conflict at most once;
  - records the write in the tracker using `sentWith`;
  - computes `draftWasCurrent`;
  - then re-reads the collection.
  - It returns `LeoConfigWriteOutcome {result, sentWith, draftWasCurrent, collection: Result}`.
- `overwrite(stale:resource:name:client:revisions:)` returns `.nothingToSend(replayed, collection)` or `.sent(replayed, outcome)`.

**Mac**
- `LeoConfigCollectionModel` holds one `@Published private(set) var state: LeoConfigCollectionState`.
- It keeps every current property and method as a forwarder, so views and tests don't change.
- `Confirmation` and `Conflict` become typealiases of the LeoKit types.

**Failing tests (new): `LeoConfigCollectionStateTests`**
- `applyCarriesDraftOnlyForSameItem`
- `applyWithoutRebasingKeepsDraftOnItsRevision`
- `iOSModeDoesNotAutoSelect`
- `selectWhileDirtyAsks`
- `failedConflictKeepsDraft`
- `failed422LandsOnField`
- `restructureNeedsCleanDraft`

**Failing tests (new): `LeoConfigCollectionOpsTests`** (against `LeoFakeConfigClient`)
- `retryOnceThenRecordsSentWith`
- `draftNotCurrentAfterRetry`
- `overwriteReplaysOverFreshRead`
- `overwriteNothingToSend`
- `restartRequiredSurfaces`

**Verify**
- LK(LeoConfigCollectionStateTests), LK(LeoConfigCollectionOpsTests), LKL.
- MB, then MT for: LeoConfigCollectionModelTests, LeoConfigCollectionConfirmationTests, LeoTasksSettingsModelTests, LeoEnvironmentsSettingsTests, LeoDaemonSettingsModelTests and LeoSettingsTargetModelTests.
- ML.
- **Every existing Mac test passes unmodified.** If a Mac test needs editing, stop and report it, because that means the behavior changed.

### K2. Tasks core
**Files**
- Move into LeoKit `Config/Panes/LeoTaskPaneState.swift`, from `macos/.../Tasks/LeoTasksSettingsState.swift`:
  - `LeoTasksLoad`
  - `LeoTaskRunNotice`
  - `LeoTaskPromptState`, made public.
- New pure decisions on `LeoTaskPromptState` (the bodies of the Mac methods):
  - `saveCheck(configuredFile:) -> .proceed | .askFileChanged`
  - `conflictOutcome(served:current:)`, which sets `.fileChanged` or `conflict`
  - `itemsChanged(configuredFile:) -> .none | .reload`
  - `formSaveAllowed(patch:) -> Bool`, which sets `.saveWithFile`
  - `saved(_:sent:)`
  - `discardEdits()`
- New `LeoTaskToggleOverrides`: the overrides and pending counts, plus `isEnabled(item)`.
- New `LeoTaskLog.tail(maxBytes:)`, the bounded tail for the log view (D9).

**Mac:** `LeoTasksSettingsModel` calls these. Its toggle `Task` chain stays in the Mac shell.

**Failing tests:** `LeoTaskPromptStateTests`
- `configuredFileMovedAsks`
- `conflictOnSameFileIsConflict`
- `conflictAfterFileMovedAsks`
- `formSaveRepointingWhileDirtyAsks`
- `cleanPromptFollowsNewFile`
- `toggleOverrideClearsAfterLastPending`
- `logTailKeepsLastBytesOnLineBoundary`

**Verify:** LK(LeoTaskPromptStateTests), MB, MT(LeoTasksSettingsModelTests, LeoTaskHistoryViewTests), LKL, ML.

### K3. Restart wait and service text
**Files**
- **New LeoKit `Config/Panes/LeoRestartWait.swift`:**
  - `init(previous:startedAt:deadline:maxUnreachablePolls:)`
  - `mutating func record(_ poll: Result<LeoServiceStatus, Error>, at: Date) -> Step`
  - `Step` is `.waiting(onAgents: Bool) | .restarted(LeoServiceStatus) | .gaveUp(afterDown: Bool)`.
  - A deadline check runs before each poll.
- **New `LeoServicePane` constants**, moved from the Mac model: `logLines` 200, `logInterval` 2 s, `restartPollInterval` 1 s, `defaultMaxRestartPolls` 60 and `defaultRestartDeadline` 12 min.
- **New `LeoServiceText`:** `agentsRestartMessage(running:)`, `summary(of:)`, `failureText(of:)` and the two give-up messages, each naming the machine.

**Mac:** `waitForRestart` becomes a loop over `LeoRestartWait`. `LeoRestartPrompt` and the Service view read `LeoServiceText`.

**Failing tests:** `LeoRestartWaitTests`
- `samePidPollsWaitOnAgentsWithoutSpendingBudget`
- `newPidRestarts`
- `downThenUpWithoutPreviousRestarts`
- `deadlineNeverDownGivesAgentsMessage`
- `unreachableLimitGivesUp`

**Verify:** LK(LeoRestartWaitTests), MB, MT(LeoServiceSettingsModelTests, LeoSettingsTargetModelTests), LKL, ML.

### K4. Web link via the paired origin
- **Change:** `LeoConfigWebLink.url(web:machineHost:resource:item:fallbackOrigin:)`. The order is `public_urls[0]`, then `fallbackOrigin`, then the bind address (the Mac's path, where `fallbackOrigin` is nil). See D6.
- **Failing test:** `LeoConfigWebLinkTests.pairedOriginBeatsBindWhenNoPublicURL`, `.disabledWebStillNoLink`.
- **Verify:** LK(LeoConfigWebLinkTests). Mac unchanged; MB only.

---

## Part I — iOS (UIKit + TCA)

- Reducers go in `ios/LeoFeatures/Sources/LeoFeatures/Features/Settings/`.
- View controllers go in `ios/Leo/Settings/Machine/`, next to the existing `SettingsViewController`.
- Navigation is tree-based, like `AgentDetail.destination`:
  - `@Presents var destination` with a `@Reducer enum Destination`;
  - `navigationDestination(item:)` and `present(item:)` from UIKitNavigation.

### I1. Machine detail, config clients, capability gate
**Dependency**
- `Dependencies/ConfigClients.swift`, a `@DependencyClient`.
- `client: (DaemonConnection) -> any LeoConfigClient`. The live value is `LeoWebDaemonClient(transport: LeoHTTPSTransport(…)).configClient()`.
- `revisions: (String) -> LeoConfigRevisionTracker`, one tracker per daemon id, kept in a locked dictionary.
- The test value is unimplemented. Tests inject a `LeoFakeConfigClient`.

**`MachineSettings` reducer**
- State:
  - `daemonID`, `name`, `baseURL`;
  - `session: DaemonSession`, which AppFeature keeps in sync after every `fleet` action;
  - `@Presents destination`: `templates`, `environments`, `tasks` or `service`;
  - `restart: MachineRestart.State` (I5).
- **Availability is derived from the session:**
  - connected with `config_api` in the hello features → the 4 rows;
  - connected without it → "Requires leo ≥ 0.59.0", from `LeoConfigAPI.minimumVersion`;
  - not connected → the Machines-style status and Reconnect, unless a pane is already open. An open pane is never dismissed.
- **Connection changes.** `.onChange(of: \.session.connection)` forwards `.machine(.connectionChanged(isConnected))` to the open destination.
- **Connection lookup.** The `DaemonConnection` comes from `pairedDaemons` + `secrets.connection(for:)`, as AppFeature does.

**Wiring**
- `Daemons.State.machine: MachineSettings.State?` (`@Presents`), with `Daemons.Action.machineTapped(id)`.
- AppFeature syncs `daemons.machine?.session` from `fleet.sessions` and forwards `scenePhaseChanged`.
- `DaemonsViewController`:
  - `shouldSelectItemAt` returns true, and rows get a disclosure accessory;
  - `didSelectItemAt` sends `.machineTapped`;
  - `navigationDestination(item:)` pushes the machine screen.
- `MachineSettingsViewController`:
  - an insetGrouped list: an info section that reuses `MachineCellConfiguration`, then the Configuration section;
  - accessibility ids `machine.config.<row>`.

**Failing tests** (F)
- `MachineSettingsTests`:
  - `rowsNeedConfigAPI`
  - `oldDaemonShowsRequires`
  - `disconnectedShowsStatusNotRequires`
  - `rowTapPresentsPane`
  - `disconnectKeepsOpenPane`
  - `reconnectForwardsToPane`
- `AppFeatureTests.machineSessionStaysInSync`

**Verify:** F(MachineSettingsTests), F(AppFeatureTests), IB.

### I2. Schema form cells, plus a hosted test bundle
- **`project.yml`:** add the target `LeoTests` (`bundle.unit-test`, iOS 26, `TEST_HOST` Leo) and add it to the `Leo` scheme's test targets. Run xcodegen and commit the project. CI's "App tests" step picks it up. See D7.
- **`ios/Leo/Settings/Config/SchemaForm*.swift`:**
  - **Data source:** a `UICollectionView` list over `[LeoConfigFormSection]`.
  - **One cell per `LeoConfigControl` case:**
    - `text`, `multiline` (pushes a text editor), `number`, `toggle`;
    - `triState` (menu: Inherit / On / Off), `picker` and `referencePicker` (pull-down `UIMenu`);
    - `list` and `keyValue` (each pushes a row editor with add and delete);
    - `duration`, `cron` (the preview as secondary text), `yaml` (pushes a monospaced editor);
    - `secret` ("Set" / "Not set", with Replace… and Clear);
    - `suggestions` (a text field with a suggestion menu);
    - `readOnlyUnknown` (an "Edit on the web" link only when the URL is non-nil).
  - Help text is the secondary text. A dirty marker, inline errors and the warning (⚠) follow the Mac rules.
  - Every edit leaves a cell as `(path, LeoConfigValue)` through one closure.
  - The spec's "double" has no schema type. See D5.
- **Failing tests:** `LeoTests/SchemaFormCellTests`, one per control, parameterized over every case.
  - Each one checks the label, the help as secondary text, the shown value, and that an edit emits the expected value.
  - Secret: Replace emits `{replace}` and Clear emits `{clear}`.
  - Unknown: read-only, with the link only when a URL is present.
- **Verify:** IB, IT(LeoTests/SchemaFormCellTests).

### I3. Templates and Environments (`ConfigCollection`)
**Reducer**
- State: `core: LeoConfigCollectionState` (`autoSelectsFirst: false`), plus `@Presents alert`, `@Presents nameEntry`, and `pendingLeave`.
- **Actions → core transitions → `LeoConfigCollectionOps` effects**, with the outcome fed back as an action:
  - `.task` / `.load`
  - `.rowTapped`, `.field(path, value)`, `.saveTapped`, `.revertTapped`
  - `.reloadTapped`, `.overwriteTapped`
  - `.add` / `.rename` / `.duplicate` / `.delete(name)`
  - `.backTapped`
  - `.machine(.connectionChanged)`: on a reconnect, re-read and rebase the carried draft
  - `.restartBannerTapped(kind)` → `.delegate(.restart(kind))`
- **Leaving a dirty editor.** `backTapped` with unsaved edits opens a dialog: Save / Discard / Cancel.
  - Save leaves only after a successful write. A 409 or 422 keeps the user on the editor.
  - The VC replaces the back action with `navigationItem.backAction` and refuses the edge and content pop gestures while dirty. Check the iOS 26.5 SDK for the name of the content-pop recognizer.
- **`NameEntry` sheet feature.** A name with inline `nameError`, plus an optional schedule (used by I4). It is a sheet rather than a `UIAlertController` text field, so validation stays inline.

**VCs**
- `ConfigCollectionViewController`: a list with + in the navigation bar, swipe Delete, and a context menu with Rename / Duplicate / Delete, offered only for `core.actions`.
- `ConfigItemViewController`: the schema form, with Save and Revert in the navigation bar, plus banners for conflict (Reload / Overwrite), restart (Restart Daemon / Restart All Agents / Later), warning, error, and "Disconnected — your edits are kept" while the machine is down.
- Environments use the `keyValue` cell for `env`.

**Failing tests:** `ConfigCollectionTests`, against `LeoFakeConfigClient`
- Dirty and save: `editMarksDirty`, `saveSendsChangedKeysWithRevision`, `saveDisabledWhenInvalid`
- Conflict and validation: `conflictShowsBanner`, `reloadRebases`, `overwriteReplaysOverFreshRead`, `overwriteSendsNothingWhenTheirsHasMine`, `invalidLandsOnField`
- Replay: `saveSendsOneEnvEntry`, `reloadKeepsTheirSetListEntry`, `orderedListReplaysWhole`
- Structure and alerts: `deleteConfirmNamesItem`, `confirmActsOnAlertPayload`, `renameFollowsItem`, `duplicateOnlyForTemplates`
- Leaving: `backWhileDirtyAsks`, `leaveSaveStaysOnConflict`, `leaveDiscardPops`
- Restart and connection: `restartRequiredShowsBanner`, `reconnectRebasesDraft`, `disconnectKeepsPaneAndDraft`

**Verify:** F(ConfigCollectionTests), IB, IT(LeoTests).

### I4. Tasks (`TaskSettings`)
**Reducer**
- It embeds `ConfigCollection` (resource `tasks`) through `Scope`, and gates the form's Save with `formSaveAllowed`.
- **Toggles:** a FIFO of `(name, enabled)` in state, with one write in flight (`applyPatch` semantics via `LeoConfigCollectionOps.write(retryingConflict: true)`), `LeoTaskToggleOverrides`, and a rollback plus message on failure.
- **Run Now:** `LeoTaskRunNotice`.
- **Cron preview:** `LeoCronPreviewer` with `sleep` = `continuousClock.sleep`. The Add sheet has a previewer of its own.
- **Add:** `NameEntry` with a required schedule.
- **History and log:** history newest first, then a run's log through `LeoTaskLog.tail`. Loads use cancel IDs, and a selection change cancels them, as the Mac's tokens do.
- **Prompt:** `LeoTaskPromptState` and its K2 decisions.
  - The "This task now uses B" dialog offers "Keep my text for B" / "Discard" (Mac parity, D10).
  - Leaving a dirty prompt asks Save / Discard / Cancel.

**VCs**
- `TasksViewController`: a `UISwitch` accessory per row, Run Now on a leading swipe and in the context menu, and Delete on a trailing swipe.
- `TaskDetailViewController`: the schema form with a live cron preview, then Prompt and History rows.
- `TaskPromptViewController`: a `UITextView` with Save, a conflict banner and the file-changed dialog.
- `TaskHistoryViewController` → `TaskLogViewController`: a read-only `UITextView` in a monospaced font.

**Failing tests:** `TaskSettingsTests`
- Toggles and Run Now:
  - `toggleShowsAtOnceAndWritesEnabledOnly`
  - `toggleFailureRollsBack`
  - `togglesRunOneAtATime`
  - `toggleRetryKeepsDirtyFormOnItsRevision`
  - `secondToggleAfterRetryStillConflicts`
  - `runNowIgnoresSecondPress`
- Schedule and history:
  - `cronPreviewDebouncesWithTestClock`
  - `addRequiresSchedule`
  - `historyNewestFirstLoadsNewestLog`
  - `lateHistoryReplyForOtherTaskDropped`
- Prompt:
  - `promptSaveRefusedWhenFileMoved`
  - `prompt409ReReadsServedFile`
  - `promptConflictReloadAndOverwrite`
  - `formSaveRepointingPromptAsks`
  - `keepTextWritesNewFile`

**Verify:** F(TaskSettingsTests), IB.

### I5. Service and the machine-level restart
**`MachineRestart`** (a child of `MachineSettings`, so a restart outlives the pane that started it)
- Every restart request first reads `serviceStatus` for a fresh `runningAgentCount`, then confirms.
  - Restart daemon: "Restart leo on <machine>?" / "Running agents keep their tmux sessions."
  - Restart all agents: `LeoServiceText.agentsRestartMessage`.
- **The wait:** `LeoRestartWait`, driven by `continuousClock` + `date` dependencies. It shows "Waiting for busy agents to pause…". A 409 `restart_in_progress` counts as a restart under way.
- **Who triggers it:** both the Service screen and the collection panes' restart banners delegate here.

**`ServiceSettings`**
- Status, and Reload Config.
- **Log tail:** polls `serviceLog(lines: 200)` every 2 s only while it is visible, the app is active and the user hasn't paused it. One cancel ID covers it, so `.disappeared`, `.machine(.scenePhaseChanged(false))` or Pause cancels it.
- **Copy:** a `pasteboard` dependency. Its live value writes `UIPasteboard` under `#if canImport(UIKit)`.

**`ServiceViewController`:** status rows, the three actions, and the log in a read-only monospaced `UITextView` with Pause and Copy. It observes both the `service` store and the `machine.restart` store.

**Failing tests**
- `MachineRestartTests`:
  - `confirmNamesMachineAndAgentCount`
  - `confirmActsOnAlertPayload`
  - `drainPollsDontSpendBudget`
  - `newPidEndsWait`
  - `deadlineGivesUpWithAgentsMessage`
  - `unreachableBudgetGivesUp`
  - `inProgressCountsAsStarted`
  - `restartAllSummary`
- `ServiceSettingsTests`:
  - `pollsEvery2sWhileVisible`
  - `stopsWhenHidden`
  - `stopsInBackground`
  - `pauseStops`
  - `copyWritesShownText`

**Verify:** F(MachineRestartTests, ServiceSettingsTests), IB.

### I6. Lifecycle across features
- **Forwarding:** AppFeature `scenePhaseChanged` → `daemons.machine` → the destination's `.machine(.scenePhaseChanged)`. This mirrors the terminal's path in `AppFeature.swift:175-180`.
- **Background and foreground:**
  - A draft stays in memory.
  - When the app comes back, Fleet reconnects and `connectionChanged(true)` reloads and rebases (I3).
  - Accepted risk: a draft is lost if iOS kills the app (per the spec).
- **A notification tap mid-edit** pushes the agent over the editor. The editor and its draft stay in the stack.
- **Failing tests:** `AppFeatureTests`:
  - `backgroundForwardsToServicePane`
  - `foregroundReconnectRebasesOpenDraft`
- **Verify:** F(AppFeatureTests, ConfigCollectionTests, ServiceSettingsTests).

### I7. Fixture and screenshots
- **`ios/Leo/Settings/Machine/SettingsFixture.swift`** (DEBUG, `-settingsFixture`), modeled on `MachinesFixture`.
- **Two machines:**
  - "Dionysus" on leo 0.59.0 with `config_api`. Its fake `LeoConfigClient` is seeded with templates (one with every field type, including a secret and an unknown type), environments with env entries, tasks with history, a log and a prompt, and service status and log.
  - "leo-vm" on leo 0.58.0, which shows "Requires".
- **`LeoUITests/LeoSettingsScreensTests`.** In light and dark, it captures:
  - machine detail;
  - each list;
  - the template form (all field types);
  - the dirty Save state;
  - the conflict banner (scripted with `failNextWrite(.conflict)`);
  - the 422 inline error;
  - the leave dialog;
  - the task detail with cron preview, the prompt, history and the log;
  - Service, with the restart confirm and waiting state;
  - the "Requires" note.
- **Verify:** IB, ISHOT. Inspect each PNG at native pixels. The orchestrator posts them to Evan.

---

## Integration gate
1. Check `uptime`. Below ~30, run the full suites: LeoKit `swift test`, LeoFeatures `swift test`, MT(GhosttyTests), IB + IT(LeoTests, LeoUITests), LKL and ML. Above it, run only the slice targets and note what was deferred.
2. Run ISHOT in light and dark and inspect the PNGs.
3. **Real-daemon check:** an isolated leo 0.59.0 over `/api/v1` with a paired token, on this host's simulator.
   1. **Get the binary.** `.github/scripts/leo/fetch-leo.sh /private/tmp/claude-501/leoset/bin` fetches the pinned, sha-checked leo 0.59.0. Keep the scratch path short, because the socket path limit is 104 characters.
   2. **Write a scratch `leo.yaml`.** Enable web on 127.0.0.1 at a spare port. Add one template, one environment with env, and two tasks whose harness is a stub. A stub matters because Run Now must not start a real `claude`.
   3. **Start the daemon.** From the scratch dir: `env -u LEO_CONFIG -u LEO_API_TOKEN -u LEO_WEB_PORT -u CLAUDE_CONFIG_DIR HOME=<s>/home TMUX_TMPDIR=<s>/tmux <bin>/leo -c <s>/home/.leo/leo.yaml service`, run in the background. Start a second scratch daemon on `~/.local/bin/leo` (0.58.0) to get the "Requires" case.
   4. **Pair.** Run `leo pair` with the same environment to get the payload. Build the simulator app **signed ad hoc** (no `CODE_SIGNING_ALLOWED=NO`) so the Keychain works.
   5. **Run `LeoUITests/LeoSettingsE2ETests`.** It is gated on `TEST_RUNNER_LEO_PAIRING_PAYLOAD`, like `LeoE2ETests`, and writes to `TEST_RUNNER_LEO_SCREENSHOTS`.
      - Pair, then open Machines → the machine.
      - **Template:** edit a field and Save. Then `grep` the scratch leo.yaml.
      - **Stale save:** edit while a CLI or `curl` write changes leo.yaml → 409 → Overwrite. Both changes must be on disk.
      - **Tasks:** toggle, Run Now, and a prompt save. Then repoint `prompt_file` by CLI and check that the save is refused.
      - **Environment:** add an env entry.
      - **Service:** the log tail runs. Restart Daemon → "Waiting…" → a new pid. The open draft survives the reconnect.
      - **Old machine:** pair the 0.58.0 daemon → "Requires leo ≥ 0.59.0".
   6. Stop both daemons and remove the scratch directory.
4. **Review.** Run a fresh-context `review` over `git diff main...HEAD` at the bar above. Address each finding, or dismiss it with a reason.
5. **Follow-up.** Add the backlog follow-ups with the `feature` skill: Defaults, Delegation and Daemon on iOS, and draft persistence across termination. Both are out of scope here.

## Decisions the spec didn't settle (recommendations; the orchestrator approves or raises)
- **D1 Functional core in LeoKit.** Value state plus pure transitions plus async ops. There is no TCA in LeoKit, and no shared `ObservableObject`. Both shells drive the same code.
- **D2 iOS does not auto-select the first item.** The LeoKit flag `autoSelectsFirst` is true on the Mac and false on iOS. On iOS, selection means a pushed screen.
- **D3 Leave-dirty Save.**
  - Save leaves only after a 2xx. On a 409 or 422 the user stays on the editor with the banner or inline error.
  - Back is intercepted with `navigationItem.backAction`, and swipe-back is refused while dirty.
- **D4 Restart banner after a save** (Mac parity; the iOS spec is silent). The restart and its drain wait run in `MachineSettings`, so they outlive the pane. Every restart confirmation names the machine and a fresh running-agent count.
- **D5 "double" field.** The schema has no double type (`LeoConfigFieldType`). The cells cover the 15 `LeoConfigControl` cases, and an unknown type stays read-only.
- **D6 "Edit on the web" origin on iOS.** The order is `public_urls[0]`, then the paired `baseURL` (which this device reaches), then nothing. A LAN bind address isn't reachable off-LAN.
- **D7 New hosted `LeoTests` bundle** for the cell tests. The app target has no unit-test bundle today.
- **D8 Screenshots.** A `-settingsFixture` UI test writes PNGs. There is no snapshot-testing dependency, because the iOS target has no snapshot harness.
- **D9 Bounded task log.** The client shows the last 256 KiB, starting on a line boundary, with a "Showing the last 256 KB" note. The service tail is the daemon's 200 lines.
- **D10 Prompt file.** iOS has no file picker or "new file" UI. `prompt_file` is edited as a normal form field, guarded by `formSaveAllowed`. A moved file offers Keep my text / Discard, as on the Mac.
- **D11 Capability** comes from the hello `features` (`DaemonSession.features`), with no extra `/api/v1/version` call. While a machine is not connected it shows the status, never "Requires".
- **D12 `LeoConfigSingletonModel` stays on the Mac.** No iOS pane uses singletons (Defaults and Daemon are out of scope).
