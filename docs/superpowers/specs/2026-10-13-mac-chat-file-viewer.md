# Mac chat: view attachments in-app

**Platform:** Mac only. iOS already previews chat attachments in-app via
`ChatQuickLookController` (`ios/.../ChatThreadViewController.swift:238`).

## Problem

Clicking a file or image attachment in Leo Chat on Mac calls
`NSWorkspace.shared.open(url)` (`LeoChatAttachmentView.swift:28, 64-69`), which
throws the user out to Preview / TextEdit / whatever owns the type.

## Behavior

1. Clicking an image or file attachment opens a **read-only viewer inside the
   chat pane**. The viewer replaces the thread view (composer hidden) in both
   chat layouts (`chatReplacingTerminal` and `sideBySide`).
2. The viewer has a header with: a back button (returns to the thread at the
   same scroll position), the filename, and an "Open in Default App" button
   (current `NSWorkspace` behavior).
3. Escape and the back button both close the viewer. Switching agents or
   closing chat also closes it; reopening chat shows the thread, not the
   viewer.
4. Content is rendered with the editor's existing preview stack
   (`LeoFilePreview` / `LeoFilePreviewKind`): markdown and SVG rendered,
   images, movies, PDF/Office via QuickLook, text read-only. No editing, no
   save path.
5. Kind selection uses the filename extension as the editor does, then the
   attachment's MIME type when the extension is missing or unknown. If neither
   maps to a known kind and the file is not valid UTF-8 text, the click falls
   back to opening in the default app (today's behavior) instead of showing
   binary garbage.
6. Voice notes keep their inline player; unchanged.
7. While the attachment is still downloading, the click behaves as today
   (waits for the existing `loadAttachment` path), then opens the viewer.
   Download failure shows the existing error handling; no viewer.

## Constraints

- Do not route through `openInEditor` / `LeoEditorPaneModel` — those need an
  agent workspace and an editable document.
- Reuse `LeoFilePreview` and `LeoFilePreviewKind` and the local
  `LeoFileAccess` backend; add a read-only mode only if the preview views
  currently allow edits. No copy of the deleted surface-file viewer.
- The downloaded file is already local (`attachmentDirectory/<id>/<name>`);
  no extra streaming or temp copy.

## Testing

- Unit: the kind-resolution function (extension → MIME → text sniff →
  fallback) and the chat-pane viewer state (open / back / agent switch /
  chat close resets it).
- Manual: debug build, open a markdown, PNG, PDF, and unknown-binary
  attachment in the chat pane; screenshot each.

## Out of scope

- iOS changes.
- Prev/next navigation across attachments, search, or edit-and-send-back.
