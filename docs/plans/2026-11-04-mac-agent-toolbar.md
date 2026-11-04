# Mac agent window toolbar + activity capsule: implementation plan

Spec (source of truth): `docs/specs/2026-11-04-mac-agent-toolbar.md` (approved 2026-11-04). Mockup: `docs/mockups/2026-11-03-agent-progress/v2-C.png`. Platform: **Mac only**. iOS keeps its nav bar and progress panel.
Base: `fix/progress-sizing` @ `dc601e631`. Toolchain: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`. Never use 26.5, because Zig fails to link against its SDK.

## Verified facts this plan relies on
- **Window class.** Every `TerminalController` window is a Leo window: `leoSession` is set in `windowDidLoad` (`TerminalController.swift:1449`). The class comes from the nib, which `windowNibName` picks from Ghostty's `macos-titlebar-style` (`TerminalController.swift:258`). The upstream default is `transparent` (`Config.zig:3389`), not `hidden`, and Dionysus's config sets neither. So today the window class depends on the user's config: `TerminalWindow`, `TransparentTitlebarTerminalWindow`, `HiddenTitlebarTerminalWindow`, or `TitlebarTabsTahoeTerminalWindow`, which owns its own `NSToolbar`. `HiddenTitlebarTerminalWindow` hides the titlebar container and the traffic lights (`:55-73`), so no toolbar can live in it. **Approach:** Leo windows stop following `macos-titlebar-style` and always load a new `LeoAgentTerminalWindow`. `window-decoration = false` still means no titlebar and no toolbar.
- **Title.** `window.title` already resolves to the agent name for attach surfaces (`LeoTitleSource`, `BaseTerminalController.swift:900`). A user-set title still wins. `subtitle` is new.
- **Subtitle data.** `harness` exists only on the observe snapshot (`LeoActivityClient.swift:33`), not on `LeoAgent` or `LeoAgentRow`. The cwd is `LeoAgentRow.workspace`.
- **Primary order.** `LeoAgentTasks.primary` (LeoKit) is failed → running → ended. `source`, auto tasks and `isDismissable` arrive with plan D2 (`2026-11-03-agent-progress-auto.md`), which the spec schedules after this work. The capsule must call `primary` and `LeoTaskDetailText.canDismiss` so that D2's change flows through on its own.
- **Reuse.** `LeoTaskBar(kind:height:)` already handles Reduce Motion and the indeterminate shimmer. `LeoTaskListView` stays because the row popover (Detail A) uses it. It sorts running-first, not in primary order.
- **Switcher.** `LeoAgentViewSwitch` (`LeoAgentControlBar.swift:187`) is an `NSSegmentedControl` in `.selectAny` mode, with both segments lit when the panes are side by side. Accessibility label "View".
- **Native capsule.** The 26.3 SDK has `NSSegmentedControl.borderShape` (`NSControl.BorderShape.capsule`, macOS 26). Combined with `selectedSegmentBezelColor = .controlAccentColor`, AppKit should draw the capsule natively. Step 0 confirms that visually.
- **Toolbar APIs (SDK 26.3).** `NSToolbarItem.isHidden` (macOS 15), `NSToolbarItem.style` and `backgroundTintColor` (macOS 26), `NSTrackingSeparatorToolbarItem`, `NSToolbar.centeredItemIdentifiers`, `NSWindow.subtitle`.
- **Shortcuts in use.** ⌘1–9 select rows (`goto_tab`). Agents menu: ⌃⌘A, ⌃⌘D, ⌃⌘M, ⌃⌘. (Interrupt), ⌃⌘K (Compact), ⌃⇧⌘K (Clear), ⌃⇧⌘M, ⌃⇧⌘C. ⌃⌘F is full screen. Ghostty's ctrl+super defaults are only `[`, `]` and the arrow keys; ctrl+super+shift has `j` and the arrows.
- **Shortcut choice.** **View ▸ Terminal = ⌃⌘1, View ▸ Chat = ⌃⌘2.** Neither collides with any MainMenu.xib item, any Ghostty default, or a macOS system shortcut.

## Steps
Every Swift step verifies with this sequence, run from `macos/`, with heavy runs in the background:
`heavy xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -packageAuthorizationProvider netrc`, then `heavy xcodebuild test-without-building … -only-testing:GhosttyTests/<Suite>`. If the console is locked, use the in-host runner (`scratchpad/runtests.sh`). Finish with `swiftlint lint --strict --fix`.

The **launch check** is `timeout 15 <DerivedData>/Debug/Leo.app/Contents/MacOS/Leo; echo $?`. **124** means the app stayed up (pass). **6** means it died at launch. Run it after any step that touches the window or split.

### 0. Spike: prove the AppKit behavior (throwaway branch, screenshots only)
Build the bare toolbar in `LeoAgentTerminalWindow` and answer each question below with a screenshot from the isolated debug build:
- Does an `NSTrackingSeparatorToolbarItem` bound to the embedded `LeoSplitViewController.splitView` (divider 0) keep the title, subtitle and items over the detail column, with the glass sidebar running full height under the traffic lights? The split is inside a SwiftUI `NSViewControllerRepresentable`, not the window's `contentViewController`.
- With `.fullSizeContentView` and the split ignoring the top safe area, do the sidebar hosting view and the detail and side-pane hosting views receive the toolbar's real top safe-area inset?
- Is a custom-view item drawn on AppKit's own glass platter, and can it be 32 pt tall? If not, set the item to borderless and have the capsule draw `.glassEffect(in: Capsule())` itself.
- Does `borderShape = .capsule` + `selectedSegmentBezelColor` in `.selectAny` mode give two capsule segments, accent-filled with white text, both lit when side by side?
- In native full screen, does the toolbar reveal with the menu bar (standard behavior, no custom presentation options)?
- On macOS 27 (Dionysus), does `SurfaceScrollView`'s `NSScrollPocket` cover terminal text under the toolbar (Ghostty #13390)?

Record the answers in this plan under "Step 0 findings" and commit them before Step 4 starts.

**Gates:**
- If the tracking separator fails, change the split to report its `NSSplitView` to the window controller once it's in the window. A KVO or callback on `LeoWindowSession` is fine. **No `NSSplitViewDelegate` sizing methods.**
- If the native segmented capsule fails, Step 7 builds a custom control.

### 1. LeoKit: primary-order list
- **Files:** `Packages/LeoKit/Sources/LeoKit/Progress/LeoAgentTasks.swift`, adding `ordered(_:) -> [LeoAgentTask]` (every task in primary order, with `ordered(t).first == primary(t)`).
- **Failing test:** `LeoAgentTasksTests`: ordered list for mixed failed/running/ended tasks; the first element equals `primary`; ties break by id.
- **Verify:** `cd Packages/LeoKit && swift test --filter LeoAgentTasksTests`.

### 2. Capsule presentation model (pure)
- **Files:** `macos/Sources/Features/Leo/Progress/LeoActivityCapsulePresentation.swift`.
- **Inputs:** `LeoRowTasks`, `now`, the available width, and an injected `measure: (String, Role) -> CGFloat` text-width closure.
- **Outputs:**
  - `isVisible`: false when there are no tasks.
  - `glyph`: `.spinner` / `.succeeded` / `.failed` / `.cancelled`, from `LeoAgentTasks.primary`.
  - `title` and `statusText`: `LeoTaskDetailText.status`, falling back to `trailing` (percent · ~ETA, elapsed, Done).
  - `bar`: `LeoAgentRowPresentation.Progress.Kind`.
  - `badge`: total count when there are 2 or more tasks, with `isRed` when any task failed.
  - `variant`: `.full` or `.titleOnly`. Status text drops first and the title truncates; spinner, badge and bar always stay; max width 500.
  - `accessibilityLabel`: `<title>, <status>, <n> tasks`.
  - `popover`: summary `"3 · 1 failed"` (the failed part omitted at 0) plus rows in `ordered` order. Each row carries a tile glyph and tint by state, title, bar kind, a status line (`status ?? timing`) and `canDismiss` (`LeoTaskDetailText.canDismiss`).
- **Failing tests:** `LeoActivityCapsulePresentationTests`, one per spec bullet: primary pick, badge count and red-on-failure, narrow-width degradation (fake measurer), VoiceOver label, hidden with no tasks. Also popover summary and order.

### 3. Subtitle data
- **Files:** `LeoSidebarState.swift`, where `LeoAgentRow` gains `harness: String?`, overlaid at emission time the way `appearance` is. Plus the feed that builds rows from the observe snapshot, and a new `Sidebar/LeoAgentWindowSubtitle.swift` with a pure `text(workspace:harness:host:home:) -> String`.
- **Subtitle rules:** `~`-abbreviate a local path; a missing harness leaves the cwd alone; non-agent rows get an empty subtitle.
- **Failing tests:** `LeoAgentWindowSubtitleTests`, plus one feed test that the harness reaches the row.

### 4. Agent window + toolbar skeleton + insets
- **Files:**
  - New `Window Styles/LeoAgentTerminalWindow.swift` (a `TerminalWindow` subclass) and `TerminalLeoAgent.xib` (copied from `Terminal.xib`, class swapped).
  - `TerminalController.windowNibName`: a Leo runtime with decorations on returns `"TerminalLeoAgent"`.
  - New `Leo/Toolbar/LeoAgentToolbar.swift` (`NSToolbarDelegate`). Items: sidebar toggle (`toggleLeoSidebar:`, `isHidden` unless the sidebar is collapsed), tracking separator, flexible space, `.leoActivity` (listed in `centeredItemIdentifiers`), flexible space, `.leoMore`. Settings: `toolbarStyle = .unified`, `titleVisibility = .visible`, `allowsUserCustomization = false`.
  - The controller observes the session's actionable row and sets `window.subtitle`.
  - **Insets:**
    - `LeoTitlebarInsets.splitIgnoredEdges` returns `.top` for `LeoAgentTerminalWindow`, so the glass sidebar reaches the window top.
    - The sidebar header, the detail column and the side-pane headers sit under the toolbar's safe area. `LeoSidebarChromeMetrics.topInset` stays as the gap below it.
    - `TerminalView.terminalIgnoredEdges` stops ignoring the top edge for Leo windows.
    - Remove the hidden-style branch and docs from `LeoTitlebarInsets` and `LeoSidebarSplit`.
- **Failing tests first:**
  - Rewrite `LeoSidebarTitlebarStyleTests` and `LeoSidePaneTitlebarStyleTests`: for every `TitlebarStyle` config value, the window is a `LeoAgentTerminalWindow`; the toolbar has the item identifiers in order with the capsule centered; all three traffic lights are visible; and the sidebar, side-pane headers and terminal top sit `topInset` / 0 below `contentLayoutRect.maxY`.
  - Add a `window-decoration = false` case: no toolbar.
- **Verify:** suites + **launch check** + one screenshot.

### 5. Capsule view and popover
- **Files:** `Progress/LeoActivityCapsule.swift` (SwiftUI) and `Progress/LeoActivityPopover.swift`.
- **Hosting:** the toolbar item's `view = NSHostingView(rootView:)` with `sizingOptions = .intrinsicContentSize`, width constraints ≤ 500 and ≥ the minimum variant, and `visibilityPriority = .high` so the "⋯" item and the title yield first at narrow widths. `item.isHidden = !presentation.isVisible`, so no gap is left.
- **Content:** spinner or glyph, title (semibold) and status (secondary) on a 32 pt capsule, with `LeoTaskBar(kind:, height: 4)` clipped to the bottom edge. The badge is red on failure.
- **Popover:** "Tasks" header with the summary, rows with a 32 pt icon tile, title, bar, status line, and Dismiss only for dismissable tasks via `actions.dismissTask(host:agent:id:)`. There are no stop buttons.
- **Keyboard and accessibility:** a focusable `Button` (Space) plus `.onKeyPress(.return)`, labeled with the model's accessibility label. Reduce Motion: a static glyph replaces the spinner; `LeoTaskBar` is already static.
- A `TimelineView(.periodic(by: 15))` refreshes the ETA text, as the strip did.
- **Tests:** UI styling, verified by screenshot. The model tests from Step 2 cover the behavior.

### 6. "⋯" menu
- **Files:** `Leo/Toolbar/LeoAgentToolbarMenu.swift`, built as an `NSMenuToolbarItem` with an `ellipsis` image.
  - Interrupt, Compact Context and Clear send the Agents-menu selectors (`interruptSelectedLeoAgent:` and its siblings) to the first responder. They copy `keyEquivalent` and modifier mask from the live Agents-menu items, so the shortcuts match, and they validate through `validateLeoControlMenuItem`.
  - "Show Messages ▸" holds All Messages plus `chat.timeline.knownTasks` (sorted), rebuilt in `menuNeedsUpdate`. Each entry calls `chat.setTaskFilter`, and the current filter is checked.
- **Failing test:** `LeoAgentToolbarMenuTests`: titles, selectors and shortcuts equal the Agents-menu items, and Show Messages lists the known tasks.
- **Manual check:** each shortcut fires once, not twice, with the toolbar present.

### 7. Switcher capsule + View menu
- **Switcher** (`LeoAgentControlBar.swift`, `LeoAgentViewSwitch`): `borderShape = .capsule`, `selectedSegmentBezelColor = .controlAccentColor`. If Step 0 failed, build a custom control instead, keeping the "View" label, the selected trait per segment and the tooltips. The unread badge stays.
- **View menu** (`MainMenu.xib`): "Terminal" ⌃⌘1 (`showLeoTerminal:`) and "Chat" ⌃⌘2 (`showLeoChat:`). They go to `TerminalController`, which calls `leoSession.select(_:for:)` for the actionable row, matching a click on that segment. They are disabled with no agent selected and checked when that pane is shown.
- **Failing tests:** `LeoViewMenuTests`: each action routes to `select`; validation works; no other main-menu item uses ⌃⌘1 or ⌃⌘2.

### 8. Removals
- Delete `Progress/LeoTaskStrip.swift`, `Progress/LeoProgressPanelView.swift`, `Progress/LeoProgressPanelModel.swift` and `Tests/Leo/LeoProgressPanelModelTests.swift`.
- `LeoChatPane.swift`: remove the strip overlay (`:34-42`), the progress card overlay (`:53-62`), `header` and `taskFilterMenu` (`:159-209`). Close Chat now lives in the switcher. `viewerHeader` stays.
- Update `LeoChatPaneModelTests` where it references the header or filter.
- Check that `LeoTaskDetailText.trailing`, `LeoWindowVisibilityReader` and `LeoTaskListView` still have callers (they should) before touching them.

### 9. Integration gate
- Check the load average.
- Run the full suite in the background with `heavy` (in-host runner if the console is locked).
- Run `swiftlint lint --strict` and the **launch check**.
- **Screenshots**, light and dark, from the isolated debug build:
  - Use an isolated daemon per memory `isolated-leo-daemon-recipe`, with `LEO_PROGRESS_FIXTURE`.
  - Light mode comes from `background = #ffffff` in the isolated config.
  - Capture with `peekaboo see --capture-engine cg`.
  - If clicks are refused, add a DEBUG-only `LEO_OPEN_ACTIVITY_POPOVER=1`, as `LEO_OPEN_FILE` was done.
  - The 12 shots: (1) one task, (2) three tasks with the popover open, (3) no tasks, (4) a 480 pt narrow window (`peekaboo window resize`), (5) Chat view, (6) full screen. Each is checked against v2-C.png at native pixels.
