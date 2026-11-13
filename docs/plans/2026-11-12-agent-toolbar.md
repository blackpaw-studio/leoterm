# Agent toolbar: implementation plan

- **Spec:** `docs/superpowers/specs/2026-11-12-agent-toolbar.md`. The spec is the source of truth.
- **Platform:** Mac only. iOS has its own tab bar and no Files or Browser panes, so there is nothing to defer to the backlog.
- **Branch:** `feat/agent-toolbar`.

## Answers to the brief

**Browser badge: drop it.**
- Nothing records who opened a tab. `LeoAgentBrowserTabs.Tab` (`AgentBrowser/LeoAgentBrowser.swift:109`) has no origin field, and there is no seen or unread state.
- Tabs are created in five places. The agent creates them at `LeoBrowserExecutor.swift:59,62`. The user creates them at `LeoAgentBrowser.swift:71,86`. Popups from `createWebViewWith` at `:184` would have to inherit their opener's origin.
- `NSItemBadge` is also macOS 26+ only.
- That is not cheap, so per the spec the badge is dropped. It can go on the backlog as a follow-up.

**Shortcuts:**
- **⇧⌘R is taken** by Agents ▸ Reconnect (`MainMenu.xib:645`). Reveal Workspace in Finder ships with no shortcut.
- **⌥⌘C is free.** Ghostty's only `c` default is ⌘C copy (`src/config/Config.zig:6638`), and no Leo item uses it. Copy Workspace Path gets ⌥⌘C.
- **⌥⌘T is free.** It goes on Show/Hide Toolbar.
- The xib is at `macos/Sources/App/MainMenu.xib`.

**Customization APIs:**
- The Leo app targets macOS 13.0. The test bundle targets 15.5.
- `toolbarImmovableItemIdentifiers(_:)` and `toolbar(_:itemIdentifier:canBeInsertedAt:)` are both available from macOS 13.0 (SDK 27 `NSToolbar.h:255,262`), so neither needs an availability gate.
- The `NSToolbar.itemIdentifiers` setter needs 15.0. `NSToolbarItem.isHidden` needs 15.0, and the existing insert/remove fallback covers 13 and 14.

**Toggle state:** the toggles follow each panel's state through pushed bindings. The toolbar does not use AppKit autovalidation, which only runs on window events. This is the same reasoning as `bind(interruptEnabled:)` (`LeoAgentToolbar.swift:157-169`).
- **Files:** the selected row pane's `LeoWorkspaceBrowserModel.$root`, which is open when non-nil (`Browser/LeoWorkspaceBrowserModel.swift:77,118`).
- **Browser:** on when the row pane's `content == .agentBrowser` (`Editor/LeoRowPanes.swift`).
- **Agent Pane:** `LeoAgentPaneModel.$state`, using `isShown && state.isExpanded` (`AgentPane/LeoAgentPaneModel.swift`).
- **Agent browser setting:** `LeoAgentBrowserSetting.$isOn` (key `leo.agentBrowser.enabled`).
- `TerminalController+Leo` switches to the newly selected row's publishers whenever the selection changes, folds them into one pure `LeoToolbarToolState`, and pushes that to the toolbar.

## Decisions the spec didn't settle (defaults, open to veto)

1. **D1, saving the toolbar layout.** `autosavesConfiguration` stores the layout under the toolbar identifier, and each window uses a new `leo.agent.toolbar.<UUID>` (`LeoAgentToolbar.swift:35`). A saved layout would never load again, and each window would leave a stale defaults key behind.
   - The identifiers can't simply be shared. Shared identifiers make the toolbars one family, and the tracking-separator insert would then repeat across every window.
   - **Plan:** keep per-window identifiers, set `autosavesConfiguration = false`, and save the item list in an injected `LeoToolbarLayoutStore` under the key `leo.toolbar.items`. This meets the spec's goal that the layout survives a relaunch, by a different mechanism.
2. **D2, the toggle on state.** `NSToolbarItem` has no on state. Each toggle becomes a one-segment `NSToolbarItemGroup(selectionMode: .selectAny)`, which gives the native selected highlight and keeps every toggle removable on its own.
   - Step 6 starts with a spike to confirm that three of these share one Liquid Glass group.
   - Fallback: `style = .prominent` on macOS 26 for the on state.
