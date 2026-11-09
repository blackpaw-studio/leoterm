# Sidebar task progress: HIG-native trailing indicator

Status: approved by Evan (2026-11-09)
Mockup: `docs/mockups/2026-11-09-sidebar-progress/options.html` (published at https://claude.ai/artifact/7R3n8SNioPMo4pxuMvxnyd)
Supersedes the row treatment in `docs/specs/2026-11-03-agent-progress.md` (row bar only). The data model, daemon contract, popover, toolbar capsule and notifications are unchanged.

## Problem

The agent row draws a 3 pt bar plus a `title · status · 62% · 4m` string and a `+N` capsule. In a busy sidebar this reads as jumbled. It also breaks the HIG (`progress-indicators`, `sidebars`):

- Constrained space should use a small circular indicator with no label.
- Completed indicators should not persist. Today the done bar lingers for up to 10 minutes.
- Indicators should not stand still. Today the indeterminate bar is static.
- Colour in a sidebar should be sparse. Today the row uses blue, green, red and grey fills.

## Design (Mac)

The row keeps two lines: the name line and the detail line. The bar row is removed, so rows are 5 pt shorter.

**Trailing slot on the name line.** This is the slot where the elapsed time sits today. It shows the first match below:

1. At least one live task (running, not stale):
   - A small `NSProgressIndicator` in spinning style.
   - It is determinate (a pie) when any live task is determinate. The value is the mean percent of the live determinate tasks.
   - Otherwise it is the indeterminate system spinner.
2. A stale task and no live task: a determinate pie at its last percent, drawn in a muted (secondary) tint, with no animation.
3. An undismissed failed task, while the agent itself is not in its error state: a red `exclamationmark.circle.fill` at the same size. If the agent is in its error state, the leading symbol already shows the failure and the slot falls through to 4.
4. Otherwise: the elapsed time, as today.

The trailing slot has no percent text and no `+N` capsule.

**Detail line.** The existing precedence (attention, error, environment warning, then progress) is unchanged. The progress text becomes:

| Situation | Text |
|---|---|
| Running | the task title, nothing else |
| Several running | `<primary title> and N more` |
| Stale | `<title> · no update for <elapsed since last update>` |
| Failed | `Failed: <title>` |
| Succeeded or cancelled | no progress text; fall through to the next source |

**Leading state symbol.** When the trailing slot shows an indicator (cases 1 and 2), the working symbol is drawn static. The indicator carries the motion. With no task the symbol spins as today. Each row has at most one moving element.

**Interaction.** Clicking the indicator opens the existing task popover, which still shows percent, status, ETA and Dismiss. The bar's click target moves to the indicator with a hit area of at least 20×20 pt. The tooltip carries today's full summary string.

**Selected row.** The indicator draws in white on the accent highlight, like other sidebar accessories.

**Accessibility.**
- The row's VoiceOver value includes `Build Leo.app, 62 percent`, `In progress`, `Stalled` or `Failed`.
- Reduce Motion stops the spinner animation (static spokes). The pie still updates its value.

## Design (iOS)

**Call: both platforms.** The same problem applies to the iOS agent cell's 3 pt bar (`ios/Leo/Progress/TaskBarView.swift`).

- The selection rules (which indicator, which text) move into LeoKit next to `LeoAgentTasks`, so both apps share one presentation function.
- iOS draws a small circular indicator in the cell's trailing area. Indeterminate uses `UIActivityIndicatorView` (`.medium`). Determinate uses a custom pie of the same size, because UIKit has no circular determinate view.
- The iOS Tasks section and floating panel keep their bars. Those are detail surfaces with room for them.

## Out of scope

- Toolbar capsule, task popover, iOS Tasks panel.
- Daemon linger times.
- B-361 (capsule title truncation).

B-362 (faint done bar) becomes moot for the row and stays open only if the popover shows the same problem.

## Acceptance

- The row shows no bar. The trailing slot follows rules 1–4.
- The detail text matches the table above.
- Selected, light and dark modes render correctly.
- A row with a running task has exactly one animating element.
- With Reduce Motion on, nothing animates.
- Clicking the indicator opens the popover.
- Unit tests cover the shared presentation function (live, mixed, stale, failed-without-agent-error, succeeded fallthrough).
- Verified with windowed Mac screenshots and an iOS simulator screenshot of the user's scenario.
