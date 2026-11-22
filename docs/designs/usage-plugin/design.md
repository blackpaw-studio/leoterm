# Account Usage plugin: design

Mockups: `sidebar-{light,dark}.png` (sidebar section), `palette-{light,dark}.png` (Show Account Usage), `meter-{light,dark}.png` (Meter close-up, edge values, account states). Sources in `src/`; re-render with `./render.sh`. Hex values in `src/mock.css` only approximate the NSColor names below, and the names are what counts. Glyphs in the PNGs stand in for the SF Symbols named here.

## Meter
One row: **label | track | valueText**, then `detail` on a second line starting at the label's x. Column gaps are 8 pt.

| | Regular (palette, pane body) | Compact (sidebar) |
|---|---|---|
| Track | 6 pt high, radius 3 (capsule) | 5 pt high, radius 2.5 |
| Label | 13 pt `.body`, `labelColor` | 11 pt `.subheadline`, `secondaryLabelColor` |
| valueText | 13 pt, monospaced digits, `labelColor`, trailing | 11 pt, same rules |
| detail | 11 pt `.subheadline`, `secondaryLabelColor`, 2 pt below | 10 pt `.caption`, 1 pt below |
| Between meters | 8 pt | n/a (one meter per Group) |

- Track: `quaternaryLabelColor` (`tertiaryLabelColor` when Increase Contrast is on). The fill is clipped to the track and has the same radius.
- Fill by tone: neutral = `secondaryLabelColor`, success = `systemGreen`, warning = `systemOrange`, failure = `systemRed`. These are the renderer's existing tone colours (`LeoPluginRenderStyle.color(for:)`). Increase Contrast picks up the system colours' high-contrast variants.
- valueText weight: regular for neutral and success, semibold for warning and failure, so tone never depends on colour alone. Its colour stays `labelColor`, because orange and red text fail contrast on light sidebars.
- Value: clamped to 0…1. At 0 the track is empty. Above 0 the fill is at least as wide as the track is high, so 1% shows as a dot.
- valueText column: at least the width of "100%" in the current font, right-aligned, never truncated.
- Label column: all meters in one slot share it, sized to the widest label and capped at 40% of the meter's width, so the tracks line up.
- Motion: a value change animates the fill width (0.2 s ease-out), and doesn't animate under Reduce Motion.
- Tone thresholds (set by the plugin): below 75% success, 75% to below 90% warning, 90% and up failure.

## Group
- **Header row**: `sfSymbol` in a 16 pt column (`secondaryLabelColor`, decorative), 6 pt gap, title, accessory, then a trailing `ellipsis.circle` menu button (20×20 pt hit target) holding `actions`. The same actions appear in the context menu and the ⌘↩ action panel, and Return runs the first one.
  - Regular: title 13 pt semibold, accessory right after the title.
  - Compact: title 13 pt medium, accessory at the trailing edge, no menu button (actions are in the context menu only).
- **Subtitle**: 11 pt `secondaryLabelColor`, indented 22 pt to the title's x. Regular wraps to 2 lines; compact shows only when the Group has no meters (2 lines, then tail-truncated).
- **Children**: indented 22 pt.
  - Regular: 8 pt below the subtitle, 8 pt apart.
  - Compact: 3 pt below the title.
- **Inline action**: a Group with no Meter children shows its first action as a small capsule button below the subtitle. The button is 20 pt high, 11 pt medium text, `quaternaryLabelColor` fill, with the action's `sfSymbol`. This is renderer behaviour, not a new prop.
- **Container**:
  - Regular: inset rounded rect, radius 10, padding 10/12, `quaternarySystemFillColor`, 10 pt between Groups. Keyboard focus adds `unemphasizedSelectedContentBackgroundColor` and a 1.5 pt `keyboardFocusIndicatorColor` ring.
  - Compact: no background, 5/6 pt vertical padding, 4 pt horizontal (the agent-row insets).
- **Accessory**: the existing Accessory, 11 pt medium, coloured with `LeoPluginRenderStyle.ink(for:)`.

## Account states (all built from spec props)
| State | Accessory | Subtitle | Children | First action |
|---|---|---|---|---|
| loading (first fetch) | none | "Loading…" | none | Refresh |
| ok | none | `~/path · Updated 3m ago` | meters | Refresh |
| stale | `arrow.clockwise.circle` "Stale", warning | `~/path · Updated 22m ago` | last good meters, detail "Couldn't refresh · values from 8:57 PM" | Refresh |
| expired (401) | `person.crop.circle.badge.xmark` "Expired", failure | `~/path · Signed out — run claude with this account to refresh` | none | Copy Sign-in Command (`copy`) |
| needsAuthorization | `lock.fill` "Locked", warning | `~/path · Leo needs Keychain access to read this account` | none | Grant Access… (callback → `credentials.authorize`) |
| error / no data | `exclamationmark.triangle` "Error", warning | `~/path · <reason>` or "No usage data" | none | Refresh |

In the sidebar, the path is left out of subtitles. The section header accessory shows the worst current meter: `gauge.with.dots.needle.67percent` plus the percentage, toned. It still shows when the section is collapsed.

## VoiceOver
- **Meter**: one element, role `levelIndicator`, label "Session, 42%, Resets in 2h 14m" (label, valueText, detail, as the spec says), value 0–100.
- **Group**: an accessibility container labelled "blackpaw-evan, Stale". Its `actions` are exposed as custom actions, and the subtitle as help.
- **Section header**: "Usage, Account Usage plugin, worst 91%".
- **Hidden from VoiceOver**: the kind glyph and the ⋯ button. The button's actions are already custom actions.

## Narrow sidebar
Things give way in this order as the sidebar narrows:
1. `detail` tail-truncates.
2. The Group title tail-truncates (full title in a tooltip).
3. The accessory drops its text and keeps the symbol (tooltip has the text).
4. The meter label tail-truncates, down to a 48 pt minimum track.
5. Below that the label hides, but VoiceOver still reads it.

valueText never truncates. At the 260 pt default nothing truncates except long expired subtitles.

## Proposed spec deltas
1. **Meter already exists.** v1 ships `Meter {segments, max, label?, help?}` (LeoKit `LeoPluginNode.Meter`). Extend that node in apiVersion 2 rather than adding a second `Meter`:
   - Add `valueText?` and `detail?`.
   - The spec's `value` + `tone` become one segment, `{segments:[{value, tone}], max:1}`.
   - The spec's `neutral` tone maps to the existing `secondary`.
   - The inline label | track | value layout above applies when `valueText` or `detail` is set.
2. **Section header accessory.** Today the sidebar header is chevron + title only. Proposal: a sidebar slot root may start with an `Accessory`, which the host lifts into the header's trailing edge, visible even when collapsed.
3. **Add Account… needs a pull-down.** `credentials.add(kind)` needs the kind, and a row click runs only the first action. Proposal: `List.Item.presentsMenu: true`, so clicking or pressing Return opens the item's actions as a menu. Without it, the fallback within the current spec is two rows, "Add Claude Account…" and "Add Codex Account…".
