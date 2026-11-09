# Plan: HIG-native sidebar progress indicator

- Spec (source of truth): `docs/specs/2026-11-09-sidebar-progress-indicator.md`
- Mockup: `docs/mockups/2026-11-09-sidebar-progress/options.html`. The intended behaviour is in its `indicator()` function and `RENDER.native`.

**Platform call: both.**
- The rules for what a row shows live in LeoKit. Each app keeps only its drawing and glue.
- **Mac:** `NSProgressIndicator`, with an AppKit click target that opens the popover.
- **iOS:** `UIActivityIndicatorView` or a custom pie as the cell's trailing accessory. There is no popover; tapping the cell pushes the detail view as today. The iOS Tasks panel keeps its bars.

## Decisions (orchestrator, settling the spec's gaps)

1. **Stale task with no percent:** show a muted, empty pie.
2. **"and N more":** N counts the other running tasks, stale ones included. Ended tasks are not counted.
3. **Failed glyph on the selected row:** draw it white, like the other sidebar accessories. Everywhere else it stays red.
4. **When each platform hides progress:** keep today's rules. iOS hides it for stopped agents and agents that need attention. Mac hides it only while the agent needs input. Aligning the two is out of scope.
5. **VoiceOver with several tasks:** read the primary task's title plus the mean percent, for example "Screenshot sweep and 2 more, 47 percent".

## Commands

- **LeoKit:** `cd Packages/LeoKit && swift test --filter <Suite>`
- **iOS models:** `cd ios/LeoFeatures && swift test --filter <Suite>`
- **Mac app:** run from `macos/` as a background `heavy` job.
  - Build: `heavy xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -packageAuthorizationProvider netrc`
  - Test: `heavy xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:GhosttyTests/<Suite>`
- **Lint:** `swiftlint lint --strict --fix`

## Step 1 — LeoKit row-task presentation (test-first)

New file: `Packages/LeoKit/Sources/LeoKit/Progress/LeoTaskRowPresentation.swift`

```swift
public enum LeoTaskIndicator: Equatable, Sendable {
    case progress(fraction: Double?)   // rule 1: live; nil = indeterminate spinner
    case stalled(fraction: Double?)    // rule 2: muted, still; nil = empty muted pie
    case failed                        // rule 3
}

public struct LeoTaskRowSummary: Equatable, Sendable {
    public let indicator: LeoTaskIndicator?  // nil = rule 4: the platform's own trailing (elapsed time)
    public let detail: String?               // nil = fall through to the next detail source
    public let tooltip: String               // LeoTaskText.summary(primary) [+ ", N more"]
    public let spokenValue: String?          // "Build Leo.app, 62 percent" | "In progress" | "Stalled" | "Failed"
}

public enum LeoTaskRowPresentation {
    /// Returns nil only when there are no tasks.
    public static func summary(_ tasks: [LeoAgentTask], etaAt: [String: Date],
                               agentIsInError: Bool, now: Date) -> LeoTaskRowSummary?
}
```

**Rules**

- A task is **live** when it is running and not stale (`isRunning && !stale`).
- A task is **determinate** when `mode == .determinate` and its percent is set. A determinate task with no percent counts as indeterminate.
- The **live fraction** is the mean percent of the live determinate tasks, divided by 100.
- For the **stalled** indicator, use the stale task updated most recently.
- **Rule 3** (the failed glyph) applies only to an undismissed failed task, and only when `!agentIsInError`.

**Detail text**, chosen from `LeoAgentTasks.primary`:

| Primary task | Detail |
|---|---|
| Running | its title, or `<title> and N more` (see decision 2) |
| Stale | `<title> · no update for <LeoTaskText.duration(now - updatedAt)>` |
| Failed | `Failed: <title>` |
| Succeeded or cancelled | nil |

**Tests** go in a new file, `Packages/LeoKit/Tests/LeoKitTests/LeoTaskRowPresentationTests.swift`. Each one fails first because the type does not exist yet. Cases:

- A live determinate task.
- Determinate and indeterminate tasks together: the mean uses only the determinate ones.
- Only indeterminate tasks.
- Only a stale task: stalled pie plus the stale text.
- A stale task with no percent: an empty stalled pie.
- A failed task while the agent is not in error.
- A failed task while the agent is in error: the indicator is nil and the detail still reads `Failed: …`.
- A failed task plus a live task: rule 1 wins.
- A succeeded or cancelled task: falls through, with nil detail and nil indicator.
- Several running tasks: "and 2 more", with ended tasks not counted.
- A determinate task with no percent.
- The spoken values, including the several-task case from decision 5.

**Verify:** `swift test --filter LeoTaskRowPresentationTests`

## Step 2 — Mac row presentation (test-first)

Files: `macos/Sources/Features/Leo/Sidebar/LeoAgentRowPresentation.swift` and `LeoRowTasks.swift`.

- Replace `Progress {kind, extraBadge, accessibilityLabel}` with `task: LeoTaskRowSummary?`.
  - Pass `agentIsInError: resolved.state == .error`.
  - Keep the `needsInput` gate.
- Keep `Progress.Kind`. The capsule, the popover and `LeoTaskListView` still use it.
- `Detail.progress` uses `task?.detail`. When that is nil, the existing detail chain falls through as before.
- `detailInk` is red when the detail reads `Failed: …`.
- Add `symbolRotates`. It is `state.rotates`, except that it is false while the indicator is `.progress` or `.stalled`. Pass it to `LeoAgentStateSymbolView`.
- Set `hasSecondLine = state.hasSecondLine || task != nil`, so the row doesn't change height when a task succeeds.

**Tests:** rewrite `macos/Tests/Leo/LeoAgentRowProgressPresentationTests.swift` for the new detail strings and the indicator.

- Add a test that the working symbol is still while an indicator shows and spins when none does.
- Add a test that an agent in error with a failed task gets a nil indicator.
- Keep the test that `needsInput` hides the task.
- Delete the `extraBadge` test.

**Verify** with `-only-testing:` on these four suites:

- `GhosttyTests/LeoAgentRowProgressPresentationTests`
- `GhosttyTests/LeoAttentionPresentationTests`
- `GhosttyTests/LeoAgentRowPresentationTests`
- `GhosttyTests/LeoAgentMetadataTests`

## Step 3 — Mac row view (UI styling, so no test-first)

**Files**

- `LeoAgentRowContent.swift`
- `LeoAgentStateSymbolView.swift`
- `LeoAgentRow.swift`
- `LeoAgentRowMetrics.swift`
- `LeoRowClickCatcher.swift`
- New: `macos/Sources/Features/Leo/Progress/LeoTaskIndicatorView.swift`

**Spike R1 first** (see Risks).

**`LeoTaskIndicatorView`** wraps an `NSProgressIndicator` with style `.spinning`, control size `.small`, and `isDisplayedWhenStopped = true`.

- **Determinate:** set `doubleValue`.
- **Indeterminate:** call `startAnimation`, unless Reduce Motion is on, in which case show the spokes without animating.
- **Stalled:** still, in a muted tint.
- **Failed:** the SF Symbol `exclamationmark.circle.fill`, red, or white on the selected row.
- **Selected row:** white.
- Update the view in place in `updateNSView`. If it is recreated on each of the row's `TimelineView` redraws, the spinner restarts.

**Row changes**

- In `trailing()`, the indicator replaces the elapsed time. Rule 4 keeps the time. A pending action's spinner still wins over both.
- The indicator sits in a 20×20 pt frame:
  - Overlay `LeoTaskBarClickTarget` so a click opens the existing popover.
  - Set `.help(tooltip)`.
  - Hide the indicator itself from VoiceOver. The row's combined element gets `accessibilityValue(spokenValue)` and a named "Show Tasks" action.
- Click catcher:
  - Remove `bottomExclusion`, `hasTaskBar` and `taskBarHitHeight`.
  - Add an exemption: a click whose `window.contentView?.hitTest` lands in `LeoTaskBarClickTarget.TargetView` (or a marker protocol, `LeoRowClickExempt`) counts as outside the row. Write this one test-first in `LeoRowClickCatcherTests`.
  - Prune the bottom fields of `LeoRowClickRegion` if nothing else uses them. Grep first.
