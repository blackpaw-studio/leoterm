# Mac agent window: everything in the toolbar — implementation plan

Spec (source of truth): `docs/specs/2026-11-07-mac-agent-chrome-toolbar-only.md` (approved 2026-11-07). It amends `docs/specs/2026-11-04-mac-agent-toolbar.md`. Mockup: option A, https://claude.ai/artifact/AzeAhQSmTNxRu5gbPE2uN5. **Platform: Mac only.** iOS has no control bar and no terminal composer.
Base: `docs/mac-chrome-toolbar-only` @ `d3a3faf7c`. Toolchain: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`. Never use 26.5.

## Verified facts this plan relies on
- **Where the bar lives.** `TerminalView.swift:155` puts `LeoAgentControlBarHost` under `LeoChatLayoutHost` in a `VStack` inside the detail column's `GeometryReader`. The bar spans both the terminal and a side-by-side chat. The split (`LeoSidebarSplit`) is not touched.
- **What the bar holds** (`Control/LeoAgentControlBar.swift`):
  - In Terminal layouts: `LeoControlPromptField` + Send.
  - Interrupt / Compact / Clear, each folded by width (`LeoControlBarFold`).
  - `LeoAgentViewSwitch`: an `NSSegmentedControl`, `.selectAny`, both segments lit side by side, Chat acts as a toggle via `session.select`. Its unread badge is the `chatSegmentBadge` overlay.
  - The floating `feedbackBanner`: errors, the "Queued" notice, the denied-host Retry.
  - `LeoAgentControlBarContent.chatToggleOnly`: the switch alone, for daemons without `agent_control`.
- **Chat's composer is separate.** It is `Chat/LeoChatComposer.swift` on `LeoChatPaneModel`, not the bar's prompt field. In chat-only layouts the bar already hides its field. Nothing in the bar is needed by Chat, so the whole bar is deletable except the feedback banner, which moves.
- **Message Agent (⌃⌘M).** It goes through `messageSelectedLeoAgent` → `session.requestControlFocus()` → the bar's prompt field. It validates on `\.canSend`. With the field gone it needs a new target (decision D1).
- **Interrupt.** `⌃⌘.` per `MainMenu.xib:607`, so the tooltip is **"Interrupt (⌃⌘.)"**, read from the live menu.
  - It validates through `TerminalController.validateMenuItem` → `validateLeoControlMenuItem(\.canInterrupt)` (`TerminalController.swift:2160`) → `LeoRuntime.controlAvailability(for:)`.
  - `canInterrupt` today means `status == .running && inFlight == nil`. It does not look at `row.activity` (`LeoActivity`: `.working/.idle/.unknown`).
  - `TerminalController` has no toolbar-item validation.
- **View menu.** View ▸ Terminal ⌃⌘1 / Chat ⌃⌘2 → `LeoViewMenuActions` → `session.select`. They stay as they are.
- **Focus on switch.** `LeoWindowSession.choose(.terminal)` already closes the viewer and, on the next turn, runs `routeTerminalFocus { focusTerminal(in:isAllowed:) }` → `Ghostty.moveFocus(to: focusedSurface)`. Every path (toolbar, menu) must go through `session.select`.
- **Toolbar** (`Toolbar/LeoAgentToolbar.swift`):
  - Order: `sidebarToggle, splitSeparator, flex, activity (centred), flex, update, more`.
  - `LeoActivityCapsuleSizing` tiers reserve `moreSideReserve = 56` on the right, and the last tier hides ⋯ (`showsMoreItem`). The spec now requires the trailing items at every width.
  - The update pill (not mentioned in the spec) stays left of the new trailing groups.
  - Wiring happens in `TerminalController+Leo.swift:leoInstallAgentToolbar`.
- **Tests touching what moves:** `LeoControlBarFoldTests`, `LeoAgentControlBarContentTests` (in `LeoChatFeedSignalTests.swift:31`), `LeoAgentControlAvailabilityTests`, `LeoAgentControlModelTests` (drafts/send), `LeoActivityCapsuleSizingTests`, `LeoAgentToolbarActivityTests`, `LeoAgentToolbarMenuTests`, `LeoViewMenuTests`, `LeoChatViewerModelTests:344` (`requestControlFocus`), `LeoChatFocusRoutingTests`, `LeoSidebarTitlebarStyleTests`.

## Decisions settled here (orchestrator may veto)
- **D1 Message Agent.** ⌃⌘M runs `session.choose(.chat, for:)`, which shows Chat and focuses its composer. It validates like View ▸ Chat: enabled when an agent is shown. This keeps "nothing becomes pointer-only" true.
- **D2 Interrupt enabled.** `canInterrupt = running && inFlight == nil && row.activity != .idle`.
  - `.unknown` counts as working, so daemons without activity data keep Interrupt.
  - One rule feeds the toolbar button, ⋯ and Agents ▸ Interrupt.
- **D3 Switch semantics.** Keep today's `.selectAny` behaviour: both segments lit side by side, and clicking Chat while it shows closes it. "Selection-style, not momentary" holds.
- **D4 With no agent shown** (a shell row, or nothing selected): the switch and Interrupt stay in the toolbar, disabled, because the spec says they never appear or disappear. On a daemon without `agent_control` the switch works and Interrupt is disabled.
- **D5 Feedback banner.** Becomes `LeoControlFeedbackBanner`, overlaid at the bottom of the detail column (over terminal or chat). It keeps the zero-height-change rule, so tmux never reflows.

## Steps
Every Swift step is verified from `macos/` in this order:
1. `heavy xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -packageAuthorizationProvider netrc` (in the background).
2. `heavy xcodebuild test-without-building … -only-testing:GhosttyTests/<Suite>`. If the console is locked, use `scratchpad/runtests.sh`.
3. `swiftlint lint --strict --fix`.

The **launch check** is `timeout 15 <DerivedData>/Debug/Leo.app/Contents/MacOS/Leo; echo $?`. **124** means alive (pass); **6** means it died at launch. It is required after steps 4, 5 and 6.

### 0. Spike: AppKit questions (throwaway, screenshots only)
Answer each in the isolated debug build and record the answers under "Step 0 findings" before Step 4:
- Does a custom-view item holding a bordered `NSSegmentedControl` (two SF Symbol segments) draw on the system glass platter at toolbar height? Fallback: `NSToolbarItemGroup(images:selectionMode: .selectAny, labels:target:action:)`.
- Do Interrupt (borderless `stop.circle`) and ⋯ share one glass group, with the switch in its own group? Try adjacency vs an `.space` item between them.
- Does a segment image composed with an accent dot (`stop.circle`-sized template plus a non-template dot) render in light, dark and the selected state?
- Does `NSToolbarItem` autovalidation reach `TerminalController` through the responder chain when `target = nil`?

### 1. Interrupt follows activity (D2)
- **Files:** `Control/LeoAgentControl.swift` (`LeoAgentControlAvailability.init`).
- **Failing test:** `LeoAgentControlAvailabilityTests`.
  - running + `.idle` → `canInterrupt == false`.
  - `.working` and `.unknown` → true.
  - An in-flight verb → false.
  - Compact and Clear are unchanged.
- **Verify:** that suite.

### 2. View-switch presentation (pure)
- **Files:** new `Toolbar/LeoViewSwitchPresentation.swift`.
- **Inputs:** `LeoChatLayout?` (nil = no agent) and the unread count.
- **Outputs:**
  - `isEnabled`.
  - `selected: Set<LeoAgentViewChoice>` (from `activeSegments`).
  - `showsUnreadDot`: unread > 0 and chat not showing.
  - `chatAccessibilityLabel`: "Chat" / "Chat, n unread".
  - Tooltips "Terminal" / "Chat"; group label "View".
  - The click mapping moved out of `LeoAgentViewSwitch.Coordinator`: `clicked(segmentStates:) -> LeoAgentViewChoice?`.
- **Failing tests:** `LeoViewSwitchPresentationTests`, one per bullet: no agent, side by side both lit, dot hidden while chat shows, VoiceOver label at 0, 1 and 12 unread, click mapping.

### 3. Sizing: trailing items never fold
- **Files:** `Toolbar/LeoActivityCapsuleSizing.swift`.
  - Replace `moreSideReserve` with `trailingGroupsReserve` (switch + Interrupt + ⋯ + group gaps, measured in Step 0).
  - Drop `showsMoreItem` and the bare tier.
  - Below the minimum the capsule shrinks to `minimumWidth`, which is the floor.
- **Also:** `LeoAgentToolbar.updateActivityWidth` stops hiding ⋯.
- **Failing tests:** rewrite `LeoActivityCapsuleSizingTests`.
  - At 480 pt the window still reserves the trailing groups.
  - Degradation order: subtitle → update pill → title → capsule width.
  - `showsMoreItem` no longer exists.

### 4. Toolbar items
- **Files:** `Toolbar/LeoAgentToolbar.swift`.
  - Add `.leoViewSwitch` and `.leoInterrupt`. New `itemOrder`: `… flex, update, viewSwitch, [space?], interrupt, more`.
  - `makeViewSwitch` uses an AppKit `LeoToolbarViewSwitch` (an `NSSegmentedControl` subclass, `refusesFirstResponder = true` so a click never takes focus from the surface).
  - `bind(viewSwitch: some Publisher<LeoViewSwitchPresentation, Never>, select:)`.
  - `makeInterrupt`: `NSToolbarItem`, image `stop.circle`, `action = #selector(TerminalController.interruptSelectedLeoAgent(_:))`, `target = nil`, `visibilityPriority = .high`, tooltip from the live Agents menu item.
  - Move `LeoAgentToolbarMenu.findItem` to a shared helper.
  - Both new items get `visibilityPriority = .high`, and `isHidden` is never set on them.