3. **D3, Browser toggle off.** If the editor has tabs, turn-off calls `showEditor()`, so the browser stays open behind the editor. Otherwise it calls `closeAgentBrowser()`, the same close as the browser's own Close button.
4. **D4, Files toggle.** The toolbar button flips between open and closed using the model's `open`/`close`. ⌥⌘B keeps its current behaviour, which includes a focus step. Without this split, clicking an on toggle would focus the panel instead of closing it.
5. **D5, extra immovable items.** These also go in the immovable set: the sidebar toggle, the split separator, the update pill and reset zoom. The app shows and hides them itself. The palette leaves out the separator.
6. **D6, menu-bar coverage.** Appearance… and Open in New Window have no menu-bar item today.
   - Adding the two new `@IBAction`s is needed for the title menu anyway.
   - They stay out of the main menu, because the spec's menu-bar list doesn't name them. This is an open HIG gap for the orchestrator to decide.

## Steps

**Commands used by the steps**
- **Build** (from `macos/`, as a background job): `heavy xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -packageAuthorizationProvider netrc`
- **Test:** `xcodebuild test-without-building … -only-testing:GhosttyTests/<Suite>`
- **Launch check:** `timeout 20 …/Leo.app/Contents/MacOS/Leo; echo $?`. Exit 124 means alive. Run it under the isolated daemon recipe with a second debug bundle id.

**Testing rules**
- Tests use Swift Testing and `LeoInMemoryDefaults`, never `.standard`.
- New tests go in `macos/Tests/Leo/Toolbar/`. Confirm the folder is picked up by the target.

**1. Item model (pure).**
- New `Toolbar/LeoAgentToolbarItems.swift`, holding:
  - identifiers `leoTitleMenu`, `leoFiles`, `leoBrowser`, `leoAgentPane`;
  - `defaultOrder`, `immovable` and `paletteLabels` ("Files", "Browser", "Agent Pane", "Status", "View", "Interrupt", "More"), plus tooltips;
  - `canInsert(id, at:, in:)`: nothing may go before the title menu;
  - `visibilityPriority`: toggles `.low`, Interrupt `.standard`, everything else `.user`.
- `LeoAgentToolbar.itemOrder` derives from this model.
- Failing test: `LeoAgentToolbarItemsTests` checks the default set and its order, the immovable set, the palette labels, and the insert rule.

**2. Tool state and titles (pure).**
- New `Toolbar/LeoToolbarToolState.swift`, built from `(hasAgent, browserSettingOn, filesOpen, browserFront, editorHasTabs, paneShown, paneExpanded)`.
- For each toggle it gives `{isPresent, isEnabled, isOn}`. It also gives the Show/Hide menu titles and the D3/D4 toggle step.
- Failing test: `LeoToolbarToolStateTests` covers:
  - no agent: everything disabled;
  - a local agent and a remote agent;
  - Agent browser setting off: Browser not present;
  - on and off titles;
  - the D3 cases.

**3. Title menu entries (pure).**
- New `Toolbar/LeoAgentTitleMenuItems.swift`: an ordered list of entries, each with a title and an existing selector.
- Enablement for Reveal and Copy:
  - Reveal is disabled for a remote host (`row.host != .local`) or when the workspace path is gone. Path existence is checked through an injected `fileExists`.
  - Copy uses the remote path verbatim.
- Start, Stop and Restart reuse `LeoMenuCommands` and `LeoRowActionAvailability`.
- Failing test: `LeoAgentTitleMenuItemsTests` checks the order and separators, that Delete is absent, Reveal is disabled for remote and missing paths, and that everything is disabled with no agent.

**4. Workspace actions.**
- New `Integration/LeoWorkspaceActions.swift`, with the Finder reveal and the pasteboard write injected.
- `@IBAction revealLeoWorkspaceInFinder:` and `copyLeoWorkspacePath:` on `TerminalController`, with validators using step 3.
- Agents ▸ items in `MainMenu.xib`: Copy Workspace Path gets ⌥⌘C, and Reveal Workspace in Finder gets no shortcut.
- Sidebar: `Sidebar/LeoAgentRow.swift` gets both items after Browse Files, calling the same `LeoWorkspaceActions`.
- Failing test: `LeoWorkspaceActionsTests` uses fakes to check that reveal receives the file URL, copy receives the remote path, and a remote reveal is a no-op.

