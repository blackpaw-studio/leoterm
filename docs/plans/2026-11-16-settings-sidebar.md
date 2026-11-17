# Plan: Settings window, one sidebar

Spec: `docs/superpowers/specs/2026-11-16-settings-sidebar.md`. If this plan and the spec disagree, the spec wins. Mockups: `docs/mockups/2026-11-16-settings-redesign/` (`a1-this-mac`, `a1-this-mac-dark`, `a2-remote`, `a3-this-mac-defaults`).
Branch: `feat/settings-sidebar` (off `main`). **Platform: Mac only**, per the spec. iOS already uses this model (`ios/Leo/Settings/`). No LeoKit changes and no backlog item.

## B0. Conventions

- **Commands** (same as `docs/plans/2026-10-23-in-app-settings.md` §B0). Run each from `macos/` with `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`:
  - **MB:** `xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`. It is CPU-heavy, so run it as `heavy …` in the background.
  - **MT(S…):** `timeout 600 xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<S>`. It hangs while the console is locked. In that case, use the injected-bundle runner (`LEO.md`).
  - **ML:** `swiftlint lint --strict --quiet`.
  - **SNAP:** `LEO_SETTINGS_SNAPSHOTS=<scratch dir>` + MT(LeoSettingsSnapshots). It writes light and dark PNGs offscreen (`Tests/Leo/LeoSettingsSnapshots.swift`). Inspect them at native pixels against the mockup PNGs.
- **Worktree prereq:** symlink `macos/GhosttyKit.xcframework` and `zig-out` from the main checkout.
- **TDD:** model and presentation steps are test-first. View layout and styling are TDD-exempt and verified by SNAP. Tests use `LeoInMemoryDefaults` and never `UserDefaults.standard`. A custom trait conforms to both `SuiteTrait` and `TestTrait`.
- **Review bar:** P0/P1, plus anything a realistic Settings session can hit. Step 9 (split view) and step 2 (pending-change semantics) get `review`. Everything else is reviewed once at the gate.
- **Parallel lanes:** steps 1→2→3 run in sequence. Step 4 and step 8 are independent. Step 5 runs before step 7 because both edit `LeoMachinesSettingsView.swift`. Step 9 needs steps 1–8. Steps 10 and 11 come after step 9.

## B1. Facts settled (evidence)

### Entry points today