- **Failing tests:** extend `LeoAgentToolbarActivityTests` (or a new `LeoAgentToolbarTrailingTests`).
  - The order puts `viewSwitch, interrupt, more` last.
  - Interrupt is present and disabled with no agent.
  - Its tooltip reads "Interrupt (⌃⌘.)" from a fake main menu.
  - The switch reflects a pushed presentation (selection, enabled, accessibility label, dot image).
  - Clicking segment 1 calls `select(.chat)`.
  - Update `LeoSidebarTitlebarStyleTests` for the new identifier order.
- **Verify:** suites + **launch check**.

### 5. Wiring, validation and focus
- **Files:**
  - `Integration/TerminalController+Leo.swift`: bind the switch from `leoSelectionChanges` + `session.$viewChoices` + `runtime.unread.$counts` + layout. `select` → `session.select(_:for:)`.
  - `TerminalController.swift`: adopt `NSToolbarItemValidation`, with `validateToolbarItem` routing `interruptSelectedLeoAgent` → `validateLeoControlMenuItem(\.canInterrupt)`.
  - Call `window.toolbar?.validateVisibleItems()` on `leoSelectionChanges`, `control.$inFlight`, **and changes to the selected row's status/activity** (the test below depends on the last one). Autovalidation alone only runs on window events, so an activity flip from the daemon would leave the button stale.