**5. Menu bar.**
- Move Browse Agent Files into View as Show/Hide Files ⌥⌘B. It keeps `browseLeoAgentFiles:`, and its validator (`LeoBrowserMenuActions.swift:60`) now uses the titles from step 2.
- New `toggleLeoAgentBrowser:` in `LeoAgentBrowserMenuActions.swift` wraps `openLeoAgentBrowser`, plus the D3 close.
- Rename Toggle Agent Pane to Show/Hide Agent Pane, with its title set in `validateLeoAgentPaneMenuItem`.
- Add Customize Toolbar… (`runToolbarCustomizationPalette:`) and Show/Hide Toolbar ⌥⌘T (`toggleToolbarShown:`).
- Before moving the xib item, grep for `@IBOutlet` and `identifier` references to it.
- Glue, so this is a TDD exception. Verify by build, launch check, and checking the menu titles in the E2E.

**6. Toggle items.**
- In `LeoAgentToolbar.swift`, build the toggles as D2 groups with `target = nil`, using the step 5 selectors.
- New `bind(tools: some Publisher<LeoToolbarToolState, Never>)`. Browser presence uses `setHidden` on 15+ and `setPresence` below 15. A toggle the user removed must not be put back.
- Accessibility: a label, plus `setAccessibilitySelected` from `isOn`.
- `TerminalController+Leo.swift` (`leoInstallAgentToolbar`, :120-168): the selection-switched publisher described under Toggle state.
- Glue: verify by launch check and screenshot. `LeoAgentToolbarTrailingTests` must stay green.

**7. Title menu item (highest risk).**
- The leading `leoTitleMenu` item has a custom view: title, subtitle and ▾, opening a pull-down built from step 3.
  - Menu actions use `target = nil`, so the existing validators handle enablement.
  - Move To ▸ reuses `LeoAgentsMenuController`'s submenu builder.
  - New `openSelectedLeoAgentInNewWindow:` calls the same `attach(row, .newWindow)` path the sidebar uses.
  - New `showLeoAgentAppearance:` presents the existing Appearance popover, anchored to the item. The popover is extracted from `LeoAgentRow`, not copied.
- `window.titleVisibility` becomes `.hidden`. `window.title` is still set, for the Window menu and Mission Control.
- `leoRefreshSubtitle` feeds the item instead of `window.subtitle`.
- `LeoActivityCapsuleSizing` reserves the title item's width.
- Spike first: take a screenshot next to today's native title, and match the font, weight and colour.
- Failing test: update `LeoActivityCapsuleSizing` tests so the title reserve and the hide-subtitle-first order are tested as pure functions.

**8. Terminal | Chat labels.**
- `LeoToolbarViewSwitch.swift` and `LeoViewSwitchPresentation.swift`: each segment gets a symbol plus a noun label, and the Chat unread count stays.
- Failing test: extend `LeoViewSwitchPresentationTests` with the labels and the count.

**9. Customization and overflow.**
- `allowsUserCustomization = true`, with the immovable and `canBeInsertedAt` delegate methods backed by step 1.
- New `LeoToolbarLayoutStore` (D1):
  - Load normalizes the saved list: drop unknown identifiers, put missing immovable items back, add the Browser item only if the setting allows it.
  - It saves on `toolbarWillAddItem` and `toolbarDidRemoveItem`, and when the customization sheet ends.
  - Restore assigns `toolbar.itemIdentifiers` on 15+. On 13 and 14 it returns the saved list from the delegate's default-items method.
- Overflow: give the toggles and Interrupt the step 1 priorities. `LeoActivityCapsuleSizing.trailingGroupsReserve` stops reserving room for items that can fold.
- Failing tests:
  - `LeoToolbarLayoutStoreTests`: round-trip, normalization, defaults isolation.
  - Sizing tests for the reserve once items fold.

**10. Integration gate.**
- `swiftlint lint --strict --fix`.
- The full `GhosttyTests/Leo*` suite, run through `heavy`, after checking the load average.
- Launch check.
- Customization round-trip: remove Files, relaunch, and confirm it is still gone.
- Fresh-context `review` at bar P0/P1 plus anything a user can hit.

**Order and parallelism:** steps 1, 2, 3 and 8 are independent. Step 4 depends on 3. Step 5 depends on 2 and 4. Step 6 depends on 1, 2 and 5. Step 7 depends on 1 and 3. Step 9 depends on 1, 6 and 7. Step 10 comes last.

## E2E (isolated debug app and scratch daemon)

Follow the isolated-leo-daemon-recipe memory: run with `-c`, a scratch cwd, `TMUX_TMPDIR` and a short socket path, a second bundle id, and `stub-claude` scratch agents. Filter to the scratch agent and screenshot focus before any keystroke. Take screenshots with Peekaboo `--capture-engine cg`.

