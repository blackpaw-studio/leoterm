# Agent Bottom Pane — plugin surface spec

Date: 2026-11-12 · Status: draft for approval · Platform call: **Mac only** (plugins are Mac-only in v1) · Extends: `2026-11-10-plugin-platform.md` · Mockups: https://claude.ai/artifact/T846yipP8vwhhy46TUWsdL (option C)

## Goal

Give plugins a pane under the agent's terminal/chat view. Collapsed, it is a one-line strip of plugin summaries. Expanded, it is a tabbed drawer with one tab per plugin. The first consumers are the Status plugin (`2026-11-12-status-plugin.md`) and the GitHub plugin.

## Layout and behaviour

- The pane sits under the detail column (terminal or chat) of the selected agent and follows the selection. It has two states:
  - **Collapsed:** a 30pt tab bar. Each tab shows the plugin's title and its **summary** render.
  - **Expanded:** the tab bar plus the selected tab's **body** render, in a drawer that can be resized vertically (min 120pt, max 50% of the column, default 184pt).
- Clicking a tab expands the drawer to that tab. Clicking the selected tab, or the chevron, collapses it. A View menu item, "Toggle Agent Pane", toggles it. There is no default shortcut in v1, so no Ghostty key is taken, but users can bind one through macOS menu shortcuts.
- The expanded state, the selected tab and the height are remembered app-wide, not per agent.
- When no enabled plugin contributes a pane, nothing is drawn: no empty strip.
- Tab order: first-party plugins first, then install order. Settings → Plugins can hide a plugin's pane, like hiding a sidebar section.
- If the summaries overflow the width, the selected tab keeps its summary and the others drop to their title only. If even the titles don't fit, the extra tabs collapse into a "+N" menu.

## Manifest

`contributes.panes: [{id, title, sfSymbol?}]`, at most one per plugin in v1. An unknown key is refused, as today.

## Renders

- The plugin calls `leo.render("<paneId>.summary", tree)` and `leo.render("<paneId>.body", tree)`. The summary slot only accepts `Text`, `Meter` and `Accessory`, laid out in one row. Any other component is rejected as a render error, shown as a "!" in place of the summary.
- The body accepts every existing component plus `Text` and `Meter`.
- Visibility for `leo.after` and refresh: a summary is visible whenever the pane is shown, and a body only while its tab is expanded. Both use the existing ref-counted visibility reporter.

## New components (available in every slot)

- **`Text`:** an inline row of runs. Each run is `{text, tone?, weight?: regular|semibold, mono?: bool}`. `tone` is a semantic colour token from a fixed palette: `secondary`, `accent1`…`accent6`, `success`, `warning`, `failure`. There are no raw hex colours, so the system can map tones to light and dark mode. A run holds at most 200 characters and a `Text` at most 20 runs.
- **`Meter`:** a horizontal bar made of up to 8 segments `{value, tone}`, with a total `max`, an optional `label` and an optional `help` tooltip of at most 80 characters. In a summary it is drawn 56pt × 5pt, and in a body it fills the available width.

## Bridge additions

- `leo.agents.usage(agentName)` returns the latest usage snapshot, or `null`. It requires the new permission `agents: ["usage"]`. Fields:
  - available today: `model`, `context {tokens, window, percent}`, `session {tokens, costUsd}`;
  - optional, filled in as the daemon adds them (`2026-11-12-agent-telemetry-request.md`): `effort`, `context.breakdown {system, tools, mcp, memory, messages}`, `context.compactAt` (a fraction 0–1), `rateLimits [{kind: "five_hour"|"seven_day", percentUsed, resetsAt}]`, `git {added, removed}`.
  - Unknown fields are dropped, and absent ones stay absent rather than being zero-filled.
- `leo.on("usageChanged", fn(agentName))` comes from the daemon's `agent_usage` and `agent_turn_completed` events. It is coalesced to at most 1 per agent per second, and fires only while one of the plugin's panes is visible.
- `leo.agents.list()` entries gain `model`, behind the same `usage` permission.

## Errors

- A pane whose plugin crashed or was disabled shows its title with a warning glyph. Its body shows the platform's existing Error and Retry state.
- A render error in the summary shows "!" with the error in a tooltip.

## Testing

- **LeoKit:** decoding the manifest `panes` key; the summary allowlist; validation of `Text` and `Meter` (limits, unknown tones); mapping usage snapshots, including absent optional fields; the permission gate for `usage`; event coalescing, tested with an injected clock.
- **App:** the collapse and expand state machine; overflow from summaries to titles to "+N"; persistence of the expanded state, selected tab and height.
- **UI:** a fixture plugin's pane in collapsed, expanded and overflow states, in light and dark mode, inspected at native pixels.

## Out of scope

- More than one pane per plugin.
- Panes on iOS.
- Dragging tabs to reorder them.
- Per-agent pane state.
- Plugin-defined colours.
