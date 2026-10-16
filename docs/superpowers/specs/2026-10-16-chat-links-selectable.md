# Leo Chat: clickable links + selectable text on iOS

Platforms: **both**. The link logic is shared in LeoKit. Mac and iOS each wire it into their own text views.

## Problem
- **Mac:** bubble text is selectable, and markdown `[x](url)` produces link runs. Bare URLs such as `https://example.com` are never linked.
  Links may also be dead while `.textSelection(.enabled)` is on (reported; to be confirmed when the app runs).
- **iOS:** the bubble body is a plain-text `UILabel`. It has no markdown, no links, and no way to select or copy text.

## Design
### LeoKit: `LeoChatText.attributed(_ text: String) -> AttributedString` (pure)
- Parse inline markdown with `.inlineOnlyPreservingWhitespace`, the same options the Mac uses today.
- Then autolink bare URLs with `NSDataDetector(.link)` over the plain characters:
  - Skip ranges that already have a `.link` attribute.
  - Skip ranges inside inline code: `inlinePresentationIntent` contains `.code`.
- Only `http`, `https` and `mailto` become links. Any other scheme detected or written in markdown, such as `file:` or `javascript:`, has its `.link` removed and shows as plain text.
- If markdown parsing fails, fall back to the plain string and still autolink.

### Mac
- `LeoChatMarkdownText` uses `LeoChatText.attributed` and keeps `.textSelection(.enabled)`.
- If links are dead while selection is on (check in the running app): render the body through an `NSTextView`-backed representable. It must be non-editable and selectable, and must size to fit, so selection and link clicks both work.
- Links open in the default browser through `openURL`. Mine-bubble link styling (white, underlined) stays.

### iOS
- The body `UILabel` becomes a `UITextView`: `isEditable = false`, `isSelectable = true`, `isScrollEnabled = false`, zero insets and `lineFragmentPadding = 0`.
  It keeps the current font, Dynamic Type and self-sizing behaviour.
- Content is `NSAttributedString(LeoChatText.attributed(text))` with the body font and colour applied. That gives iOS the same inline markdown as the Mac: bold, italic, code and links.
- Tapping a link opens it in the system default browser (`UIApplication.open`), like iMessage. A long-press on a link shows the standard system preview menu.
- Text is selectable with the system long-press and drag, which gives the Copy, Share and Look Up menu.
- Link colour: `tintColor` on agent bubbles, white and underlined on mine (`linkTextAttributes`).
- This applies to message bodies and task-card bodies. Ask prompts go through the same body view, so they get it too.

## Out of scope
- Opening chat-file links in the in-app viewer.
- An in-app Safari sheet.
- Block markdown (lists, headings).
- Link previews.

## Testing
- LeoKit unit tests for `LeoChatText.attributed`:
  - a bare URL is linked
  - a markdown link is kept
  - a URL inside inline code is not linked
  - a URL inside an existing markdown link isn't double-linked
  - `mailto:` is linked
  - `file:` and `javascript:` are not linked
  - trailing punctuation (`see https://x.com.`) is not included
  - invalid markdown falls back to plain text
- UI: exempt from TDD. Verify in the real Mac app and the iOS simulator against the isolated daemon:
  - a bare link and a markdown link in agent and mine bubbles, light and dark
  - clicking or tapping opens the URL
  - iOS long-press selects text and shows Copy
  - the bubble height still fits its text (no clipping, no extra space)
