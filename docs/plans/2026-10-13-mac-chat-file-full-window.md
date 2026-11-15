# Plan: full-window viewer for Mac chat attachments

Spec: `docs/superpowers/specs/2026-10-13-mac-chat-file-full-window.md` (source of truth). Builds on `docs/plans/2026-10-13-mac-chat-file-viewer.md`.
Platform: Mac only. iOS QuickLook is already full screen, and nothing goes into LeoKit.

## Verified facts the steps rely on
1. The window content is `window.contentView = TerminalViewContainer { TerminalView(...) }` (`TerminalController.swift:1433-1446`), which wraps one NSHostingView.
   `TerminalView.body`'s `.ready` ZStack (`TerminalView.swift:111-175`) holds, in order:
   - `LeoSidebarSplit`, the NSSplitViewController. Its items are the sidebar, the detail and the browser/editor panes. The detail is `GeometryReader { VStack { LeoChatLayoutHost; LeoAgentControlBarHost } }`.
   - the command palette and `UpdateOverlay`, as later siblings.
2. This codebase already takes clicks on SwiftUI content stacked above a representable in a ZStack: the command palette sits over the whole split, and `LeoChatLayoutHost` stacks the chat pane over `terminal()`.
3. `LeoTitlebarInsets.splitIgnoredEdges(in:)` reaches TerminalView as `leoSplitIgnoredEdges`. It is `.top` only for `HiddenTitlebarTerminalWindow`, where the split runs into a 32 pt strip with no window buttons. For every other style it is `[]`, and the content sits under the titlebar.
4. TerminalView holds `leoSession` as a plain `let` and doesn't observe it (comment at `TerminalView.swift:58-64`). The overlay therefore needs its own `@ObservedObject` host view.
5. `LeoChatViewerModel` has `shown {agent, document}`, a token-guarded `open`, `document(for:)`, `close` and `agentChanged(to:)`.
   - `agentChanged` is driven by `LeoChatLayoutHost.onChange(of: row?.id)`. That host is always mounted in the split's detail, so an agent switch reaches the model while the overlay is up.
   - `LeoWindowSession.choose(.terminal)` calls `chatViewer.close()`.
   - `LeoWindowSession.swift` moved by 3 lines while this plan was being written, so steps cite symbols, not lines.
6. Each `LeoChatFileViewerView` installs its own local keyDown monitor in `viewDidMoveToWindow` and removes it in `clear()` or when it leaves the window.
   - The monitor fires only when the first responder is a descendant that isn't a field editor (`closesOnEscape`).
   - On window entry the view focuses `contentHost.focusTarget` and retries once.
7. `LeoChatComposer` takes a *pending* focus request on appear and on every `chatFocusRequest` change (`LeoChatComposer.swift:32-33`).
8. Voice-note audio never reaches `LeoChatAttachmentView`, because `LeoChatMessageRow` filters `isAudio` out of `.voice` messages (`:45-47`). A menu on that view therefore covers images and files only.
9. The deployment target is macOS 13. `AccessibilityTraits.isModal` needs macOS 14.

## Decision: where the overlay lives (settled)
- **Host:** a SwiftUI sibling in TerminalView's top ZStack, placed right after `LeoSidebarSplit` inside the `if let leoSession` branch.
- **Why it covers everything:** it is stacked above the whole split (sidebar, terminal, chat, control bar and side panes). It ignores the same `leoSplitIgnoredEdges` as the split, so it covers exactly the split's rect, below the titlebar in every style. SwiftUI's own sizing follows window resizes.
- **Why it's safe:** split items, holding priorities and the split delegate stay untouched, so neither the launch crash nor the frozen-divider problem can come back. The command palette and the update pill stay above it.
- **Rejected: an NSView in `TerminalViewContainer`.** That file is upstream glass code and has no session. It would need a second NSHostingView for the header and its own safe-area handling.

