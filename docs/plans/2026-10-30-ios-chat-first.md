# Plan: iOS chat-first revamp (spec `docs/specs/2026-10-30-ios-chat-first.md`)

**Platform call:** iOS only, as the spec says. LeoKit is unchanged. SwiftTerm 1.19 is already an app-target dependency.

## Key decisions

**1. Strip rendering: a headless SwiftTerm `Terminal` per thread, not a cropped `TerminalView`.**
- The daemon's attach is `tmux attach -r`, which is read-only and ignores the client's size (`TerminalClient.swift` header). So no attach size can resize the agent's window.
- The strip still has to use the same `@Shared(.terminalSize)` as the full terminal. tmux redraws using cursor addressing for the client's grid, so the emulator must match that grid or the text comes out garbled.
- A cropped `ReadOnlyTerminalView` would draw 200 columns into about 350 pt, roughly a 5 pt font, which is unreadable.
- The headless approach is to feed bytes into `SwiftTerm.Terminal(delegate:options:)`, resized to `store.size`. Then read rows with `getLine(row:).translateToString(trimRight:)`, drop trailing blank rows, take the last 5, and draw them as tail-truncated monospaced labels on `TerminalPalette.background`.
- The strip gets its **own `TerminalOutputBus` instance** (`\.terminalStripOutput`). The bus allows one subscriber per `AgentRef`, so if the strip shared it with the full terminal for the same agent, the two attaches would interleave and corrupt each other.
- The strip's connection reuses the existing `Terminal` reducer unchanged: phases, backoff, `notRunning`, revoked and scene pause. It is scoped with `.dependency(\.terminalOutput, stripBus)`.

**2. Tabs: `UITabBarController(tabs: [UITab])` in the default `.tabBar` mode.**
- The deployment target is iOS 26 (`project.yml`, `Package.swift` `.iOS(.v26)`), so `UITab` and `.tabSidebar` (sidebarAdaptable) are both available.
- I'm not using sidebarAdaptable. On iPad the Chats and Agents tabs are already split views with their own sidebar column, and a tab sidebar on top would give two stacked sidebars.
- The Chats and Agents tabs each hold a `UISplitViewController` (`.doubleColumn`). Both subclass a `SelectionSplitViewController` base extracted from today's `RootSplitViewController`, which keeps the iPhone collapse, pop detection and the `transitionsInFlight` guard.
- Machines and Settings are plain `UINavigationController`s.

**3. Routing goes in the `AppFeature` reducer.** I'm adding `selectedTab: AppTab` (`.chats/.agents/.machines/.settings`, default `.chats`) plus `.tabSelected(AppTab)`.
- `chatNotificationOpened` sets `.chats` and `pendingChat`.
- `notificationOpened` sets `.agents` and `pendingAgent`.
- `RootTabBarController` observes `selectedTab` and reports user taps through `UITabBarControllerDelegate`.
- There are no URL deep links today. `AppDelegate.swift:125-128` only handles notification taps, so this routing covers notification taps and the cross-links inside the app.

**4. Each tab owns its own selection.**
- `chat` belongs to the Chats tab only; `detail` belongs to the Agents tab only.
- `openChat` stops clearing `detail`, and `agentTapped`/`openPendingAgent` stop clearing `chat`.
- `.chatOverDetail` is removed.
- The detail's Chat button switches to Chats and opens the thread; the thread's Info button switches to Agents and selects the agent.
- This is the only model where both tab stacks stay alive without two VCs sharing one `chat` store. See open question 1.

## Commits (land in order; each runs only its targeted checks)

**C1 – Inbox model** (`ChatList.swift`)
- `ChatRow` gains `agent: Agent?` (from the existing session lookup) and `bucket: ChatBucket?` (`needsYou/working/done`, nil = no dot), derived from `Agent.priority`.
- Rewrite `rows(...)` sorting: Needs you, then Working, then the rest. Within each, newest message first; `assistant` goes first in its own bucket.
- Add `State.filter: ChatFilter?` (nil = not decided yet, renders as All), `filterPicked`, `searchText` (BindableAction).
- Add static `visible(rows, filter:, search:)` and `counts(rows)`.
- Remove `Section` once C4 stops using it. Until then, keep it computed.
- Failing tests first in `ChatListTests`:
  - errored/needsInput go to needsYou; finished is done; idle, stopped and not-in-fleet get no dot
  - bucket order; newest first within a bucket
  - assistant tops its bucket but not Needs you
  - search matches name and last-message text case-insensitively
  - counts
- Verify: `cd ios/LeoFeatures && swift test --filter ChatListTests`

**C2 – Default chip and stickiness** (`ChatList.swift`, `AppFeature.swift` tail `Reduce`)
- AppFeature decides `chats.filter` once: when `hasLoadedDaemons` and no session is still `.offline/.connecting` (or nothing is paired), it picks `.needsYou` if that count > 0, otherwise `.all`.
- After that, only `filterPicked` changes it. An empty selected chip stays selected, and its empty state has an "All chats" button that sends `filterPicked(.all)`.
- Failing tests in `AppFeatureChatTests`:
  - decided once with needs-you > 0, and once with none
  - a needs-you agent arriving later does not switch an undecided-then-decided All
  - the picked chip survives its list emptying
  - nothing is decided while a daemon is still connecting
