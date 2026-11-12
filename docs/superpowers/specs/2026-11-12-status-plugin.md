# Status Plugin — v1 Spec

Date: 2026-11-12 · Status: draft for approval · Platform call: **Mac only** · Depends on: `2026-11-12-agent-bottom-pane.md`, and progressively on `2026-11-12-agent-telemetry-request.md`

## Goal

Replace the in-terminal `rich-statusline` Claude Code plugin with a first-party Leo plugin. It uses only the public plugin API and draws natively in the agent bottom pane.

## Manifest

- id `studio.blackpaw.status`, bundled with the app and enabled by default.
- Permissions: `agents: [read, usage]`. No network, no secrets.
- Contributes: pane `status` ("Status", `gauge`).

## Summary (collapsed strip)

`Opus 5.5 ▬ 21% · 5h 3% · $35.36`

- **Model:** tone `accent1`.
- **Meter:** context share by category when the breakdown is known, otherwise a single segment for the total. The meter's `help` shows the token count.
- **Percentages:** the context % appears in the summary, and the 5h limit % appears only when present.
- **Cost:** shown only when present.
- **Empty states:** before the first response the summary is `—`, and for a harness that reports no usage it is `No usage data`.

## Body (expanded)

Four labelled rows matching rich-statusline. Any missing field is hidden, never shown as 0.

1. **Model:** model name, plus `thinking <effort>` when effort is known.
2. **Where:** the agent's workspace path shortened the same way as rich-statusline (`~/.l/a/leoterm`), the branch, and `(+N,−M)` when git stats are known.
3. **Context:**
   - The full-width Meter has segments sys, tools, mcp, mem and chat in tones accent1–accent5, and free space as the unfilled remainder.
   - The total % is on the right.
   - A legend line shows each category's tokens (`29k`), the free tokens, and `compacts at 37%` when `compactAt` is known.
4. **Limits:** `session N% resets 3h 50m` and `weekly N% resets 4d 2h`, using relative times from `resetsAt`, then the cost.

The PR is not shown here; the GitHub plugin's tab covers it.

## Behaviour

- It refreshes on `usageChanged` for the selected agent and on `viewOpened`. Reset countdowns tick through `leo.after(60)` while the pane is visible.
- **Number formatting:**
  - tokens: `3.1k`, `154k`, `1.2M`
  - percentages: one decimal place in the body, none in the summary
  - money: `$35.36`
- All formatting lives in pure functions that are unit-tested.

## Testing

- Vitest with a stubbed `leo` and an injected clock.
- Formatting and path shortening.
- Choosing summary segments when fields are present or absent.
- Body rows hidden per missing field.
- Relative reset times.
- Byte-deterministic bundle, as with the GitHub plugin.
- **E2E:** a live agent in an isolated debug app, with the pane collapsed and expanded, in light and dark mode.

## Out of scope

- Turning off rich-statusline in Claude Code. That is Evan's call once this is live.
- Showing the PR.
- History or charts.
