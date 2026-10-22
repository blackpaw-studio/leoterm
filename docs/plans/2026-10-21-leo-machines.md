# Leo Machines: implementation plan

Spec (source of truth): `docs/superpowers/specs/2026-10-21-leo-machines.md` · Branch `feat/machines` · To be saved at `docs/plans/2026-10-21-leo-machines.md`

The context you gave me holds up. Three findings change the plan's shape:
- **Leo Chat already follows the selected host.** `LeoRuntime.swift:698-699` rebinds `chat` and `unread` on every switch. They have to be pinned to This Mac.
- **The orphan store holds one record.** `LeoTunnelOrphanStore.swift:51` has a single slot. With N tunnels, a crash would leak ssh processes.
- **The Mac has no Settings window.** `Features/Settings/SettingsView.swift` is upstream's "Coming Soon" stub, and ⌘, opens the Ghostty config. See Q1.

## Verification commands
- **K(S):** `cd Packages/LeoKit && swift test --filter 'S'`
- **F(S):** `cd ios/LeoFeatures && swift test --filter 'S'`
- **MB:** one-time setup from the repo root: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer zig build -Demit-xcframework=true -Demit-macos-app=false -Demit-lib-vt=false`. Then from `macos/`: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
- **MT(S):** from `macos/`: `DEVELOPER_DIR=… /opt/homebrew/bin/timeout 600 xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64,id=00006040-001A10663400801C' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/S`. If the Mac is locked, use the injected-bundle runner in `LEO.md`.
- **IB / IT:** `cd ios && xcodegen generate && xcodebuild build-for-testing` (then `test-without-building`) `-project Leo.xcodeproj -scheme Leo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DD-ios CODE_SIGNING_ALLOWED=NO`
- **Lint:** `swiftlint lint --strict` in `Packages/LeoKit` and in `macos/`.

## 1. Inventory: consumers of `hostSelection` / `selected` (Mac)

iOS has no host selection; `Fleet` already holds every paired daemon at once. "registry" below means `LeoMachineRegistry` (S3).

