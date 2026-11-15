# Mac agent window: everything in the toolbar (option A)

Status: APPROVED 2026-11-07 · Platform: **Mac only**. iOS has no terminal composer or bottom control bar; nothing to port.
Mockup: https://claude.ai/artifact/AzeAhQSmTNxRu5gbPE2uN5 (option A).
Amends `2026-11-04-mac-agent-toolbar.md`: replaces its "Terminal/Chat switcher" section and its trailing-toolbar bullet. Everything else there (title/subtitle, activity capsule, popover) stands.

## Why
The agent window has two places for agent actions: the toolbar and a 44 pt bottom control bar. The bar's message field duplicates the terminal's own input, and Interrupt, Compact and Clear appear in both the bar and the ⋯ menu. Moving everything into the toolbar gives one place to look and returns the bar's height to the terminal.

## Removed
- The bottom control bar (`LeoAgentControlBar`) in Terminal view: message field, send, interrupt, compact, clear and the Terminal/Chat switch. The terminal runs to the window's bottom edge.

## Toolbar trailing group (agent windows only)
Order, leading to trailing:
1. **View switch.** A system segmented control, two icon segments: `terminal` and `bubble.left` (SF Symbols). Selection-style, not momentary.
   - Tooltips and VoiceOver labels "Terminal" / "Chat"; the group's label is "View".
   - The existing unread indicator moves onto the Chat segment as a small accent dot; its VoiceOver label becomes "Chat, n unread".
2. **Interrupt.** A borderless `stop.circle` toolbar button, tooltip "Interrupt (⌘.)" (use the Agents-menu shortcut, whatever it is today).
   - Always present; disabled when the agent isn't working. It never appears or disappears.
3. **⋯ menu.** Unchanged from the 2026-11-04 spec: Interrupt, Compact Context, Clear, Show Messages ▸.

Interrupt and ⋯ share one glass group; the view switch is its own group. With the title and the capsule that makes three groups, the HIG maximum.

At narrow widths the capsule degrades first (per the 2026-11-04 spec); the trailing items stay visible at every width.

## Chat view
- Chat keeps its composer at the bottom of the chat pane, since chat has no other input. Restyle it as a rounded field with an inline send button (mockup), sitting in the content area, not a full-width bar.
- No switch at the bottom of chat; the toolbar switch covers both views.

## Keyboard and menus
- View ▸ Terminal and View ▸ Chat keep their existing shortcuts.
- Agents ▸ Interrupt / Compact Context / Clear unchanged. Nothing becomes pointer-only.
- Typing in Terminal view goes to the terminal, as it does today when the terminal has focus. On switching to Terminal, the terminal surface takes first responder.

## Testing
- Unit tests for any presentation logic that moves (unread label, Interrupt enabled state) against the model, not the view.
- Launch check: the window still opens (NSSplitView launch-crash memory).
- Screenshots from the isolated debug build, light and dark: Terminal view, Chat view with unread, agent idle (Interrupt disabled), 480 pt narrow window, full screen.

## Out of scope
- Status bar / context-usage readout (option B).
- Chat as an inspector (option C).
- Toolbar customization.
- iOS.
