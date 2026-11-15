# Mac chat: resizable width in side-by-side layout

**Platform:** Mac only. iOS has no side-by-side chat layout.

## Behavior

1. In the `sideBySide` layout, the divider between terminal and chat
   (`LeoChatLayoutHost`, `LeoChatPane.swift:28-34`) is draggable. The cursor
   becomes the horizontal resize cursor over a hit area about 6 pt wide centred on the
   divider; the visible line stays thin.
2. Dragging sets the chat width live. The width is clamped to
   `max(320, min(W, contentWidth − 481))`: chat is never narrower than 320 pt,
   and the terminal never narrower than 481 pt. There is no fixed upper cap
   (the old 560 pt max applies only to the default).
3. The chosen width persists globally in `UserDefaults` under
   `leo.chatWidth`, the same way the sidebar uses `leo.sidebarWidth`. All windows
   and agents share it. It is written when the drag ends, not on every frame.
4. With no stored width, the current default formula applies unchanged
   (`clamp(320…560, min(contentWidth − 481, round(0.38 × contentWidth)))`).
5. Double-clicking the divider clears the stored width (back to the default).
6. The mode threshold is unchanged: side-by-side iff `contentWidth ≥ 1000`.
   The user width affects only the side-by-side branch; `chatReplacingTerminal`
   stays full width.
7. When the window or sidebar resizes, the stored width is re-clamped for
   display only. The stored value is not rewritten, so widening the window
   again restores it.

## Constraints

- Keep the existing SwiftUI `ZStack`/`HStack` host. No move to `NSSplitView`
  (known holding-priority and launch-crash pitfalls).
- Width math stays pure in `LeoChatLayout` (e.g. `chatWidth(in:preferred:)`)
  and is unit-tested; the session owns the stored preference via injected
  `UserDefaults`.

## Testing

- Unit: clamp cases (below min, above terminal limit, nil → default formula,
  re-clamp on narrow window keeps stored value), threshold unchanged.
- Manual: debug build, drag the divider, relaunch to confirm it persists,
  double-click to reset; screenshot.