- **Failing tests:**
  - `LeoAgentToolbarTrailingTests`: on a controller with a fake runtime, flipping the row `.idle` → `.working` then publishing leaves Interrupt `isEnabled == true` without any window event, and back again.
  - `LeoChatFocusRoutingTests`/`LeoContentFocusTests`: a switch click to Terminal ends with the terminal surface as first responder, and the segmented control never is.
- **Verify:** suites + **launch check**.

### 6. Remove the bar; move the banner; reroute Message Agent
- **Files:**
  - `Terminal/TerminalView.swift`: drop `LeoAgentControlBarHost` from the `VStack`. Overlay `LeoControlFeedbackBanner(row:control:)` at the bottom of `LeoChatLayoutHost`.
  - New `Control/LeoControlFeedbackBanner.swift`, built from `feedbackBanner`.
  - `Integration/LeoAgentControlMenuActions.swift`: `messageSelectedLeoAgent` → `session.choose(.chat, …)` (D1).
  - `TerminalController.swift:2158`: validates like `showLeoChat`.
- **Failing tests:**
  - `LeoViewMenuTests`: Message Agent shows Chat, requests chat focus, and is enabled whenever an agent is shown.
  - Delete `LeoControlBarFoldTests` and `LeoAgentControlBarContentTests`.
  - Update `LeoChatViewerModelTests:344` to drop `requestControlFocus`.