- Delete `progressBar(...)` and the `+N` capsule in `detailLine`.

**Verify with tests**

- `LeoAgentRowHeightTests`: update the expectations, since rows with a task are now shorter.
- `LeoRowClickCatcherTests`
- `LeoRowClickRegionTests`
- `LeoTaskBarClickTargetTests`

**Verify by running the app.** Run the debug app with `LEO_PROGRESS_FIXTURE`, using a fixture that covers these states:

- live determinate
- determinate and indeterminate together
- indeterminate only
- stale
- failed, agent not in error
- failed, agent in error
- several running
- succeeded

Then:

1. Capture each state in light mode, in dark mode, and with the row selected. Use Peekaboo with `--capture-engine cg`.
2. Record a short capture and confirm each row has exactly one moving element.
3. Repeat with Reduce Motion on.
4. Click the indicator and confirm the popover opens and the row is not selected.

Before sending any keystroke to the debug app, filter to the scratch agent and take a screenshot to confirm focus.

## Step 4 — iOS model (test-first)

File: `ios/LeoFeatures/Sources/LeoFeatures/Models/AgentProgress.swift`

- Rebuild `AgentProgress` as `{text: String?, indicator, spokenValue, tooltip}`, built from `LeoTaskRowPresentation.summary(..., agentIsInError: attention == .errored)`.
- Keep the existing gate for stopped agents and agents that need attention (decision 4).
- Drop `badge`.
- Keep `Agent.style(of:)` and `taskDetailLine`. The Tasks panel and the detail view use them.

**Tests:** rewrite `ios/LeoFeatures/Tests/LeoFeaturesTests/AgentProgressTests.swift`.

**Verify:** `cd ios/LeoFeatures && swift test --filter AgentProgressTests`

## Step 5 — iOS cell (UI, so no test-first)

Files: `ios/Leo/Agents/AgentsViewController.swift` and a new `ios/Leo/Progress/TaskIndicatorView.swift`.

**`TaskIndicatorView`**

- **Indeterminate:** `UIActivityIndicatorView(.medium)`. It does not animate when Reduce Motion is on.
- **Determinate:** a pie of the same size, drawn with a `CAShapeLayer`.
- **Stalled:** the same pie in `secondaryLabel`.
- **Failed:** `exclamationmark.circle.fill` in `systemRed`.

**Cell changes**

- Add the indicator as a `.customView` trailing accessory, placed before the disclosure indicator.
- Set `secondaryText = progress?.text ?? agent.summary`.
- Remove the Agents list's `showBar` call and the `+N` `BadgeView`.
- Add `spokenValue` to the cell's `accessibilityValue`.
- `ProgressListCell` and `TaskBarView` stay, because the detail view and `TaskPanelView` still use them.

**Verify**

- Build for the simulator and take screenshots in light and dark mode through the `xcode-remote` skill.
- `TaskPanelViewTests` and `TaskScreensTests` still pass.

## Step 6 — Dead code and integration gate

**Remove** each of these, grepping for other users first:

- `LeoTaskText.extraBadge` and its test in `LeoTaskTextTests`
- `LeoAgentTasks.extraCount` and its case in `LeoAgentTasksTests`
- `LeoRowTasks.extraCount`
- `LeoAgentRowMetrics.taskBarHitHeight`

**Keep** `LeoTaskBar` and `LeoTaskBarFill`. The capsule, the popover and the task list still use them.

**Gate** (check the load average first):

- The full LeoKit and LeoFeatures `swift test` runs.
- The full Mac `GhosttyTests` suite under `heavy`.
- `swiftlint lint --strict --fix`.

## Risks

**R1: the selected-row tint may not reach the indicator.**

- `NSProgressIndicator` hosted in SwiftUI may not pick up the selected row's white styling. It also has no public tint for the muted stalled state.
- Spike this first in step 3.
- Fallback: draw the determinate and stalled pies in SwiftUI at 16 pt. Keep `NSProgressIndicator` only for indeterminate, made white through its `appearance` (or use `ProgressView().controlSize(.small)`).
- Record which path was taken in the commit message.

**R2: row redraws must not recreate the indicator view, or the spinner restarts.**