- Run a fresh-context `review` on `main...HEAD`. Severity bar: P0/P1 and anything a real window can hit.

## Dispatch
- **Step 0:** `implement`, effort high. Spike, screenshots, findings commit.
- **Steps 1–3:** one `implement` at medium, in parallel with Step 0 (they're pure or data-only).
- **Steps 4–8:** one `implement` at high, after the Step 0 findings.
- **Step 9:** the orchestrator runs the gate, then dispatches `review`.

## Removal list
`LeoTaskStrip.swift` · `LeoProgressPanelView.swift` · `LeoProgressPanelModel.swift` + its tests · the strip and card overlays and the chat `header` / `taskFilterMenu` in `LeoChatPane.swift` · the hidden-style inset branch in `LeoTitlebarInsets` / `LeoSidebarSplit` / `TerminalView`. Leo windows stop using the upstream `*TerminalWindow` style classes. Those files stay unmodified.

---

## Open questions (the spec didn't settle these)
1. **`macos-titlebar-style`.** The plan makes Leo windows ignore it, because every style but `native` conflicts with a toolbar. The spec's "today an agent window has a hidden titlebar" fits Evan's laptop config, not the upstream default (`transparent`). Does dropping the key for Leo windows need a docs note or a deprecation?
2. **Remote agents' cwd.** The plan only `~`-abbreviates on the local host and shows the full path for remote hosts. Should it collapse `/home/<user>` or `/Users/<user>` too?
3. **Selected row isn't an agent** (a plain terminal row or the start screen). The plan shows the terminal title, an empty subtitle, and no capsule. Is that right?
4. **"Show Messages ▸" picked while in Terminal view.** It sets the filter but the result isn't visible. Should picking it also switch to Chat? The plan currently only sets the filter. Also, `knownTasks` may be empty until that agent's chat has been opened once.
5. **Capsule secondary text.** The plan uses the task's own status when there is one, else the percent · ~ETA / elapsed text. The mockup shows only the status. Is that the right combination?
6. **Popover icon tiles.** Tasks carry no icon, so the mockup's hammer and upload glyphs can't be reproduced. The plan uses state-based glyphs and tints (running = accent, ✓ green, ⚠ red, ⊘ gray).
7. **VoiceOver label for one task.** The spec says `<n> tasks`. The plan says "1 task", not "1 tasks".
8. **Plan D2 conflicts.** D2's Mac half edits `LeoTaskStrip` and `LeoProgressPanelModel`, which this plan deletes. D2's brief needs re-targeting at the capsule model and popover.

## Orchestrator resolutions (2026-11-04)
1. Leo agent windows ignore `macos-titlebar-style` and always use `LeoAgentTerminalWindow`. The approved spec calls for a real toolbar, and every non-native style conflicts with one. `window-decoration = false` still means no toolbar.
2. A remote cwd also collapses `/Users/<user>` and `/home/<user>` to `~` when the user is the agent host's login. When the user is unknown, show the full path.
3. Yes: a non-agent row shows the terminal title, an empty subtitle, and no capsule.
4. Picking "Show Messages ▸" in Terminal view sets the filter and switches to Chat.
5. Yes: the secondary text is the task's own status, else percent · ~ETA / elapsed.
6. Yes: state-based glyphs and tints.
7. The label is pluralized ("1 task" / "n tasks").
8. Retarget D2's Mac half at the capsule model and popover after this lands. Its LeoKit and iOS parts are unchanged.
