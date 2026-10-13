# Plan: view Mac chat attachments in-app

Spec: `docs/superpowers/specs/2026-10-13-mac-chat-file-viewer.md` (source of truth). Platform: Mac only (iOS already has
`ChatQuickLookController`). Nothing goes into LeoKit, because the preview stack lives in the Mac target.

## Verified facts the steps rely on
1. Clicks go to NSWorkspace in two places: the image `onTapGesture` (`LeoChatAttachmentView.swift:28`) and `open()` (:64-69), which awaits
   `chat.loadAttachment` and then opens `.loaded(url)`. A failed download leaves `.failed(reason)`, which the row already shows.
2. `LeoFilePreview` only fetches bytes into `LeoFilePreviewCache`'s `$TMPDIR` folders. Using it here would mean the temp copy the spec rules out.
   The reusable renderer is `LeoEditorContentHostView` (`Editor/UI/LeoEditorContentHostView.swift`). It is fed a `LeoEditorPaneContent`
   (`.text/.markdown/.svg/.image(URL)/.movie(URL)/.quickLook(URL)/.unavailable`), and `LeoEditorPresentation.content(kind:preview:textLength:)`
   maps a `LeoFilePreviewKind` plus `LeoFilePreview.State.ready(url)` to it. So this plan reuses `LeoFilePreviewKind`,
   `LeoEditorPresentation`, the content host and `LeoFileAccessor.local()`, but not the fetch/cache.
3. Read-only: only the text view can be edited. `LeoEditorTextView` is an NSTextView, which is editable by default; the editor pane
   sets `isEditable` per document (`LeoEditorPaneViewController.swift:170`). `LeoRenderedTextView` is already `isEditable = false` (:28).
   Image, movie and Quick Look views are display-only. So "read-only mode" is just `textView.isEditable = false` in the viewer, and the
   host needs no new mode. ⌘W/undo/save live on `LeoEditorPaneViewController`, which the viewer doesn't use.
4. `LeoFilePreviewKind(path:)` returns `.text` for any extension not on its allowlist, so it can't tell "unknown" from "text". Resolution needs a failable lookup.
5. `LeoEditorContentPolicy.default.evaluate(data)` already does the sniff: a NUL in the first 8000 bytes means `.binary`, and a lossy decode means `.notUTF8`.
   `readLimit` is 20 MB. Local reads use `LeoFileAccessor.local().read(path, maxBytes:)`.
6. There is one `LeoChatPaneModel` for the whole app, but the chat open/closed state is per window (`LeoWindowSession.viewChoices`). Every
   way of closing chat goes through `LeoWindowSession.choose(.terminal, for:)`: the header ✕, the segment toggle via `select`, and the Terminal segment.
   `LeoChatLayoutHost` already has `.onChange(of: row?.id)` (`LeoChatPane.swift:40`).
7. Thread scroll position is SwiftUI `ScrollView` state plus `@State pin` (`LeoChatThreadView.swift:9`). Removing the view loses both.
   Drafts live on the model (`chat.drafts`), so the composer can be removed and re-added without losing anything. It takes a pending focus request on appear (`LeoChatComposer.swift:32`).

## Test commands (Xcode 26.3; the full in-host suite times out, so run targeted suites only)
- First run `pgrep -fl "Leo -XCTest"` and make sure nothing else is running. From `macos/`, build once:
  `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO > /tmp/leo-build-viewer.log 2>&1`
- Run (`T` = suites, comma-free, one `-only-testing` each):
  `DEVELOPER_DIR=… /opt/homebrew/bin/timeout 600 xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<Suite> …`
  This hangs if the console is locked (see LEO.md). In that case stop and report; don't fall back to the full suite.
- Lint: `cd macos && swiftlint lint --strict --quiet`.

## Step 1: failable kind lookup (extension, then MIME)
Files: `Editor/Preview/LeoFilePreviewKind.swift`:
- add `static func known(path: String) -> LeoFilePreviewKind?`, which looks up the allowlist only
- `init(path:)` becomes `known(path) ?? .text`