| # | Entry point | Path | Lands today | Lands after |
|---|---|---|---|---|
| E1 | App menu ▸ Settings… (⌘,) | `App/MainMenu.xib:103` → `AppDelegate.swift:593` → `LeoRuntime+Machines.swift:26` `show()` | The tab and machine that were open (window kept). A fresh window opens on Machines (`LeoSettingsTargetModel.swift:76`), targeting the selected agent's machine (`:115`) | Remembered item, else This Mac overview |
| E2 | Agents ▸ Machines… | `MainMenu.xib:689-692` → `AppDelegate.swift:599` → `presentMachinesSettings()` → `show(selecting: nil)` (`LeoSettingsWindowController.swift:77`) | Same as E1. `show(selecting:)` never sets the tab, so an open window stays on whatever tab it is on | Overview of the remembered machine (when the remembered item is a machine or a machine's pane), else This Mac overview |
| E3 | Sidebar machine header ▸ Edit Machine… (remotes only) | `Sidebar/LeoMachineSectionHeader.swift:83-86` → `LeoSidebarView.swift:340` → `LeoRuntime.swift:478` → `presentMachinesSettings(selecting: host)` | Selects the host in the Machines list (`WindowController:79-81`). The tab is not switched, which is a latent bug | That remote's overview |
| E4 | Agent row ▸ Edit Appearance Rules… | `Sidebar/LeoAgentRow.swift:298-301` → `presentAppearanceRules(for:)` → `show(target:tab:)` (`WindowController:88`) | Appearance tab on the row's machine | `pane(machine, .appearance)` |
| E5 | Appearance popover ▸ Edit Rules… | `Sidebar/Appearance/LeoAgentAppearancePresenter.swift:16-19` → same as E4 | Same as E4 | Same as E4 |

- **Managed-daemon sidebar button:** it does not open Settings. The offline card's Start daemon button (`LeoMachineSectionHeader.swift:133`) and the banner actions call `LeoManagedStartup.perform` directly (`AppDelegate.swift:580-581`).
- **No other callers:** grepping `settingsWindow.`, `present*Settings`, `showLeo*Settings` across `macos/` finds only the five rows above.

### General items today

- **Stats style:** `LeoStatsStyleSection` at the bottom of the Machines tab (`LeoMachinesSettingsView.swift:23`), backed by `LeoStatsStyleSetting` (`WindowController:67`).
- **Agent browser:** `LeoAgentBrowserSection` (`LeoMachinesSettingsView.swift:25`), backed by `LeoAgentBrowserSetting` (`WindowController:68`).
- **Show Terminal tab:** the Plugins pane (`Plugins/LeoPluginsSettingsView.swift:82`), bound through `LeoPluginsSettingsModel.showsTerminalTab` → `LeoBuiltInPaneSettings` (`LeoPluginsSettingsModel.swift:60,90`).

### This Mac overview: data sources (spec rule: only real data)

**Kept:**

| Field | Source |
|---|---|
| Name | "This Mac" |
| Agent count | the window's injected `agents(.local).count` (`WindowController:45`, `LeoRuntime.swift:52`) |
| Connection badge | `registry.status(for: .local)` (`LeoMachineRegistry.swift:86`) |
| Managed state in words, and its action | `LeoManagedStartup.status` / `.presentation` (`Managed/LeoManagedStartup.swift:35,47`). Banner actions come from `LeoManagedBanner.actions`. Start action from `startAction`, shown only while This Mac is not connected, as on the offline card (`LeoMachineSectionHeader.swift:99,133`) |
| Version | `LeoManagedStatus.managed(version:)`, else the version `LeoSettingsTargetModel.refresh` already fetches (`:275`) |
| Config path + Show in Finder | `LeoServiceStatus.configPath` (`LeoKit/Config/LeoServiceModels.swift:45`) via `target.service(using:)` (`TargetModel:174`) |
| Reload Config / Restart Daemon… | `LeoServiceSettingsModel.reloadConfig` / `requestRestartDaemon` (`Service/LeoServiceSettingsView.swift:147-152`) |
| Local socket path | `registry.connectionState(for: .local)` → `.connected(socketPath:)` (`Hosts/LeoHostConnectionState.swift:8`). Hidden when not connected |

**Dropped:** the Mac model ("MacBook Pro"), because no source exists in the app. The only local identity is the computer name (`LeoSidebarView.swift:248`). PID and "Running since" are dropped too: they are real (`LeoServiceStatus.pid/startedAt`) but not in the spec's list, and the spec calls PIDs placeholders. The mockup's "Settings on This Mac" note is also dropped, because the spec separates by structure, not by notes.

**Remote overview:**
- **Version:** the same fetched `LeoDaemonVersionInfo.version`, shown only while the target is this machine.
- **Test result:** `LeoConnectionTestReport` (existing).
- **Agent count:** not specified for remotes, so not shown.

### How Service merges into Daemon

- **Daemon today:** a segmented Web UI / Remote client / Remote hosts picker (`Daemon/LeoDaemonSettingsView.swift:64-79`).
- **Service today:** its own tab (`Service/LeoServiceSettingsView.swift:7-17`). Its model is owned by the target and keyed by `LeoSettingsTab.service` (`TargetModel:21,174-180,293-295`), so restart prompts from any pane keep working.
- **Merge:**
  - `LeoDaemonSettingsModel.Section` gains `.service`, first in order and the default. The picker then has 4 segments, which the "segmented for 2–4" rule allows.
  - `LeoDaemonView` renders `LeoServiceView` for that section.
  - The registration key `.service` stays, so the restart plumbing is untouched.
  - Log tail visibility becomes: Daemon pane selected AND section == `.service`. It was `selectedTab == .service`, at `LeoServiceSettingsView.swift:28`.

## B2. Steps

### Step 1: Sidebar items and selection resolution (pure)

- **Files:** new `Settings/Sidebar/LeoSettingsSidebarItem.swift`; edit `LeoSettingsTargetModel.swift:7-22`.
- **Interfaces:**
  - `enum LeoSettingsMachineRef: Hashable { case local, remote(UUID) }`, keyed by `LeoHostConfiguration.ID`, not by name, so a rename keeps the selection.
  - `enum LeoSettingsMachinePane: CaseIterable` with cases templates, tasks, environments, delegation, appearance, defaults, daemon. Each maps to the existing `*.tab` statics.
  - `enum LeoSettingsSidebarItem: Hashable { case general, plugins, machine(Ref), pane(Ref, MachinePane) }`.
  - `LeoSettingsTab`:
    - Add `.general` and `.overview`.
    - Remove `.machines`.
    - Keep `.config` and `.plugins`.
    - `usesMachineTarget` covers `.overview`.
  - `static func resolve(_ item:, configurations: [LeoHostConfiguration]) -> (item, host: LeoHostID?, tab)`:
    - A gone remote falls back to `.machine(.local)`.
    - App items have a nil host.
    - An unsaved remote (in the draft, not in `configurations`) has a nil host.
  - `static func panesEnabled(status: LeoMachineStatus?) -> Bool`: false for `.disabled`, `.failed` and `nil`.
  - `enum LeoSettingsEntry { case settings, machines(LeoHostID?), appearance(LeoHostID) }` with `func item(remembered:, configurations:)`. This is the E1–E5 table above.
- **Failing tests first:** `Tests/Leo/LeoSettingsSidebarItemTests.swift`:
  - This Mac → (`.local`, `.overview`).
  - Remote pane → (`.remote(name)`, tab).
  - Removed remote → This Mac overview.
  - General and Plugins → nil host.
  - Renamed remote resolves to its new name.
  - Every entry mapping.
- Update `LeoSettingsTargetModelTests.swift:505-519`, which use `.machines`.
- **Verify:** MB; MT(LeoSettingsSidebarItemTests, LeoSettingsTargetModelTests).

### Step 2: Target model, atomic selection and daemon version

- **File:** `LeoSettingsTargetModel.swift`.
- `requestSelection(host: LeoHostID?, tab:) -> Bool`:
  - Moves machine and tab together.
  - A nil host keeps the current machine.
  - One dirty check covers both the leaving pane and the machine.
  - `PendingChange` gains `.selection(LeoHostID?, LeoSettingsTab)`. `requestSwitch` and `requestTab` route through it.
- `@Published private(set) var daemonVersion: String?`, set from the `versionInfo` already fetched at `:275` (ready and tooOld) and cleared on switch.
- **Failing tests:**
  - A dirty pane on A, then selecting B's pane, gives exactly one pending change. Confirm applies host and tab; cancel applies neither.
  - The version is set for ready and tooOld and cleared by a switch.
- **Verify:** MT(LeoSettingsTargetModelTests).

### Step 3: Sidebar model

- **File:** new `Settings/Sidebar/LeoSettingsSidebarModel.swift`, an `@MainActor` `ObservableObject`.
- **Inputs:** `LeoMachinesSettingsModel`, `LeoSettingsTargetModel`, `LeoMachineRegistry` (statuses and configurations), and the initial item.
- **Interfaces:**
  - `rows`: This Mac, then the draft `hosts` in order, so a new unsaved machine appears. Each row has name, status, and `isOff = !host.isEnabled`.
  - `selection`.
  - `expanded: Set<Ref>`. Selecting a machine collapses the previous one and expands the new one. `toggleDisclosure(ref)` changes `expanded` only.
  - `select(_:)` calls `target.requestSelection`. A refused (pending) change keeps the old selection until confirmed.
  - Follows `target.selectedHost` fallback: a removed remote's selection becomes This Mac overview.
  - `addMachine()` calls `model.addHost()` and selects the new remote's overview.
- **Failing tests** (`LeoSettingsSidebarModelTests`):
  - Expand/collapse rules.
  - Chevron toggle doesn't select.
  - Selection survives a pending change and is applied by confirm.
  - Removal falls back to This Mac.
  - `+` selects the new row.
- **Verify:** MT(LeoSettingsSidebarModelTests).

### Step 4: Managed-daemon feed for Settings

- **Files:**
  - New `Managed/LeoManagedDaemonFeed.swift`, an `ObservableObject` with published `status`, `presentation`, and `perform(LeoManagedBannerAction)` / `perform(LeoDaemonStartAction)` closures.
  - `AppDelegate.swift:566-583`: in `startup.onChange`, also update the feed from `startup.status`, and wire perform to `startup.perform`.
  - `LeoRuntime.swift`: own the feed and pass it into the settings window.
  - `Managed/LeoManagedStatus.swift`: add `var settingsSummary: (title: String, detail: String)`, every case in words. The `.managed` case reads "Managed by Leo" plus the a1 mockup detail line.
- **Failing tests** (`LeoManagedStatusTests`, new or existing): one summary per case. The actions per state equal the banner actions, plus the start action only when not connected.
- **Verify:** MT(LeoManagedStatusTests).

### Step 5: General pane

- **Files:**
  - New `Settings/LeoGeneralSettingsView.swift`: a grouped `Form` with stats style (segmented, existing options), agent browser toggle, and Show Terminal tab bound to `LeoBuiltInPaneSettings`.
  - Remove the stats and agent browser sections from `LeoMachinesSettingsView.swift:22-25`.
  - Remove the toggle from `LeoPluginsSettingsView.swift:82` and `LeoPluginsSettingsModel` (`:90` + setter) if nothing else uses them.
  - Fold `LeoStatsStyleSection` and `LeoAgentBrowserSection` into Form rows.
- **No test** (reason: UI move, no logic). Add General to SNAP.
- **Verify:** MB; SNAP; MT(LeoPluginsSettingsModelTests) if those tests touched the removed property.

### Step 6: This Mac overview

- **Files:**
  - New `Settings/Overview/LeoThisMacOverview.swift`: a pure presentation struct built from the managed feed, the connection state, `LeoServiceStatus?`, the agent count, `daemonVersion` and status. It produces only rows whose source exists.
  - New `Settings/Overview/LeoThisMacOverviewView.swift`:
    - Header with icon, "This Mac", agent count and badge.
    - Daemon section: words, action button, version, config path with Show in Finder (an injected `revealInFinder: (URL) -> Void`, live = `NSWorkspace.activateFileViewerSelecting`), and Reload Config / Restart Daemon… with the existing confirmation alert.
    - Connection section: socket path, read-only, and "This Mac can't be removed."
    - When unreachable, a top line with the reason.
- **Failing tests** (`LeoThisMacOverviewTests`):
  - The socket row is absent when not connected.
  - The config row is absent without a service status.
  - Actions per managed state.
  - The reason line appears for `.failed(msg)`.
- **Verify:** MT(LeoThisMacOverviewTests); SNAP for connected, offline and `.usingCLI(offerTakeover: true)`.

### Step 7: Remote overview

- **Files:**
  - New `Settings/Overview/LeoRemoteOverviewView.swift` and `LeoRemoteOverview.swift` (presentation).
  - Header with the Enabled toggle, editing the draft through `model.setEnabled` (`LeoMachinesSettingsModel.swift:70`) as today.
  - Connection form and `LeoConnectionTestSection` moved from `LeoMachinesSettingsView.swift:107-134`, with sentence-case labels ("SSH target", "Identity file", "Remote leo path", "Remote socket path").
  - Daemon line: version only when `target.selectedHost` is this machine.
  - Reason line: "Off", or the `.failed` message.
  - Remove Machine… with confirmation. See Q1.
  - Revert/Save footer unchanged.
  - Move `LeoStatusDot` to its own file. Delete the list part of `LeoMachinesSettingsView.swift`.
  - Retarget `LeoMachinesSettingsLayoutTests` (B-308: form not squeezed at minimum size) to the remote overview.
- **Failing tests** (`LeoRemoteOverviewTests`):
  - The version is hidden when the target is another machine.
  - Reason text for disabled and failed.
  - Remove asks and then removes.
- **Verify:** MT(LeoRemoteOverviewTests, LeoMachinesSettingsLayoutTests); SNAP for connected, disabled and a test result.

### Step 8: Service folds into Daemon

- **Files:**
  - `Daemon/LeoDaemonSettingsModel.swift`: `Section.service`, first and default. `func isLogVisible(paneSelected: Bool) -> Bool`.
  - `Daemon/LeoDaemonSettingsView.swift`: a 4-segment picker, with `.service` rendering `LeoServiceView` via `target.service(using:)`.
  - `Service/LeoServiceSettingsView.swift`:
    - Delete the `LeoServiceSettingsView` tab wrapper (`:7-37`).
    - Make the status card a `Form` section, removing the `GroupBox` at `:102`.
    - Use semantic colors for messages (`:168,175`).
- **Failing tests** (`LeoDaemonSettingsModelTests`): `.service` is the default; the log shows only when the pane is selected and the section is `.service`. `LeoServiceSettingsModelTests` stay green.
- **Verify:** MT(LeoDaemonSettingsModelTests, LeoServiceSettingsModelTests); SNAP.

### Step 9: Split-view shell, sidebar UI, entry points and deletions

- **Files:**
  - `LeoSettingsWindowController.swift`: rewrite.
    - An `NSSplitViewController`: `NSSplitViewItem(sidebarWithViewController:)` hosting `LeoSettingsSidebarView`, plus a content item hosting the detail view, which switches on the selection to General, Plugins, the overviews or the existing pane views.
    - The machine panes are disabled when `panesEnabled` is false.
  - Delete the toolbar picker and `NSToolbarDelegate` (`:36,112-115,124-145`), and `LeoMachinePicker.swift`.
  - Delete the `TabView` (`:211-243`). Keep the `.alert` for `pendingChange` and the close prompts (`:149-195`).
  - `window.title` = item name and `window.subtitle` = machine name for panes (a3 mockup). Size and sidebar width come from the mockup (`mac.css` sidebar min 230 pt; PNG 980×720 pt).
- **Sidebar view:**
  - A `List(selection:)` with `.sidebar` style.
  - Sections "App" and "Machines", with a `+` header button.
  - Machine rows have an icon, the name and a status (dot, or "Off").
  - A custom disclosure chevron bound to `toggleDisclosure`.
  - VoiceOver label "<name>, <status>". Arrow-key navigation.
- **Split-view hazards** (`nssplitviewcontroller-launch-crash`, `nssplitview-holding-priority`):
  - Implement no legacy `NSSplitViewDelegate` sizing method. Clamp with `minimumThickness`/`maximumThickness`.
  - Leave `holdingPriority` at its default (260/250).
  - Call `window.setContentSize` after assigning `contentViewController`.
  - No `setPosition` before the view is in a window.
- **Entry points:**
  - Replace `show(selecting:)` and `show(target:tab:)` with `show(_ entry: LeoSettingsEntry)`.
  - The controller keeps `lastItem` across window opens. It is in memory and survives close, since the controller is app-lifetime (`LeoRuntime.swift:49`).
  - Update `LeoRuntime+Machines.swift:21-33` and its callers.
  - Remove the now-unused `selectedHost:` init parameter (see Q2).
- **Failing tests:** extend `LeoSettingsWindowCloseTests` (`LeoSettingsWindowEntryTests`) so each `show(entry)` lands on its item in a test window. Also: a remembered removed machine opens This Mac; close prompts still fire.
- **Verify:**
  - MB.
  - MT(LeoSettingsWindowCloseTests, LeoSettingsWindowEntryTests, LeoSettingsSidebarModelTests).
  - **Launch smoke:** `timeout 15 macos/build/DD/Build/Products/Debug/Leo.app/Contents/MacOS/Leo; echo $?`. **124 = alive, 6 = died.** On 6: `log stream --predicate 'process == "Leo"'`.
  - Then `defaults delete studio.blackpaw.leo.macos.debug` before any test run.
  - Run the `review` dispatch for this step.

### Step 10: Consistency sweep A, machine panes

- **Files:** Appearance, Tasks, Delegation and Defaults views (the files that hardcode colors, listed by `grep -rln '\.green\|\.red)\|\.yellow' Settings/`).
- **Changes:**
  - Status colors go through one semantic map: reuse `Sidebar/LeoTint.swift` (system colors) or add `LeoSettingsStatusStyle` in Settings.
  - Sentence-case labels and headers; title case only for buttons and menu items.
  - Segmented pickers for 2–4 always-visible options, popup otherwise.
  - Add/remove uses the bottom-bar `+`/`−` attached to the list.
  - New `Settings/LeoSettingsMetrics.swift` replaces ad hoc paddings.
- **No test** (reason: UI styling).
- **Verify:** MB; SNAP; ML.

### Step 11: Consistency sweep B, Config components and Plugins

- **Files:** `Config/*` (`LeoListEditor`, `LeoKeyValueEditor`, `LeoConfigCollectionView`, `LeoConfigBanners`, `LeoSchemaFieldRow`, `LeoRestartPrompt`, `LeoCronField`, `LeoNameSheet`), `Plugins/*`, `LeoConnectionTestSection`.
- **Changes:** same rules as step 10.
- **No test** (reason: UI styling).
- **Verify:** MB; SNAP; ML; MT(LeoSettingsPaneStateTests).

## B3. Integration gate (once, before merge)

1. **Load check.** If the load is above about 30, defer the full run, and note what was deferred.
2. **Full suite:** `heavy bash macos/scripts/leo-runtests.sh settings-sidebar` (background), then ML. If a launch happened before the run, run `defaults delete studio.blackpaw.leo.macos.debug` first.
3. **Launch smoke:** `timeout 15 …/Leo.app/Contents/MacOS/Leo; echo $?` must print 124. Then `defaults delete studio.blackpaw.leo.macos.debug`.
4. **Real-app screenshots** (Peekaboo bridge, `--capture-engine cg`, native pixels):
   - Light and dark (toggle system appearance or set `NSAppearance` per window) for each of:
     - This Mac overview
     - remote overview
     - a This Mac pane (Defaults)
     - a remote pane
     - General
     - a disabled machine
   - Compare each with a1, a1-dark, a2 and a3 (light and dark), and inspect every PNG before posting.
   - Use a scratch remote entry only. Never send Return or keys while real agent rows are actionable (`debug-app-keystroke-safety`). Never press Restart Daemon on the real local daemon.
5. **Entry-point walkthrough** in the real app, screenshotting each landing:
   - E1 ⌘,
   - E2 Agents ▸ Machines… (via `peekaboo menu click`)
   - E3 Edit Machine… on a remote header
   - E4 Edit Appearance Rules… on an agent row: menu click only, no Return
   - E5 Appearance popover ▸ Edit Rules…
   - Close and reopen, which must restore the last item.
   - Remove the scratch remote while it is selected, which must fall back to This Mac.
6. **Keyboard and accessibility:** arrow-key traversal of the sidebar. Each machine row's AX label reads "name, status" (`peekaboo see` element dump).
7. **Final review:** a fresh-context `review` of `git diff main...HEAD` at the B0 bar.

## B4. Risks

- **Launch crash invisible to tests:** split-view misconfiguration kills the app at launch while the suite reports generic failures. Mitigation: the step 9 and gate smoke tests, and the hazard rules in step 9.
- **Identity by name:** `LeoHostID.remote(name)` changes on rename. Selection is keyed by config UUID (step 1), but `target.receive` (`TargetModel:302-308`) first falls back to `.local` when the old name disappears. The sidebar model must re-resolve to the new name instead of landing on This Mac. Covered by a step 1 test and a step 3 rename case.
- **Cross-machine draft:** `LeoMachinesSettingsModel` holds every remote in one draft, as today. Edits on remote A stay pending while B is viewed. Close still prompts (`WindowController:150`).
- **Log polling:** the Service log tail now lives behind a segment. A wrong visibility condition polls when hidden or freezes when shown (step 8 test).
- **Real daemon:** the debug app drives the real local daemon. Restart and Reload are on the This Mac overview, so the gate must not click them.
- **`swiftlint` on Evan's machine** fails builds that pass here unless ML is clean.

## B5. Open questions

- **Q1. Does Remove Machine… save at once?** Today `−` only edits the draft and needs Save (`LeoMachinesSettingsView.swift:50`, `LeoMachinesSettingsModel.swift:59`). Recommendation: on confirm, remove and save immediately. If other draft edits are invalid, refuse with the save error.
- **Q2. What does the first-ever open select?** Today the target defaults to the selected agent's machine (`TargetModel:115`), on the Machines tab. The plan uses "remembered, else This Mac", per the spec's fallback, and deletes the `selectedHost` input.
- **Q3. What goes in the This Mac header where the mockup's model line was?** Nothing has a model source. The computer name (`LeoSidebarView.swift:248`) is real but not named in the spec. The plan shows nothing there unless Evan wants the computer name.

## B6. Open questions resolved (orchestrator, 2026-11-16)

- **Q1:** Remove Machine… removes the machine and saves immediately once confirmed, as recommended. A destructive action you've already confirmed shouldn't also need Save. Only the removal is written: it saves the last-saved list minus that machine, then rebases the draft onto it, so other machines' unsaved edits stay pending (and unwritten) under Save/Revert, whether or not they are valid. The draft and the sidebar selection change only after that write succeeds; if it fails (for example the store changed in another window), the machine stays selected and the save error shows on its overview. (Amended 2026-11-16 after review: the first version saved the whole draft.) Every other edit keeps today's Save/Revert.
- **Q2:** Use the remembered item, else the This Mac overview. Delete the `selectedHost` input.
- **Q3:** Leave the This Mac header with nothing on the model line. Don't add the computer name, because the spec doesn't ask for it.