## Decision: Escape and focus (settled)
- **One viewer view per window.** While full window, the pane keeps its viewer layout (viewer header, no composer) but leaves out its file view. So at most one Escape monitor exists per window. It can't fire twice, and nothing depends on the order of NSEvent monitors.
- **Overlay Escape scope:** the overlay viewer is built with `coversWindow: true`. Escape counts with focus anywhere in the window except in a field editor (find bar, command palette), because everything else is covered.
- **Entering:** the overlay's viewer focuses itself when it enters the window (existing code). On the expand path the pane's file view is dismantled (`clear()`). On the context-menu path the composer stays mounted but loses focus.
- **Leaving to the pane:** the pane's file view remounts and focuses itself.
- **Leaving to the thread** (✕, or exit when opened from the context menu): `session.requestChatFocus()`.

## Test commands (Xcode 26.3; targeted suites only, the full in-host suite times out)
- First check that `pgrep -fl "Leo -XCTest"` shows nothing running. Then, from `macos/`:
  `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO > /tmp/leo-build-fullwindow.log 2>&1`
- `DEVELOPER_DIR=… /opt/homebrew/bin/timeout 600 xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<Suite> …`
  If this hangs because the console is locked (LEO.md), stop and report. Never fall back to the full suite.
- Lint: `cd macos && swiftlint lint --strict --quiet`.
- Launch smoke, after any change to TerminalView: `timeout 15 <DD>/Build/Products/Debug/Leo.app/Contents/MacOS/Leo; echo $?`. 124 means it stayed alive and 6 means it died at launch. Afterwards run `defaults delete studio.blackpaw.leo.macos.debug` before trusting tests.