| # | Consumer (file:line) | Today | New home |
|---|---|---|---|
| 1 | `LeoRuntime.swift:29,155-168` | owns the one `LeoHostSelection` | owns `LeoMachineRegistry` |
| 2 | `LeoRuntime.swift:148` → `LeoAttentionController.swift:71,105` | notifies only for the selected host | `isLive(host)`: every connected machine notifies (**Q4**) |
| 3 | `LeoAttentionController.swift:107` | `lastPosted` keeps only the posting host's entries | keep entries per host; otherwise multi-machine posts repeat (bug) |
| 4 | `LeoRuntime.swift:177` (dispatch access probe), `:182-189` (remote attach command), `:377-382` (pane focus) | `hostSelection.hosts` | `registry.configuration(for:)` |
| 5 | `LeoRuntime.swift:189,193` | `model.hostFeatures.applying(to:)` | `model.features(for: host)` |
| 6 | `LeoRuntime.swift:342`; `LeoAgentActions.swift:43,87` | actions observe the selection to reload templates | actions resolve a client per row host; templates load per machine on demand |
| 7 | `LeoAgentActions.swift:209-210` | `templates()` for the selected host | `templates(for: host)`, cached per host |
| 8 | `LeoAgentActions.swift:252-257,289-299` | global `generationToken` | `registry.generation(for: row.host)` |
| 9 | `LeoRuntime.swift:351`; `LeoAgentMenuActions.swift:80,84` | Retry and ⇧⌘R retry the selected host | `registry.reconnectUnavailable()` (**Q7**); per-machine Reconnect lives on the header |
| 10 | `LeoRuntime.swift:462` | `start(flavor:)` connects the selected host | registry connects every enabled machine |
| 11 | `LeoRuntime.swift:470`; `AppDelegate.swift:193,574` | reconnect only if local is selected | `registry.reconnect(.local)`, unconditionally |
| 12 | `LeoRuntime.swift:477` | 3s bounded teardown of one tunnel | parallel teardown of all tunnels under one bound |
| 13 | `LeoRuntime.swift:483-485`; `LeoRuntime+FileDrop.swift:221`; `LeoHostSelection+Files.swift:45-52` | file access only for the selected host ("Switch hosts…") | `registry.makeFileAccess(for:)` for any connected machine |
| 14 | `LeoRuntime.swift:514`; `LeoPickerPresentation.swift:82-170,299,310`; `LeoAgentPaletteModel.swift:43-150` | ⌘T palette scoped to the selected host and its connection state | all machines' agents, with per-machine status rows (**Q2**) |
| 15 | `LeoRuntime.swift:653-701` | one connection; rebinds actions, control, chat, unread | per-machine connect; chat and unread bound to `.local` only, never rebound; actions and control stop rebinding |
| 16 | `LeoRuntime.swift:697`; `LeoAgentControlModel.swift:28-46,109` | control bound to one daemon | `daemon(for: row.host)` |
| 17 | `LeoSidebarFeed.swift:102,118` (`onChat`, `selectedHost`) | one feed, switched between hosts | one feed per machine; only This Mac's feed forwards `onChat` |
| 18 | `LeoSidebarView.swift:96,124` | `@ObservedObject` host selection | registry |
| 19 | `LeoSidebarView.swift:140-162,483-488` | host dropdown | **removed**; one section per machine |
| 20 | `LeoSidebarView.swift:154`; `LeoAgentMenuActions.swift:68-71,325-348` | Manage Hosts… sheet | Machines settings pane (**Q1**) |
| 21 | `LeoSidebarView.swift:162` | `legacyTooltip` | an inline note in the Machines pane |
| 22 | `LeoSidebarView.swift:165` | disconnected banner for the selected host | that machine's header state |
| 23 | `LeoSidebarView.swift:173,285,303` | managed banner and Start Daemon when local | This Mac's section only |
| 24 | `LeoSidebarView.swift:277-290` | failure panel (Open SSH, Retry) | collapsed offline section: reason + Reconnect, plus Open SSH when there is a hint |
| 25 | `LeoSidebarView.swift:138` | "+" disabled while disconnected | enabled while any machine is connected |
| 26 | `LeoSidebarView.swift:402`; `LeoAgentMenuActions.swift:215`; `LeoRuntime+Control.swift:9`; `LeoAgentControlBar.swift:145` | feature checks against the selected host | `model.features(for: row.host)` |
| 27 | `SpawnAgentModel.swift:38,103,112,134`; `SpawnAgentSheet.swift:22,24` | spawn host = `source?.host ?? selected`, plus `hostMismatch` | the sheet's Machine field; worktree locks it to `source.host` |
| 28 | `LeoAgentRow.swift:232`; `LeoAgentMenuActions.swift:47` | View Logs config from `hosts` | `registry.configuration(for: row.host)` |
| 29 | `LeoRuntime+Editor.swift:32` | editor with no agent context opens on the selected host | `.local` |
| 30 | `LeoPlaceholderView.swift:8,23`; `TerminalView.swift:201,224` | start screen shows the selected host's connectivity | aggregate across machines (**Q3**) |
| 31 | `AppDelegate.swift:1025` | badge = one snapshot's `attentionCount` | sum across machines |
| 32 | `LeoMenuBarCoordinator.swift:83,106` | menu-bar daemon controls and agent list | daemon controls → This Mac (spec); agent list → **Q5** |
| 33 | `LeoClaudeOnboardingController.swift:39-40` | "live local daemon" check | `model.snapshot(for: .local)` |
| 34 | `LeoRuntime+Attention.swift:19,61`; `LeoChatPane.swift:23`; `LeoSidebarSelection.swift:60`; `TerminalController+Leo.swift:16`; `LeoRuntime.swift:503` | `isDisconnected` / `actionableSelection` | actionable when the row's own machine is connected |
| 35 | `LeoForcedDisconnectFixture.swift:28` (DEBUG) | the one feed | This Mac's feed |