- Verify: `swift test --filter "AppFeatureChatTests|ChatListTests"`

**C3 – Tab and routing state** (`AppFeature.swift`; extract `AppFeature+Routing.swift` so the file stays under 500 lines)
- Add `selectedTab` and `tabSelected`.
- Remove `isShowingChats`, `isShowingSettings`, `chatsButtonTapped`, `settingsButtonTapped` and `isShowingDaemons`, together with its `binding` machine-clearing case.
- `daemonsButtonTapped` becomes `tabSelected(.machines)`.
- Split `secondaryPopped` into `detailPopped` (clears `detail`) and `chatPopped` (clears `chat` and parks drafts).
- `detail(.chatButtonTapped)` sets `.chats` and calls `openChat`. A new `chat(.delegate(.infoTapped))` sets `.agents` and selects the agent.
- `chatsEntryAppeared` is now sent when the Chats tab first appears.
- Failing tests, updated/added in `AppFeaturePushTests`, `AppFeatureTests` and `AppFeatureChatTests`:
  - a chat push tap gives `.chats` plus the open thread once the fleet has it
  - an agent push tap gives `.agents` plus detail
  - the detail Chat button switches tab and keeps `detail`
  - Info switches tab and keeps `chat`
  - opening a chat no longer clears detail
- Verify: `swift test --filter AppFeature`

**C4 – Tab bar shell (UI-only; verified by screenshot plus UI tests)**
- New: `Leo/App/RootTabBarController.swift` (takes over pairing, appearance, move, name-prompt and moveProgress presentation from the root), `SelectionSplitViewController.swift`, `ChatsSplitViewController.swift`, `AgentsSplitViewController.swift`.
- Delete `RootSplitViewController.swift`.
- `SceneDelegate` installs the tab controller.
- Chats tab badge = `chats.unreadTotal`, with no badge at 0.
- `AgentsViewController`: remove `chatsButton`, the Daemons button, the Settings button and the three `navigationDestination(isPresented:)` blocks (lines ~27-78).
- `DaemonsViewController` becomes the Machines root, with Pair still in it. `SettingsViewController` becomes the Settings root.
- `NoSelectionViewController` gets a chat variant.
- Run `cd ios && xcodegen generate` and commit `Leo.xcodeproj`, because CI checks for drift.
- Update `LeoUITests.testLaunchesIntoAgents`, which now launches into Chats.
- Rework `LeoNavStackTests` so chat-from-detail asserts the tab switch; keep the rotation and back tests per tab.
- Verify, in the background: `heavy xcodebuild test -project ios/Leo.xcodeproj -scheme Leo -destination "platform=iOS Simulator,name=<iPhone>" -only-testing:LeoUITests/LeoNavStackTests -only-testing:LeoUITests/LeoUITests`
- Screenshots: iPhone tab bar; iPad Chats split and Agents split.

**C5 – Inbox UI (UI-only)** (`ChatsViewController.swift`, new `ChatInboxCell.swift`)
- Large title, `UISearchController` bound to `searchText`, and a chip row (All · Needs you (n) · Working (n) · Done) as the header.
- Rows: avatar from `AgentPresentation`/appearance, status dot, name, time, preview with an orange "Asks:"/"Error:" prefix, unread badge, and the daemon name when it is set.
- Empty state for the selected filter. The compose button keeps the picker.
- The preview prefix is a pure helper `ChatRow.previewPrefix`, tested in C1 if it sits in LeoFeatures.
- Verify: build, plus iPhone and iPad inbox screenshots with every bucket present.

**C6 – Thread header and full terminal** (`ChatThread.swift`, `ChatThreadViewController.swift`)
- `ChatThread.State` gets `@Presents var terminal: Terminal.State?` and `terminalButtonTapped`.
- `AppFeature` forwards `scenePhaseChanged` and `agentRunningChanged` to `chat.terminal`, mirroring what it does for `detail.destination.terminal`.
- The VC gets a custom title view (avatar, name, status line "Needs input · <daemon>"), Terminal and Info buttons with accessibility labels, and `navigationDestination(item:)` to `TerminalViewController`.
- **`TerminalViewController` fix:** subscribe to the bus in `viewWillAppear` and cancel in `viewDidDisappear`, not once in `viewDidLoad`. Without this, a terminal on the Agents tab and one on the Chats tab for the same agent steal each other's subscription, and the first one goes blank when you come back to it.
- Failing tests in `ChatThreadTests`/`AppFeatureChatTests`:
  - Terminal presents `isAgentRunning` from `agent.canOpenTerminal`
  - scene and running changes reach the chat's terminal
- Verify: `swift test --filter "ChatThreadTests|AppFeatureChatTests"`, then a screenshot of the header.