## Step 1: presentation state on the model
`LeoChatViewerModel.swift`:
- Add `enum Presentation: Equatable { case pane; case fullWindow(fromPane: Bool) }`. `Shown` gains `let presentation`.
- `open(_:for:fullWindow: Bool = false, download:)` sets `.fullWindow(fromPane: false)` or `.pane`. The token, `pendingAgent` and settle logic are unchanged.
- `document(for:)` (the pane's viewer layout) also returns nil for `.fullWindow(fromPane: false)`, so the pane shows the thread.
- Add `var fullWindowDocument: LeoChatViewerDocument?` and `var isFullWindow: Bool`.
- `enterFullWindow()` turns `.pane` into `.fullWindow(fromPane: true)`. Otherwise it does nothing.
- `@discardableResult func exitFullWindow() -> Bool` returns true when the pane viewer is back:
  - opened from the pane: back to `.pane`, returns true
  - opened from the thread: `close()`, returns false
  - not full window: does nothing, returns false
- `close` and `agentChanged` are unchanged and clear both views.

Failing tests first, in `macos/Tests/Leo/LeoChatViewerModelTests.swift`:
- **Expand:** `isFullWindow` is true, `fullWindowDocument` is the same document, and `document(for: a)` stays non-nil. Exit returns true, and the model is back to `.pane` with the same document.
- **Context-menu open** (`fullWindow: true`): `fullWindowDocument` is set and `document(for: a) == nil`. Exit returns false and `shown == nil`.
- **Clearing while full window, from either origin:** `close()` clears it. So does `agentChanged(to: b)`, and so do `choose(.terminal)` and `select(.chat)` through `makeSession()`.
- **Stale context-menu open:** with the download held, `agentChanged(to: b)` or `close()` means nothing is shown and nothing is opened.
- **Binary file from the context menu:** goes to `openExternally`, and `shown == nil`.
- **No-ops:** `enterFullWindow()` with nothing shown, and `exitFullWindow()` while in the pane, change nothing.

Verify: run `LeoChatViewerModelTests`. Commit.

## Step 2: Escape scope for the overlay
`LeoChatFileViewer.swift`:
- `closesOnEscape(keyCode:modifiers:isInViewer:isFieldEditor:coversWindow: Bool = false)` uses `(isInViewer || coversWindow)`.
- `LeoChatFileViewerView.init(coversWindow: Bool = false, …)` feeds `handlesEscape`.
- `LeoChatFileViewerRepresentable` gains `var coversWindow = false`.

Failing tests first, in `LeoChatFileViewerTests.escapeClosesOnlyFromTheViewerItself`: add a `coversWindow` column, with `false` for the existing rows, plus these rows:
- Esc, focus outside, not a field editor, covers → closes
- Esc, focus outside, field editor, covers → does not close
- ⌥Esc, focus outside, covers → does not close

Verify: run `LeoChatFileViewerTests`. Commit.

## Step 3: focus hand-off on the session
`LeoWindowSession.swift`:
- `func exitChatFullWindow()`: `guard chatViewer.isFullWindow`, then call `requestChatFocus()` only when `exitFullWindow()` returns false (the user is back in the thread).
- `func closeChatViewer()`: `chatViewer.close(); requestChatFocus()`. It replaces the body of `LeoChatPane.closeViewer`.
- `requestSearchFocus()` and `requestControlFocus()` call `chatViewer.exitFullWindow()` first, so Find Agent and Message Agent never focus covered chrome. This is Open question 1.

Failing tests first, in the session section of `LeoChatViewerModelTests`. After `choose(.chat)`, call `_ = session.takeChatFocusRequest()` to clear the pending request.
- exit after a context-menu open: `takeChatFocusRequest()` is true
- exit after expand: it is false, and `document(for: a) != nil`
- `closeChatViewer()` while full window: `shown == nil` and a focus request is pending
- `requestSearchFocus()` or `requestControlFocus()` while full window: `isFullWindow` is false and no chat focus request is pending

Verify: run `LeoChatViewerModelTests`, `LeoChatFocusRoutingTests` and `LeoChatAutoOpenTests`. Commit.

## Step 4: overlay view and host (glue and styling; TDD-exempt, logic covered by Steps 1–3)
New `Chat/LeoChatFullWindow.swift`:
- `struct LeoChatViewerIconButton: View(systemImage:title:action:)` is borderless and uses `title` for both `.help` and `.accessibilityLabel`. It replaces the four hand-rolled copies in `LeoChatPane`.
- `struct LeoChatFullWindowHost: View { @ObservedObject var viewer; let session: LeoWindowSession; let ignoredEdges: Edge.Set }`.
  - When `viewer.fullWindowDocument` is set, it renders the overlay.
  - Otherwise it renders nothing, which adds no hit area.
- The overlay is `VStack(spacing: 0) { header; Divider(); LeoChatFileViewerRepresentable(…) }`, with modifiers in this order:
  1. `.frame(maxWidth: .infinity, maxHeight: .infinity)`
  2. `.background(Color(nsColor: .textBackgroundColor))`
  3. `.contentShape(Rectangle())`
  4. `.onDrop(of: [.fileURL], isTargeted: nil) { _ in false }`, which keeps drops from reaching covered targets
  5. `.ignoresSafeArea(.container, edges: ignoredEdges)`
  6. `.accessibilityAddTraits(.isModal)` inside `if #available(macOS 14, *)`
- The representable gets `document`, `coversWindow: true`, `onBack: session.exitChatFullWindow` and `NSWorkspace.shared.open`. It is keyed with `.id(document.attachmentID)`.
- **Header:** a 36 pt `.bar` row with 12 pt horizontal padding. Left to right:
  - `arrow.down.right.and.arrow.up.left` "Exit Full Window", which calls `session.exitChatFullWindow`
  - the filename in `.headline`, one line, middle-truncated
  - `Spacer(minLength: 8)`
  - `arrow.up.forward.app` "Open in Default App"
  - `xmark` "Close", which calls `session.closeChatViewer`
- No animation; it opens like the in-pane viewer.

`TerminalView.swift` (`// MARK: Leo`): after `LeoSidebarSplit(...)` in the `if let leoSession, let runtime` branch, add `LeoChatFullWindowHost(viewer: leoSession.chatViewer, session: leoSession, ignoredEdges: leoSplitIgnoredEdges)`.

## Step 5: pane and attachment wiring (glue; TDD-exempt)
`LeoChatPane.swift`:
- **Viewer header:** after the `Spacer`, add `arrow.up.left.and.arrow.down.right` "Open Full Window", which calls `viewer.enterFullWindow()`. It goes before Open in Default App. Use `LeoChatViewerIconButton` throughout.
- **File view:** in the ZStack, render the file view only for `if let document, !viewer.isFullWindow`, with a comment that this is the one-viewer-per-window rule. Back and Escape call `session.closeChatViewer()`.
- **Drops:** `drop` also refuses while `viewer.isFullWindow`.
- **Environment:** `.environment(\.openChatAttachment) { attachment, fullWindow in Task { await viewer.open(attachment, for: agent, fullWindow: fullWindow, download: …) } }`.

`LeoChatAttachmentView.swift`:
- The environment value becomes `((LeoChatAttachment, _ fullWindow: Bool) -> Void)?`. When nil, it keeps downloading the file and opening it in its default app.
- Add `open(fullWindow: Bool = false)` and `openInDefaultApp()`. The second is download then NSWorkspace, and is also what the nil default does.
- `.contextMenu { Button("Open Full Window") { open(fullWindow: true) }; Button("Open in Default App", action: openInDefaultApp) }` goes on the `image` group (all states) and on enabled `fileRow`s only.

Verify:
- build, then run every `LeoChat*` suite plus `LeoWindowSessionRegistryTests` (one `-only-testing` each)
- swiftlint is clean
- the launch smoke prints 124

Commit.

## Step 6: debug-app verification (`.autopilot/verify.md`: isolated launch, Peekaboo `--capture-engine cg`)
1. Use `autopilot-scratch` only. Filter the sidebar to it and never press Return. Reuse `notes.md`, `shot.png`, `doc.pdf` and `blob.bin`.
2. For md, png and pdf: open in the pane, then Expand, and shoot. The overlay must cover the sidebar, terminal or chat, and the control bar, with the titlebar still visible. Shoot once more with the editor pane open.
3. Exit Full Window and shoot: the in-pane viewer shows. Expand again, press Escape **once** and shoot: the in-pane viewer shows, not the thread. That proves a single Escape.
4. Press ✕ while full window and shoot: the thread shows with the composer focused.
5. Right-click an image and a file row and shoot each menu. Open Full Window and shoot, then Escape and shoot: the thread shows. Open in Default App opens the default app. `blob.bin` via Open Full Window opens the default app while the thread stays.
6. While full window, resize narrow, then wide, crossing the chat replace/side-by-side threshold. Shoot each: the overlay tracks the window and stays open.
7. In a full-window `.md`, press ⌘F and shoot the find bar. The first Escape closes the find bar and the second exits.
8. While full window:
   - switch agents with the keyboard and shoot: the overlay is gone
   - use the Terminal toggle shortcut and shoot: the overlay is gone
   - use Find Agent and shoot: the overlay has exited
9. Drag a Finder file onto the overlay over the terminal and over the chat. Nothing attaches and no path is pasted.
10. Relaunch with `macos-titlebar-style = hidden` in the isolated config. Shoot: the overlay covers the top strip too.
11. Return the PNG paths for the orchestrator to post.

## Accepted risks
- While the overlay is up the thread still counts as on screen, so new messages are marked read. This matches the in-pane viewer.
- Other actions that move focus under the overlay leave it up with keys going to hidden content. Examples are a new terminal split taking focus, or a stray chat focus request reaching the mounted composer on the context-menu path. Escape (`coversWindow`) and ✕ still recover.
- Ghostty's tracking areas under the overlay may still update the cursor or link hover. The chat already has the same behavior when it replaces the terminal.
- On macOS 13 there is no `isModal` trait, so VoiceOver can reach covered content.
- Exiting back to the pane recreates the pane's file view, so the scroll position inside the file is lost.
- With focus in the overlay, ⌘W behaves as it does today with focus in the composer.

## Open questions (not settled by spec)
1. Find Agent and Message Agent exit full window to its origin before focusing (plan: yes). Alternatively they could close everything, or do nothing.
2. With the hidden titlebar, the overlay header sits at the window's top edge with no inset, since there are no window buttons there. Is that acceptable?
3. Should there be a keyboard shortcut for Open Full Window? The plan adds none; the spec lists none.

## Orchestrator decisions on open questions
1. Yes: Find Agent / Message Agent exit full window to its origin before focusing.
2. Acceptable: no inset for the hidden-titlebar style.
3. No keyboard shortcut (not in spec).