New `Chat/LeoChatViewerDocument.swift` gets `enum LeoChatViewerKind { static func known(filename: String, mime: String) -> LeoFilePreviewKind? }`:
1. Try the extension first (`LeoFilePreviewKind.known`).
2. Otherwise take the MIME, lowercased, with `;params` stripped:
   - an explicit table for `text/markdown`, `text/x-markdown` → markdown and `image/svg+xml` → svg
   - for everything else, `UTType(mimeType:)?.preferredFilenameExtension` run back through `known(path:)`
3. Return nil when nothing matches.

Failing tests first:
- `macos/Tests/Leo/Editor/Preview/LeoFilePreviewKindTests.swift`: `known` is nil for `a.txt`, `Makefile` and `.png`; `init(path:)` is unchanged.
- New `macos/Tests/Leo/LeoChatViewerDocumentTests.swift` (parameterized):
  - MIME-only matches: `("shot","image/png")` → image, `("clip","video/quicktime")` → movie, `("x","application/pdf")` → quickLook,
    `("notes","text/markdown")` → markdown, `("d","IMAGE/SVG+XML; charset=utf-8")` → svg
  - the extension wins: `("a.png","application/pdf")` → image
  - nil: `("a.json","application/json")`, `("blob","application/octet-stream")`, `("blob","")`

Verify: run `LeoFilePreviewKindTests` and `LeoChatViewerDocumentTests`. Commit.

## Step 2: `LeoChatViewerDocument`, the resolved file, or nil to open externally
In the same file:
`struct LeoChatViewerDocument: Equatable { let attachmentID, filename: String; let url: URL; let body: Body;
 enum Body: Equatable { case file(LeoFilePreviewKind); case text(String, LeoFilePreviewKind) }; var content: LeoEditorPaneContent }`

`static func load(attachment:url:access: any LeoFileAccess = LeoFileAccessor.local(), policy: .default) async -> Self?`:
- image, movie or quickLook: return `.file(kind)` without reading
- otherwise: read through `access` (capped at `policy.readLimit`) and run `evaluate`
  - `.binary`, `.notUTF8` or a failed/too-large read: return nil
  - valid text: return `.text(text, known ?? .text)`

`content` comes from `LeoEditorPresentation().content(kind:preview: .ready(url) | nil, textLength:)`. Markdown over `renderLimit` drops to `.text` for free.

Decision: a markdown or SVG attachment that fails UTF-8 also returns nil. This is wider than the spec's "neither known" rule, but it matches the spec's intent (never show garbage).

Failing tests first (`LeoChatViewerDocumentTests`; write a few bytes into a per-test temp folder and use `LeoFileAccessor.local()`):
- `.md` → `.markdown` content holding the text
- `.json` → `.text`
- an unknown-extension file of UTF-8 text → `.text`
- an unknown-extension file with a NUL byte → nil
- invalid UTF-8 → nil
- `.png` → `.image(url)` with no read: pass a fake access that fails every read; reuse `Files/LeoFileAccessTestSupport.swift` if it fits
- a missing file → nil

Verify: run `LeoChatViewerDocumentTests`. Commit.

## Step 3: per-window viewer state
New `Chat/LeoChatViewerModel.swift`:
`@MainActor final class LeoChatViewerModel: ObservableObject { struct Shown: Equatable { agent: LeoAgentID; document: LeoChatViewerDocument }
 @Published private(set) var shown: Shown?; init(access: any LeoFileAccess = LeoFileAccessor.local(), openExternally: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) })
 func open(_ a: LeoChatAttachment, for agent: LeoAgentID, download: @escaping () async -> URL?) async
 func document(for agent: LeoAgentID?) -> LeoChatViewerDocument?   // nil unless shown.agent == agent
 func close(); func agentChanged(to agent: LeoAgentID?) }        // closes unless shown.agent == agent`

`open` takes a token:
1. Await `download()`. A nil URL is the existing failure UI: no viewer and no external open.
2. Recheck the token, then `LeoChatViewerDocument.load`.
3. Recheck the token. A nil document calls `openExternally(url)`; otherwise set `shown`.