1. Each toggle opens and closes its panel, and the toggle's on state follows. Also check changes the toolbar didn't make: ⌥⌘B, the browser's own Close button, and the agent opening a browser.
2. Agent browser setting off: the Browser item is removed. Turn it back on and the item returns.
3. Select the start screen or a plain terminal: the toggles and the title menu are disabled, and the title text still shows.
4. Title menu: Start, Stop and Restart enablement; Rename, Move To, Appearance, View Logs and Open in New Window each work.
5. Reveal opens Finder at the workspace. Reveal is disabled for a remote scratch agent, and Copy puts the remote path on the clipboard.
6. In the Customize Toolbar sheet: the immovable items can't be dragged out, and nothing can go before the title. Relaunch, and the layout persists.
7. Narrow the window: the subtitle hides first, then the toggles fold, then Interrupt.
8. VoiceOver reads the labels, and the toggles read as "selected" or "not selected".
9. Screenshots: light and dark, wide and narrow. Inspect every one before posting.

## Risks and open questions

- **Title item (step 7).** A custom view may not match the native title and subtitle typography on Liquid Glass. The capsule's centring and the hide-subtitle-first logic also move off `window.titleVisibility`. The spike gates the rest of the step. If it fails, use a title-styled `NSMenuToolbarItem` and ask Evan whether the small visual difference is acceptable.
- **Overflow and sizing.** Today the trailing items never fold (`.user`), and there is a documented AppKit stall with `.high` and the capsule width constraint. Changing priorities could bring back sidebar re-layout stalls. `LeoSidebarTitlebarStyleTests` must stay green, and the E2E covers live resizes.
- **D1 restore below macOS 15.** There is no `itemIdentifiers` setter there, and returning the saved list as the defaults changes what the palette's "default set" row shows. That is acceptable on 13 and 14.
- **Customization and app-managed items.** Mixing customization with the app's own insert/remove (13/14 path, and the separator added late at `attach(splitView:)`) needs a check that the palette never shows or saves those items.
- **Open:** D6, the menu-bar gap for Appearance… and Open in New Window. Also whether the orchestrator accepts D1–D5 as written.
- **Backlog follow-up:** the browser badge. It needs a tab origin field, popups inheriting their opener's origin, a per-agent "seen" counter, and macOS 26 for `NSItemBadge`.

## Orchestrator decisions (2026-11-12)

- **D1–D5:** accepted as written.
- **Browser badge:** dropped per the spec. It is queued as an autopilot idea.
- **D6:** add **Agents ▸ Appearance…** and **Agents ▸ Open in New Window** to the main menu, using the step 7 selectors. The HIG requires every toolbar command to be in the menu bar, and that compliance is what Evan asked for.
- **Step 7 fallback:** if the title spike can't match the native typography, use the title-styled `NSMenuToolbarItem`. Bring screenshots of both to the orchestrator; don't go to Evan directly.

## Build outcome (2026-11-12)

Steps 1–10 built on `feat/agent-toolbar` (HEAD a7a721272). Review round 1 found one P1 (Appearance… crash with toolbar hidden) and four P2s; the E2E found B1–B5. All fixed except as below; re-reviews of 3276c367a..462744862+ and a7a721272 came back clean at the P0/P1 + user-hittable bar. Gate: full GhosttyTests 4625 tests, 1 failure (`LeoLaunchPlaceholderIntegrationTests/aNewTabWindowReplacesTheLaunchWindowOnItsSpot`, window-geometry flake, passes alone, untouched by this diff); swiftlint clean; launch check 124.

**Accepted risks**
- Narrow windows fold the toggles and Interrupt with `isHidden` (macOS 15+), not AppKit overflow: AppKit overflow also took Interrupt and shifted the capsule off centre. Toggles stay in the View menu, Interrupt in ⋯.
- Toggle on/off state is not exposed to VoiceOver (tooltip/AXHelp flips Show→Hide). An NSButton view lost the glass group; a `.selectAny` NSToolbarItemGroup lost the lit state and still exposed no value.
- Side by side with a very wide chat pane (≳45% of the window), the capsule falls back to the column layout and the toggles and Interrupt fold.
- The real-toolbar test doesn't assert toggles/Interrupt are visible side by side; covered by E2E shots only.
- Capsule sizing keeps a fixed trailing reserve after the user removes toolbar items.
- A layout change in one window reaches other open windows only after relaunch.
- `LeoAgentTitleMenuItems.Item.isEnabled` is not what the live menu uses (responder validators are); pure tests don't cover the live enablement.
- The "ambiguous height or width" NSToolbarItem warning at launch is unattributed (suspect the update pill's hosting view).
- macOS 13/14 fold path (`visibilityPriority`) untested.