- **Verify:** suites + **launch check** + one screenshot (the terminal reaches the window's bottom edge).

### 7. Delete dead code (separate commit)
- **Delete:**
  - `LeoAgentControlBar`, `LeoAgentControlBarHost`, `LeoAgentViewSwitch` (whole of `LeoAgentControlBar.swift`).
  - `LeoControlBarFold.swift`, `LeoControlPromptField.swift` (+ handle), `LeoAgentControlBarContent`.
  - `chatSegmentBadge`. `LeoUnreadCountBadge` stays for the sidebar.
  - In `LeoWindowSession`: `controlPrompt`, `controlFocusRequest`, `requestControlFocus`.
  - In `LeoAgentControlModel`: `drafts/setDraft/canSendDraft/send/maxMessageBytes`.
  - In availability: `canCompose/canSend/reason`, if nothing else reads them.
- **Keep:** `LeoAgentControlModel` interrupt/compact/clear/inFlight/feedback/deniedHosts/retry, `LeoClearConfirmation`, `LeoAgentControlAvailability.isOffered/canInterrupt/canCompact/canClear`, `LeoViewMenuActions`.
- **Tests:** prune the drafts/send cases from `LeoAgentControlModelTests`. Nothing new; the build is the check.

### 8. Chat composer restyle (no test: UI styling)
- **Files:** `Chat/LeoChatComposer.swift`.
  - Replace the full-width `.bar` strip with a rounded field (continuous corner radius, quaternary fill + hairline stroke) inset from the pane edges.
  - Send goes inline, trailing inside the field. Paperclip and mic stay inside the field.
  - Reply banner and attachments sit above it.
- **Verify:** screenshot light and dark, side by side and chat-only.

### 9. Integration gate
1. Check load average.
2. Full suite under `heavy`.
3. **Launch check.**
4. Screenshots.
5. `swiftlint lint --strict --fix`.
6. Fresh-context `review` of `git diff d3a3faf7c...HEAD`. Severity bar: P0/P1 plus anything a real user hits.

## Risks
- **NSSplitViewController launch crash.** No step may add `NSSplitViewDelegate` sizing methods or touch `LeoSidebarSplit`/`LeoSplitViewController` sizing. Removing the bar only changes the detail column's `VStack`. A green suite cannot catch a launch crash, so the launch check is mandatory after steps 4–6 and at the gate.
- **Disabled Interrupt validation.** Toolbar autovalidation runs on window update events, not on model changes. Without the explicit `validateVisibleItems()` (Step 5) the button stays stale after a daemon activity flip. The item also needs `target = nil` plus `validateToolbarItem` on `TerminalController`. `NSMenuItemValidation` alone does not cover toolbar items.
- **Toolbar overflow.** A custom-view item that doesn't fit goes to the chevron at its preferred width, so sizing (Step 3) must reserve the trailing groups explicitly. Check at 480 pt.
- **Focus theft.** A first-responder segmented control would swallow keystrokes after a click (`refusesFirstResponder`, Step 4). Terminal focus must go through `routeTerminalFocus`, never directly.
- **Keystrokes in the debug app.** Before sending any key, filter to the autopilot-scratch agent and screenshot to confirm focus (memory: `debug-app-keystroke-safety`).

## Final screenshots (isolated debug build, light and dark each: 10 total)
1. Terminal view (terminal running to the bottom edge; switch, Interrupt and ⋯ in the toolbar).
2. Chat view with unread (accent dot on the Chat segment, restyled composer).
3. Agent idle (Interrupt disabled).
4. A 480 pt narrow window (capsule degraded, trailing items visible).
5. Full screen.