`close` and `agentChanged` bump the token, so Back or an agent switch during a download cancels the open, and a later click supersedes an earlier one.

`LeoWindowSession.swift`:
- add `let chatViewer = LeoChatViewerModel()`
- in `choose(_:for:)`, `.terminal` also calls `chatViewer.close()`. This covers the ✕, the toggle, the Terminal segment and the `select` path.

`LeoChatPaneModel.swift`: add `func downloadedFile(_ a: LeoChatAttachment) async -> URL?`, which is `loadAttachment` and then `.loaded(url)`. It is reused by `open()` and the audio player.

Failing tests first, in new `macos/Tests/Leo/LeoChatViewerModelTests.swift` (with `@MainActor`; the download is a closure gated by a continuation):
- markdown opens `shown`
- a binary file calls `openExternally` and leaves `shown` nil
- a nil download does neither
- close clears
- agent changes:
  - `agentChanged(to: B)` clears
  - a later `agentChanged(to: A)` still shows the thread
  - `document(for: B)` is nil while A is shown
- close or `agentChanged` while a download is held shows nothing and opens nothing
- with two clicks, the second wins
- through `LeoWindowSession(defaults: LeoInMemoryDefaults())`:
  - `choose(.terminal)` clears
  - `select(.chat)` while chat is showing clears (use `selectedAgent` stubbed and `setObservedContentWidth(800)`)
  - `choose(.chat)` keeps the viewer

Verify: run `LeoChatViewerModelTests`, `LeoChatAutoOpenTests` and `LeoChatFocusRoutingTests`. Commit.

## Step 4: AppKit viewer view
New `Chat/LeoChatFileViewer.swift`:
- `final class LeoChatFileViewerView: NSView`
  - owns a `LeoEditorContentHostView(textScrollView:textView:)` built from `LeoEditorTextView.make()`
  - sets `textView.isEditable = false`; selection and the find bar stay
  - `show(_ doc)`:
    - for `.text` bodies, sets `textView.language = LeoEditorLanguage(path: filename)` and calls `textView.load(text, keepingSelection: false)`
    - then `contentHost.show(doc.content, source: { text }, name: sanitized filename, revealTitle: "Open in Default App")`
  - `contentHost.onUnavailableAction = { _ in openExternally(url) }`, so an image that fails to decode or a broken SVG offers the default app
  - `clear()` releases Quick Look and movie files; it is called from `dismantleNSView`
  - once in a window, it makes `contentHost.focusTarget` the first responder, retrying once on the next turn as `focusText()` does
- Escape: a local `.keyDown` monitor, installed in `viewDidMoveToWindow` and removed when the view leaves the window, calls `onBack`. It fires only when:
  - `event.window === window`
  - the key is code 53 with no modifiers
  - the first responder is inside this view and is not a field editor, so the find bar keeps its Escape and a side-by-side terminal keeps vim's
  - The rule is the pure `static func closesOnEscape(keyCode:modifiers:isInViewer:isFieldEditor:) -> Bool`.
- `struct LeoChatFileViewerRepresentable: NSViewRepresentable` is keyed by `attachmentID`.

Failing tests first, in new `macos/Tests/Leo/LeoChatFileViewerTests.swift` (off-window, like `LeoEditorContentHostTests`):
- text doc: `contentHost.content == .text`, the text view isn't editable, and it holds the string
- `.md` → `.markdown`
- `.png` → `.image(url)`
- an undecodable `.png` → `.unavailable` content, and its action calls `openExternally`
- Escape predicate:
  - a bare Escape in the viewer closes
  - ⌥Esc, a field editor, or focus outside the viewer does not

Verify: run `LeoChatFileViewerTests` and `LeoEditorContentHostTests`. Commit.

