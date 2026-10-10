# Sidebar rows: state pill + role-chip dispatches

Mockup: https://claude.ai/artifact/3eaFbdbsquh6nsGR4pBtnM (option A1, tinted role chips).

## Goal

Replace the three-line agent row (whose third line is usually empty) with a
two-line row led by a coloured state pill, and restyle live dispatch rows as
one-line tree children with a tinted role chip. Every row keeps a constant
height across tool calls.

## Agent row (`LeoAgentRowView`)

Two lines, `VStack(spacing: 4)`, row vertical padding 7pt.

**Line 1:** name (`.body` medium, search highlights unchanged) · surfaced-files
glyph (if any) · trailing relative time from `metadata.lastActiveAt`
(`.caption`, tertiary, monospaced digits). A pending action replaces the time
with a small `ProgressView`.

**Line 2:** state pill, then one detail string (`.caption`, secondary,
one line, tail-truncated, full text in `.help`).

### State pill

Capsule, `.caption2` semibold, SF Symbol + word, tint at 15% fill (light) /
20% (dark), text in the tint. Selected row: white text on white 22%.
Resolution, first match wins:

| State | When | Word | Symbol | Tint |
|---|---|---|---|---|
| Needs you | attention `needsInput` | Needs you | reason symbol (`hand.raised`, `questionmark.bubble`, `list.bullet.rectangle`), else `questionmark.circle` | orange |
| Error | attention `errored`, or row `error` set | Error | `exclamationmark.triangle.fill` | red |
| Done | attention `finished` | Done | `checkmark` | green |
| Starting | status `starting` | Starting | `ellipsis` | gray |
| Stopped | status `stopped` | Stopped | `stop.fill` | gray, outline (no fill) |
| Unknown | status `unknown` | Unknown | `questionmark` | gray |
| Compacting | `compaction` set | Compacting | existing compaction symbol | indigo |
| Working | attention `working` or activity `working` | Working | existing working symbol | blue |
| Idle | otherwise | Idle | `moon.fill` | gray |

Stopped rows dim the name to secondary.

### Detail precedence

attention reason (`tool: detail`) → error text (red) → task → tool
(`Tool name`) → turn preview (`Interrupted: …` when aborted) → fallback
`template · $session cost` in tertiary. Line 2 is never blank. Compaction's
copy now lives in the pill, so it drops out of the detail chain.

### Removed

Activity dot, trailing attention badge, trailing status badge, the
`template · state · usage · time` subtitle, and the third detail line. Usage
and template stay in the row's `.help` tooltip and the fallback detail.

## Dispatch row (`LeoDispatchRowView`)

One line, 22pt tall. Tree guide (1.5pt, separator colour, rounded elbow)
replaces `arrow.turn.down.right`; continuing siblings draw the vertical
through-line. Indent rules unchanged.

Content: role chip · name (`.callout`, tail-truncated) · nested-tree
chevron (unchanged behaviour) · trailing status.

- **Role chip:** role text, `.caption2` semibold, 4pt corner radius, tint at
  15%/20%. explore = cyan, plan = brown, implement* = purple, review* = mint,
  anything else or no role = gray. Role families match on the part before the
  first "." (`review.security` is a review). Pink is avoided: it reads as the
  Error red. No role → chip omitted, name falls back as today.
- **Trailing status:** 6pt dot + elapsed since `startedAt` in minutes
  (`<1m`, `4m`, `1h 12m`; `.caption2`, tertiary, monospaced digits).
  Running = blue dot that pulses (static under Reduce Motion); queued =
  hollow gray; idle/settling = gray; stalled = orange dot + "Stalled 31m" in
  orange. No `startedAt` → status word instead of elapsed.
- Selection/attachability, click handling and collapse unchanged.
- Accessibility label: "`<role>` dispatch `<name>`, `<status>`" (nested:
  "nested `<role>` dispatch …").

Dispatches never get a filled pill; only the parent agent signals
attention.

## Tests

- Row height: every pill state × detail variant renders at the same height
  (replaces `LeoAgentRowDetailLineHeightTests`).
- Pill resolution table and detail precedence (presentation-level unit tests,
  replacing the badge/subtitle tests they supersede).
- Dispatch presentation: role → tint mapping, elapsed formatting, stalled
  copy, accessibility label.
- GUI check: debug build screenshot of a real sidebar with a nested dispatch
  tree, light and dark.

## Out of scope (follow-ups)

- Folding an agent's dispatches behind a count chip on line 1.
- Surfacing a failed dispatch in the parent's line 2 (needs terminal
  dispatches retained).
