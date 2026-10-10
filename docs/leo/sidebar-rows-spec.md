# Sidebar rows: symbol column + Needs You section

Mockup: https://claude.ai/artifact/3D5VAxxSKUPHuKQnCkbeuw (option B rows,
option C sections). Replaces the state-pill / role-chip rows.

## Goal

A calmer sidebar that is easy to read. A row uses colour only when the state
changes what you'd do. Agents that need you sit at the top. Quiet agents take
one line.

## Agent row (`LeoAgentRowView`)

**Leading symbol column.** A fixed 16pt column holds an SF Symbol in the state
tint (white on a selected row). This replaces the pill. Symbols use
hierarchical rendering at `.body` scale.

| State | Symbol | Tint | Second line | Trailing |
|---|---|---|---|---|
| needsYou | by reason, unchanged (`hand.raised.fill` / `questionmark.bubble.fill` / `list.bullet.rectangle.fill`) | orange | yes, in orange ink | time |
| error | `exclamationmark.triangle.fill` | red | yes, in red ink | time |
| done | `checkmark.circle` | green | yes, secondary | time |
| working | `arrow.triangle.2.circlepath` (rotates; static under Reduce Motion) | blue | yes, secondary | time |
| compacting | `arrow.down.right.and.arrow.up.left` | indigo | no | the word "Compacting", in indigo ink |
| starting | `ellipsis` | secondary | no | time |
| idle | `moon` | tertiary | no | time |
| stopped | `stop.fill` | tertiary; the name turns secondary | no | time |
| unknown | `questionmark` | tertiary | no | time |

The order for resolving the state is the same as today (first match wins).

**Line 1:**
- Name in `.body` medium. Search highlights are unchanged.
- Surfaced-files glyph and count, unchanged.
- Trailing: the time (`.caption`, tertiary, monospaced digits) or the trailing word from the table. A pending action still swaps this for a `ProgressView`.

**Line 2:** shown only where the table says yes. The detail string follows the
same precedence as today. It aligns with the name, not with the symbol.

**Row height** depends on state: one line or two. Within a state it is
constant, so tool calls never make a row jump. The vertical padding is 5pt.

**Accessibility:** colour is never the only cue, because every state has its
own symbol shape. The VoiceOver label on the name keeps carrying the state and
the reason. The symbol stays hidden from VoiceOver, as the pill was.

## Dispatch row (`LeoDispatchRowView`)

One line, 22pt high:
- The indent puts the glyph on the parent's name column, plus 16pt for each level of depth (still capped at 4).
- Role glyph, 12pt, replacing the chip:
  - explore: `magnifyingglass`
  - plan: `list.bullet`
  - implement: `chevron.left.forwardslash.chevron.right`
  - review: `eye`
  - other roles: `circle.dashed`
- The glyph's colour shows the status:
  - running: blue
  - stalled: orange
  - queued or idle: tertiary
- Title in `.callout`, secondary. A queued dispatch's title is tertiary. The fallback when there's no name is unchanged.
- Trailing elapsed time, unchanged, including "Stalled 4m" in orange.
- **Tree guides are removed.** The indent alone shows the hierarchy. `LeoDispatchTreeGuide` gets deleted.
- Role colours (`LeoTint` role mapping) are removed.

## Sections

### Default: grouped by status, with Needs You on top

1. **Needs You**:
   - Holds agents whose attention is `needsInput` or `errored`.
   - The header shows a count in orange ink.
   - It appears only when it isn't empty.
   - It can't be collapsed.
2. **Pinned**, then **Running / Starting / Stopped / Unknown**, as today.

Each agent appears in exactly one section. Needs You takes precedence over
Pinned and over status. When the agent's attention clears, it returns to its
own section.

### Opt-in: grouped by attention

1. **Needs You**: `needsInput` or `errored`.
2. **Working**: working or compacting, as one-line rows (trailing word "Working" or "Compacting" in place of the time).
3. **Finished**: `finished` attention.
4. **Idle & Stopped**: everything else. Collapsed by default.

Rules for this mode:
- Pinned agents stay pinned: a Pinned section sits under Needs You.
- Section headers show counts. Collapse behaves as today, keyed by section ID.
- While filtering, both modes flatten exactly as today.

### The setting

- A new menu item, **Agents ▸ Group By ▸ Status / Attention**, sits next to Sort By. It is a checkmarked radio pair.
- The setting is persisted as a new `groupBy` field in `LeoSidebarPreferences`:
  - The default is `.status`.
  - Decoding is lenient, like the other fields.

## Out of scope

- The header, the button bar, search and the Terminals section.
- Inline approve/deny actions on Needs You rows.

## Tests

- Section layout per mode: membership, precedence over Pinned, Needs You hidden when it's empty, Idle & Stopped collapsed by default.
- Row presentation: symbol, tint, whether there's a second line and what goes in the trailing slot, for each state.
- `groupBy` round-trips through the preferences, and an old blob without the field still decodes.
- GUI: a capture of the real app in light and dark mode, in both modes.