## Step 5: pane wiring (glue and styling; TDD-exempt, covered by Steps 3–4 and Step 6)
`LeoChatPane.swift`:
- `LeoChatPane` takes `@ObservedObject var viewer: LeoChatViewerModel` (passed `session.chatViewer`). `let doc = viewer.document(for: row.id)`.
- Body: header, Divider, notice, then `ZStack { LeoChatThreadView(...).opacity(doc == nil ? 1 : 0).disabled(doc != nil).accessibilityHidden(doc != nil); if let doc { viewer view } }`.
  The Divider and composer render only when `doc == nil`.
  - The thread stays mounted, so its scroll offset and pin survive.
  - Removing the composer only resizes the viewport. That is a layout change in `LeoChatScrollPin`: a pinned reader stays at the bottom, and an unpinned one keeps its top-anchored offset.
- Viewer header, the same 36 pt `.bar` row:
  - leading: a `chevron.backward` borderless button (help/AX "Back to Chat")
  - the filename in `.headline`, one line, middle-truncated
  - `Spacer`, then an `arrow.up.forward.app` button (help/AX "Open in Default App")
  - the existing ✕ Close Chat button
  - The task-filter menu is hidden.
- Back and Escape both call `viewer.close()` then `session.requestChatFocus()`. The composer takes focus when it reappears.
- `drop` refuses (returns false) while `doc != nil`, so files can't join a hidden draft.
- Set `.environment(\.openChatAttachment) { a in Task { await viewer.open(a, for: row.id, download: { await chat.downloadedFile(a) }) } }`.

`LeoChatLayoutHost`:
- pass `session.chatViewer`
- extend `.onChange(of: row?.id)` to call `session.chatViewer.agentChanged(to: $0)`

`LeoChatAttachmentView.swift`:
- add the `openChatAttachment` EnvironmentKey. Its default is today's behaviour (download, then NSWorkspace).
- the image tap and `open()` both call it. Voice notes are untouched.

Verify: build; run all `LeoChat*` suites plus `LeoWindowSessionRegistryTests` (one `-only-testing` each); swiftlint clean. Commit.

## Step 6: debug-app verification (`.autopilot/verify.md`: isolated launch, Peekaboo `--capture-engine cg`)
1. Use `autopilot-scratch` only. Filter the sidebar to it and never press Return.
2. Have it `leo_chat_post` four files: `notes.md`, `shot.png`, `doc.pdf`, and `blob.bin` (random bytes, no MIME match).
3. Shot each of md, png and pdf in the viewer, in both `chatReplacingTerminal` and `sideBySide` (narrow and wide window).
4. `blob.bin` shot: the thread is still showing and the default app opened.
5. Scroll up, open, Back, and shoot: the same messages are in view. Repeat with Escape.
6. Open the viewer, then:
   - switch agent and back, and shoot: the thread shows
   - close chat and reopen, and shoot: the thread shows
7. Open a `.md` in the viewer and type: the text doesn't change.
8. Return the PNG paths for the orchestrator to post.

## Accepted risks
- While the viewer is up the thread still counts as on screen, so messages that arrive are marked read and don't badge. Back shows them.
  Fixing this means splitting `setOnScreen` bookkeeping across windows, which isn't worth it here.
- Extension-first means a `.txt` that the daemon labels `image/png` shows as an image, which follows the spec's order.
- Text over 20 MB with an unknown extension opens in the default app instead of the viewer.
- With focus in the viewer, ⌘W behaves as it does with focus in the composer today (not a viewer close).

## Open questions (not settled by spec)
1. Keep the ✕ Close Chat in the viewer header (plan: yes) or show only Back, filename and Open?
2. Should markdown or SVG get the editor's Rendered/Raw toggle (⌥⌘U), or images get Fit / Actual Size? The plan leaves both out.
3. Show a spinner on the row while a slow download or text read is in progress? Today the subtitle already shows "Downloading…".

## Orchestrator decisions on open questions
1. Keep the ✕ Close Chat in the viewer header.
2. No Rendered/Raw toggle or Fit/Actual Size (YAGNI; not in spec).
3. No extra spinner; the existing "Downloading…" subtitle is enough.