## 2. Ordered steps

All steps wait for **S0** (spec gate 3). Spec gate 4 applies: each step's diff gets a fresh-context review at the P0/P1 bar before merge.

**S0 · Mockups (gate, no code) · both.** HTML mockups:
- Mac sidebar in healthy, warning, offline and no-stats states;
- the spawn sheet with the machine picker;
- the Machines pane;
- the iOS machine list.

Post them to Evan. Approval also settles the visual side of Q2, Q3 and Q6.

**S1 · LeoKit shared code · both** (shared, per the spec's LeoKit list)
- **Files:**
  - `Packages/LeoKit/Sources/LeoKit/Machines/{LeoMachineStats,LeoMeterLevel,LeoMachineStatus,LeoSpawnMachineDefault}.swift`
  - `Observe/LeoDaemonFeatures.swift`: add `.machineStats = "machine_stats"`
  - `Daemon/LeoDaemonClient.swift`: add `machineStats()`; the protocol default throws `.transport`; socket `GET /machine`
  - `Remote/LeoWebDaemonClient.swift`: `GET /api/v1/machine`
- **Interfaces:**
  - `LeoMachineStats` (Decodable, Equatable, Sendable): `sampledAt: Date`, `cpu.percent: Double?`, `cpu.cores`, `memory.used/totalBytes`, `disk.path/used/totalBytes`
  - `LeoMeterLevel.level(fraction:)`: below 0.8 normal, from 0.8 warning, from 0.9 critical; nil or zero total gives normal
  - `LeoMachineStatus`: `.connecting | .connected | .failed(String) | .disabled`, with `isSelectable`
  - `LeoSpawnMachineDefault.resolve(context:lastUsed:statuses:) -> LeoHostID`: the first *selectable* of context, then last used, then `.local`
- **Failing tests first:**
  - `LeoMachineStatsTests`: full payload, `cpu.percent: null`, fractional RFC3339, extra keys ignored
  - `LeoMeterLevelTests`: 79.9, 80, 89.9, 90 and zero total
  - `LeoSpawnMachineDefaultTests`: unreachable context falls through; a removed last-used machine gives `.local`
  - `LeoDaemonFeaturesTests`: missing flag
  - route tests for the socket and web clients with a fake transport
- **Verify:** `K(LeoMachine|LeoMeterLevel|LeoSpawnMachineDefault|LeoDaemonFeatures|DaemonClient)`, then Lint.

**S2 · Host config, orphan store, migration · Mac only** (iOS has no SSH hosts)
- **Files:**
  - `Hosts/LeoHostConfiguration.swift`: add `isEnabled`; a missing key decodes as `true`
  - `Hosts/LeoTunnelOrphanStore.swift`: a set of records keyed by socket path; still reads the old single-record key
  - new `Hosts/LeoMachineDefaultsMigration.swift`: `leo.selectedHost` → `leo.lastSpawnMachine` once, then delete the old key
- **Failing tests first:**
  - `LeoHostStoreTests`: existing `leo.hosts` JSON round-trips unchanged
  - `LeoTunnelOrphanStoreTests`: two records; clearing one keeps the other; the legacy record is still reaped
  - `LeoMachineMigrationTests`: remote value, `"localhost"`, absent key, idempotent second run
- **Verify:** MB, then `MT(LeoHostStoreTests,LeoTunnelOrphanStoreTests,LeoMachineMigrationTests)`.

**S3 · Per-machine connections and registry · Mac only** (needs S1, S2)
- **Files:**
  - new `Hosts/LeoMachineConnection.swift`: `LeoHostSelection`'s connect, `retiring` barrier, generation, orphan record and `handleExit`, for one fixed configuration
  - new `Hosts/LeoMachineRegistry.swift` (`@MainActor ObservableObject`):
    - `machines`: This Mac first, then Settings order
    - `status(for:)`, `configuration(for:)`, `generation(for:)`
    - `reconnect(_:)`, `reconnectUnavailable()`, `reload()`, `start(flavor:)`, `shutdown()`
    - `connectionTarget(host, generation, state)`
    - backoff 1, 2, 4 … capped at 60s on an injected `Clock`
    - retry on app activation, through an injected notification center
  - `Hosts/LeoMachineRegistry+Files.swift`, moved from `+Files`
  - `isolatedForTesting()`
- `LeoHostSelection` stays until S5.
- **Failing tests first:**
  - `LeoMachineRegistryTests`:
    - B's ssh hangs forever (fake runner) while A reaches connected;
    - B's tunnel exits and A is untouched;
    - removing B runs `terminateAndWait` on B only;
    - a disabled machine never launches ssh;
    - editing B reconnects only B;
    - backoff sequence on a TestClock;
    - activation retries only failed machines;
    - shutdown with B hung returns within the bound and still tears A down.
  - `LeoMachineConnectionTests`: port the existing A→B→A teardown-race tests as same-machine reconnects.
- **Verify:** MB, then `MT(LeoMachineRegistryTests,LeoMachineConnectionTests,LeoTunnelSocketPathTests,LeoControlSocketDirectoryTests)`.

**S4 · Multi-machine sidebar model · Mac only** (iOS `Fleet.sections` already groups by daemon)
- **Files:** `Sidebar/LeoSidebarModel*.swift`, `Sidebar/LeoSidebarLayout.swift`, the snapshot type.
- **Interfaces:**
  - `receive(_:for:)` with a per-machine generation guard; today's guard at `:148` is global and would drop B's lower generations
  - `snapshot(for:)`, `rows` (union)
  - `features(for:)`, replacing `hostFeatures.applying(to:)`
  - `isDisconnected(_ host:)`, summed `attentionCount`
  - per-machine `dispatchChildren`
  - `machineStats` with `receiveStats(_:for:)`
  - `machineSections`
  - closures `reconnectRequested`, `editMachineRequested`, `newAgentHereRequested` (host)
- **Failing tests first:**
  - `LeoSidebarMachinesTests`:
    - an agent named `alfred` on A and on B gives two rows with distinct selection, pins and row errors;
    - B's snapshot never clears A's selection or errors;
    - B's generation 1 is accepted after A's generation 5;
    - removing a machine drops its rows;
    - collapse state is kept per machine.
- **Verify:** MB, then `MT(LeoSidebarMachinesTests + the existing LeoSidebarModel*/Layout suites)`.

**S5a · Per-host actions and control · Mac only**
- **Files:**
  - `Sidebar/LeoAgentActions.swift`, `Control/LeoAgentControlModel.swift`
  - `Sidebar/LeoTemplateCache.swift`: one slot → keyed per host
  - new `Sidebar/LeoMachineClients.swift`: `protocol LeoMachineClientResolving { daemon(for:); generation(for:); configuration(for:) }`
- Remove `updateDaemon` and the selection observation. Add `templates(for:)` and `environmentCatalog(for:)`.
- **Failing tests first:**
  - an action on B's row reaches B's client while A is reconnecting;
  - an A generation bump does not drop B's completion;
  - spawn on B succeeds while A is failed;
  - the Claude onboarding offer stays local-only.
  - Migrate `LeoAgentActionsTests` (19 sites), `LeoWorktreeSpawnTests`, `LeoTemplateListTests`, `LeoEnvironmentActionsTests` and the control tests to a fake resolver.
- **Verify:** MB, then MT on those suites.

**S5 · Runtime integration · Mac only** (serial, after S3, S4 and S5a; one `implement.hard`)
- **Files:**
  - `LeoRuntime.swift` and its `+Attention`, `+Control`, `+Editor`, `+FileDrop` extensions
  - new `LeoMachineFeeds.swift`: one `LeoSidebarFeed` per machine; polling and wake fan-out
  - `LeoAttentionController.swift`, `AppDelegate.swift`, `LeoMenuBarCoordinator.swift`, `LeoClaudeOnboardingController.swift`
  - `LeoAgentMenuActions.swift`, `LeoAgentRow.swift`
  - picker and placeholder files, `TerminalView.swift`
  - the 18 test files that use `LeoHostSelection.isolatedForTesting`
- Deletes `LeoHostSelection(+Files)`.
- Lands inventory rows 1–17, 20 (menu), 26, 28–35, plus the minimal sidebar changes (19, 25) needed to compile. Header UI is S6.
- **Failing tests first:**
  - `LeoRuntimeMachinesTests`:
    - B's feed failing leaves A's rows connected;
    - chat arrives only from This Mac;
    - attention from A and from B posts once each;
    - badge sums;
    - `localDaemonChanged` touches only This Mac.
- **Verify:**
  - MB, then `MT(LeoRuntimeMachinesTests, LeoAttention*, LeoPickerPresentation*, LeoAgentMenuSheetTests, LeoClaudeOnboarding*, LeoMenuBar*)`;
  - launch the Debug app with This Mac only and confirm it is alive (exit 124 = alive; see the NSSplitView memory).

**S6 · Sidebar machine sections · Mac only**
- **Files:** `LeoSidebarView.swift`; new `LeoMachineSectionHeader.swift`, `LeoMachineMeters.swift`, `LeoMachineHeaderPresentation.swift`.
- **Header:** name, plus a hostname subtitle for This Mac; status dot; CPU, memory and disk meters; tooltips with exact values and the sample time.
- **Offline:** dimmed, collapsed, reason + Reconnect. **No stats:** no meters.
- **Context menu:** New Agent Here…, Reconnect, Edit Machine…, Disable.
- **Failing tests first:** `LeoMachineHeaderPresentationTests`: meter text (e.g. "3.1/16 GB"), tooltip text, offline state, missing flag, New Agent Here enabled only when connected. View styling is a TDD exception.
- **Verify:**
  - MB, then MT on that suite and `LeoSidebar*`;
  - Debug app screenshots of all four states (Peekaboo `--capture-engine cg`), using a DEBUG stats fixture that follows the `LeoAttentionFixture` pattern.

**S7 · Spawn machine picker · Mac only** (the iOS half drops; see S10)
- **Files:** `SpawnAgentSheet.swift`, `SpawnAgentModel.swift`, `SpawnValidation.swift`.
- **Interface:** `SpawnAgentSheet(model:actions:machines:context: LeoHostID?, source:attach:)`.
- **Behavior:**
  - Machine is the first field;
  - changing it reloads templates, environments and gates;
  - unreachable machines are listed but disabled;
  - worktree spawns lock the machine (replaces `hostMismatch`);
  - `leo.lastSpawnMachine` is written only on success.
- **Failing tests first:**
  - `SpawnAgentModelMachineTests`: defaults; switching resets the template list and environment prefill; an unreachable machine can't be picked; spawn targets the chosen machine; last-used is written only on success.
  - Update `LeoWorktreeSpawnTests`.
- **Verify:** MB, then MT on those suites and `LeoSpawnAgentSheetPresenterTests`.

**S8 · Machines settings pane · Mac only**
- **Files:**
  - remove `LeoHostsSheet.swift`;
  - new `LeoMachinesSettingsView.swift`, `LeoMachinesSettingsModel.swift`, `LeoSettingsWindowController.swift` (Q1);
  - `LeoAgentMenuActions.presentManageHosts`;
  - `MainMenu.xib`: "Manage Hosts…" becomes "Machines…".
- **Test Connection:** a throwaway `LeoMachineConnection` running ssh + tunnel + `/health` + `/version`. It never touches the live connection. Save calls `registry.reload()`.
- **Failing tests first:** `LeoMachinesSettingsModelTests`: validation, the disable toggle, Test Connection success and failure (fake runner), and the registry is never mutated.
- **Verify:** MB, then MT on that suite; screenshot the pane.

**S9 · Mac stats poller · Mac only**
- **Files:** new `Sidebar/LeoMachineStatsPoller.swift`, plus its wiring in `LeoRuntime`. In this wave, only S9 touches the runtime.
- **Behavior:**
  - polls every 5s on an injected clock;
  - only while `hasPollableSidebar` and the app is active;
  - only connected machines that advertise `machine_stats`;
  - one task per machine with a 2s timeout.
- **Failing tests first:** `LeoMachineStatsPollerTests` on a TestClock: cadence; stops when the sidebar is hidden or the app is inactive; a machine without the flag is never polled; a hung B does not delay A; a removed machine's stats are cleared.
- **Verify:** MB, then MT on that suite.

**S10 · iOS stats and machine list · iOS only** (needs only S1)
- **Files:**
  - `LeoFeatures/Dependencies/DaemonClient.swift`: add `machineStats`
  - `Features/Fleet.swift`: `DaemonSession` stores hello `features` (dropped today at `:224`) and `stats`
  - `Features/Daemons.swift`: `onAppear` / `onDisappear` plus the poll effect
  - `ios/Leo/Daemons/DaemonsViewController.swift`: title "Machines", meters, status
  - `ios/Leo/Agents/AgentsViewController.swift`: section headers only when more than one machine
  - `project.yml`: run `xcodegen` if files are added
- **Spawn picker:** iOS has no spawn flow. There is no spawn reducer or UI, only the `agentSpawned` event, so this item drops, as the spec says.
- **Failing tests first:**
  - `DaemonsStatsTests` on a TestClock: polls only while visible and active; skips daemons without the flag; a null CPU shows "—"; one daemon's failure is isolated.
  - `FleetTests`: hello features are stored.
- **Verify:** `F(DaemonsStatsTests|FleetTests)`, then IB and IT; simulator screenshots.

**S11 · Integration gate · both**
- Check the load average first. Then run the full K, F, MT (`GhosttyTests`), IT and Lint.
- **Live checks:**
  - the Debug app with This Mac, Dionysus and a Tart VM; kill the VM mid-session;
  - screenshots of every sidebar state;
  - the iOS simulator against two paired daemons.
- **Review:** `review.concurrency` for S3, S5 and S9 (teardown and generation races); `review` for the rest; P0/P1 bar.

## 3. Parallel waves (separate implement dispatches, no shared files)

| Wave | Dispatches | Notes |
|---|---|---|
| W0 | S0 | gate |
| W1 | S1 · S2 · S4 · S5a | disjoint files: LeoKit; Hosts config and orphan store; sidebar model and layout; actions, control and template cache |
| W2 | S3 · S10 | S3 needs S1 and S2; S10 needs S1 and runs through W4 |
| W3 | S5 | serial integration point |
| W4 | S6 · S7 · S8 · S9 | S6 calls S7's `SpawnAgentSheet(…context:)`, so merge S7 before S6 |
| W5 | S11 | |

Every Mac step must go to a Claude `implement` role. Codex cannot run xcodebuild in its sandbox (see memory).

## 4. Platform calls
- **Both:** S0, S1 (shared logic in LeoKit), S11.
- **Mac only:** S2–S9. SSH tunnels, the sidebar, the Settings pane and the spawn sheet are Mac UI and transport.
- **iOS only:** S10. It reuses the S1 models; UIKit + TCA, no SwiftUI. Polling is tied to the machine list being on screen, not to the sidebar.
- **Differences to keep:**
  - iOS backoff stays capped at 30s, as `Fleet` does today; the spec's 60s cap is for Mac.
  - iOS has no This Mac section.
  - iOS has no Settings pane; pairing stays as it is.

## 5. Open questions for Evan (each has a recommendation)
1. **Where does the Machines pane live?** There is no Leo Settings window. *Recommend:* a new Leo Settings window with toolbar tabs and one "Machines" tab, opened from Agents ▸ Machines… and from the header's Edit Machine…. Leave ⌘, (the Ghostty config) alone.
2. **⌘T agent palette** (row 14). *Recommend:* agents from every machine with a machine label, and one status row with Retry per unreachable machine.
3. **Start-screen placeholder** (row 30). *Recommend:* show "Choose agent" when any machine is connected; show This Mac's failure only when no machine is connected.
4. **Notifications from remote machines.** Today only the selected host notifies. *Recommend:* every connected machine notifies; remote notifications include the machine name.
5. **Menu-bar agent list** (row 32). *Recommend:* This Mac only. It is the local daemon's status item (server mode), consistent with the spec's daemon controls.
6. **"Needs You" section.** *Recommend:* inside each machine's section, with the machine as the top level. The mockups confirm.
7. **Agents ▸ Reconnect (⇧⌘R).** *Recommend:* reconnect every machine that isn't connected.
8. **Disable needs a new field.** The spec says "same fields", but Disable must be stored. Plan: add `isEnabled`; existing entries decode as enabled. This is a decision, flagged for visibility.

## 6. Risks
- **Quit time.** N tunnels torn down in series would exceed the 3s bound. Quit has hung before (see the quit-deadlock memory). Teardown must run in parallel under one bound (S3 test).
- **Orphaned ssh.** The single-slot orphan store leaks ssh after a crash until S2 lands. S3 must not merge before S2.
- **Stale rows.** The global generation guard in `LeoSidebarModel.receive` silently drops other machines' snapshots (fixed in S4).
- **Duplicate notifications.** The `lastPosted` filter at `LeoAttentionController.swift:107` causes them once two machines post (fixed in S5).
- **Load.** Each feed runs its own SSE and refresh, and with S9 a 5s stats poll per machine, so wakeups grow linearly with machines. Stats polling is gated on visibility.
- **Sidebar regressions.** Nested collapsible sections risk breaking the one-list invariants (B-099, B-148) and the split-view sizing (NSSplitView memories). Verify with screenshots and the launch-alive check.
- **Stats contract drift.** The daemon half lands in parallel. Before S11, check the JSON against the leo agent's implementation, especially the `sampled_at` format and whether `cpu.cores` is present when percent is null.
- **"Hello" in the spec.** The spec's daemon `hello` is an event-stream frame. Test Connection uses `/health` + `/version` instead. If the pane must show whether `machine_stats` is advertised, that needs one short event-stream read.
- **Shared test defaults.** Concurrent MT runs share debug defaults (see the LeoKit memory). Run MT serially across W1 and W4, or give each dispatch its own `-derivedDataPath`.
- **Live checks.** A blind Return in a fresh Debug build once started a real agent. Filter to autopilot-scratch and screenshot the focus before sending any key.

## Decisions (orchestrator, 2026-10-21)
The orchestrator accepted the recommended answer for every one of Q1–Q8:
- Q1: a new Leo Settings window with a Machines tab; ⌘, is unchanged.
- Q2: the ⌘T palette shows every machine, with a status row per unreachable machine.
- Q3: the placeholder aggregates across machines.
- Q4: every connected machine notifies, with the machine name included.
- Q5: the menu-bar agent list shows This Mac only.
- Q6: "Needs You" appears inside each machine's section.
- Q7: ⇧⌘R reconnects every machine that isn't connected.
- Q8: add `isEnabled`, defaulting to true.

The stats contract amendments are in the spec. They ship in leo v0.57.0.

## Mockup approval (S0 done, 2026-10-21)
Evan approved:
- `istat.html` as the Mac Capsules look: 10×20pt capsules, a 20pt header row, and the This Mac hostname moved from the subtitle to the tooltip.
- `styles.html` for all five meter styles, the iOS list layout and the Stats style setting.

Fills are flat, never gradients. The new spec section "Stats style" adds the following to the existing steps:
- S1: a `LeoStatsStyle` enum (capsules|bars|rings|numbers|off) with a stored default.
- S6: one meter view that renders each style.
- S8: the Stats style control.
- S9: polling is skipped when the style is off.
- S10: the iOS meter styles and the Settings row.