**C7 – Ask card restyle (UI-only)** (`ChatQuestionsCard.swift`, `ChatAskControls.swift`)
- Single-choice button asks: full-width stacked buttons, the first filled with the accent color and the rest tinted.
- "Reply instead" calls back to the thread VC, which focuses `ComposerView`.
- Spacing tweaks for radio, checkbox and text asks. Actions and wire format are untouched.
- Verify: `-only-testing:LeoUITests/LeoQuestionsCardTests` and fixture screenshots (`ChatQuestionsFixture`).

**C8 – Strip state** (new `Features/TerminalStrip.swift`; `TerminalClient.swift` for `\.terminalStripOutput`; new `SharedKey.showsTerminalInChats`, `appStorage`, default true, next to `notificationsEnabled`)
- `TerminalStrip.State`: `terminal: Terminal.State`, `userChoice: Bool?`, `@Shared showsByDefault`, and computed `isShown = userChoice ?? showsByDefault`.
- Actions: `toggleTapped`, `terminal(...)`, and `delegate(.openTerminal)` for the tap.
- `ChatThread.State.strip` is created in `init`.
- AppFeature's tail `Reduce` computes `want = chat.isOnScreen && strip.isShown && chat.agent != nil` and sends `.terminal(.appeared/.disappeared)` when it differs from `terminal.isVisible`. It also forwards scene phase and running state.
- A setting change therefore reaches the open thread on the next action, since the root `Reduce` runs on every action.
- Failing tests in a new `TerminalStripTests`:
  - a new thread starts from the setting (both values)
  - toggling persists while the thread stays open, and a reopened thread resets
  - a setting flip applies to an untoggled open thread but not to a toggled one
  - connects on screen when shown; cancels on hide, off-screen and background; reconnects on return
  - no connection when the agent is not in the fleet
  - the strip and the full terminal use different buses (assert that `stripBus` receives `.reset` and the default bus does not)
- Verify: `swift test --filter "TerminalStripTests|AppFeatureChatTests"`

**C9 – Strip view** (new `Leo/Chat/TerminalStripView.swift` and `StripEmulator.swift`, the headless SwiftTerm wrapper; pure `TerminalStripLines.bottom(_ rows: [String], count: Int)` in LeoFeatures)
- Title row: green "Live" dot, the agent's state, and the hide control.
- States:
  - connecting: dim placeholder lines
  - `notRunning`: "Not running"
  - `disconnected`/`revoked`: "Terminal unavailable", where a tap sends `retryButtonTapped`
  - live: a tap opens the full terminal
- Pinned under the header. Hiding animates the height constraint to 0 together with the collection view's `contentInset`, so the messages don't jump. The title view shows a "show terminal" control while the strip is hidden.
- Failing test for `bottom`: trailing blank rows are trimmed, the last 5 are kept, fewer than 5 is fine, an all-blank screen gives an empty result.
- Verify: `swift test --filter TerminalStripLines`, plus screenshots of the strip shown and hidden on a live agent.

**C10 – Settings › Chat (UI-only)** (`SettingsViewController.swift`)
- New `Item.showTerminalInChats` section, a toggle that writes the shared key through an `AppFeature` action (`showsTerminalInChatsToggled`). That action is covered by a C8 test.
- Verify: a Settings screenshot and the existing `LeoSettingsScreensTests`.

**Merge gate (once)**
- `swift test` in `ios/LeoFeatures`.
- In the background: `heavy xcodebuild test` for the full scheme.
- Simulator screenshots against an isolated daemon (memory: isolated-leo-daemon-recipe) with a live agent: iPhone and iPad inbox, thread with the strip shown and hidden, Settings toggle.
- A fresh-context review.

## Risks
- **Split view inside a tab bar on iPad (iOS 26):** this is supported for column-style splits, but collapse and pop behavior must be checked in C4 before anything builds on it. Rotation across the size class is the known trap; `LeoNavStackTests` covers it.
- **The bottom 5 rows may be all TUI chrome.** For Claude Code that means the input box and footer, or a tmux status line if one is on. The spec says "bottom rows", so implement it as written and check on the C9 screenshot. If the strip is useless, raise it with Evan rather than quietly skipping rows.
- **Strip cost:** each output chunk re-reads up to 64 rows. That is cheap, but render on the main actor after the bus coalesces, and never per byte.
- The `AppFeature` routing rewrite touches push-tap tests and parked drafts (`parkChatDrafts` on `chatPopped`/replace). The existing `AppFeatureQuestionsDraftTests` must stay green.
- Removing `isShowingDaemons` also removes the "pop skips the Machines list" workaround. That case can't happen once Machines is a tab root, but confirm the machine push still clears on pop.

## Open questions
1. **Cross-tab links.** In this plan the detail's Chat button switches to the Chats tab, and the thread's Info button switches to the Agents tab. The spec only covers deep links. The alternative keeps today's chat-over-detail inside the Agents tab, which needs two independent `ChatThread` slots and a second unread/on-screen path. I recommend the tab switch.

**Orchestrator decision (2026-10-30):** open question 1 resolved as recommended — cross-tab links switch tabs (Chat button → Chats tab, Info → Agents tab); no chat-over-detail.
