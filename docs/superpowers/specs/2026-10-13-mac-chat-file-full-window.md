# Mac chat: full-window file viewer

**Platform:** Mac only. iOS QuickLook previews are already full screen.
Builds on `2026-10-13-mac-chat-file-viewer.md` (in-pane viewer, shipped in
leo-v0.19.0).

## Behavior

1. **Entry points**
   - An **expand** button (`arrow.up.left.and.arrow.down.right`, help/AX
     "Open Full Window") in the in-pane viewer header, between the filename and
     "Open in Default App".
   - A **context menu** on image and file attachments (not voice notes) with
     "Open Full Window" and "Open in Default App". "Open Full Window" goes
     straight to full window without showing the in-pane viewer.
   - A normal click is unchanged (in-pane viewer).
2. **Presentation:** an opaque overlay covering the whole window's content
   area: sidebar, terminal, chat and control bar, below the titlebar. It is
   inside the window, not a sheet and not a new window. The window stays
   resizable and the overlay tracks its size.
3. **Header:** the same 36 pt bar style as the in-pane viewer. From left to
   right: collapse button (`arrow.down.right.and.arrow.up.left`, "Exit Full
   Window"), sanitized filename, spacer, "Open in Default App", ✕ "Close".
4. **Leaving**
   - **Collapse and Escape** return to where the user came from. From the expand
     button that is the in-pane viewer. From the context menu it is the
     thread.
   - **✕** closes the overlay and any in-pane viewer, back to the thread.
   - **Agent switch or chat close** from any path, including keyboard
     shortcuts, closes the overlay and the in-pane viewer, the same rule as
     the in-pane viewer today.
5. **Content:** the same renderer, read-only rule and kind resolution as the
   in-pane viewer. A file the viewer can't show falls back to the default app
   from either entry point. The double-click and stale-download guards apply
   to the context-menu path too.
6. **Focus:** focus moves into the overlay content (text is selectable and the find bar
   works). On leaving, focus goes back to the in-pane viewer or the composer.
7. **Scope:** one overlay per window. A file opened full window in one window
   does not affect other windows.

## Constraints

- Reuse `LeoChatFileViewerView`, `LeoChatViewerDocument` and the
  `LeoChatViewerModel` token logic. Add presentation state (`pane` /
  `fullWindow` plus where it came from) to the model rather than a second model.
- The Escape monitor must not fire twice; while the overlay is up, it handles
  Escape before the in-pane viewer.

## Testing

- Unit: model transitions (expand → collapse returns to pane; context-menu
  open → collapse returns to thread; ✕ clears both; agent switch and chat close
  clear both; stale open from the context menu is dropped).
- Manual: debug build. Expand md/png/pdf, collapse, Escape, ✕, context-menu
  open, and window resize while full; screenshot each.

## Out of scope

- Zoom controls, prev/next between attachments, and native macOS full screen.
