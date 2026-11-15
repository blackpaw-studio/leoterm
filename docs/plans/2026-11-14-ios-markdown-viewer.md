# iOS rendered Markdown viewer: implementation plan

Spec: `docs/specs/2026-11-14-ios-markdown-viewer.md` (it wins any conflict with this plan). Branch `feat/ios-markdown-viewer`.
Platform call: iOS-only UI. Parsing goes in LeoKit (plain Swift, Foundation only).

**Mac adopts the LeoKit block model: no.** `LeoMarkdownRenderer` streams Foundation runs straight into TextKit 1 paragraphs. Its `NSTextTable`/`NSTextList` placement is keyed by per-run `PresentationIntent` identity, not by a tree. Moving it onto the block model means rewriting its `Builder` and redoing the B-278 visual checks, which is neither small nor low-risk. Leave `macos/` untouched. Follow-up for the backlog: point Mac `isAllowedLink` at `LeoMarkdownLinkPolicy` so one allowlist serves both apps.

## Step 1: LeoKit block model and parser (TDD)
New `Packages/LeoKit/Sources/LeoKit/Markdown/`. Every type is `public`, `Equatable` and `Sendable`.
- `LeoMarkdownDocument.swift`:
  - `struct LeoMarkdownDocument { let blocks: [LeoMarkdownBlock]; static func parse(_: String) -> LeoMarkdownDocument }`. It never throws.
  - `indirect enum LeoMarkdownBlock { heading(level: Int, [LeoMarkdownRun]), paragraph([LeoMarkdownRun]), list(LeoMarkdownList), code(language: String?, text: String), quote([LeoMarkdownBlock]), rule, table(LeoMarkdownTable) }`.
  - `struct LeoMarkdownList { isOrdered: Bool; start: Int; items: [[LeoMarkdownBlock]] }`.
  - `struct LeoMarkdownTable { alignments: [Alignment]; header: [[LeoMarkdownRun]]; rows: [[[LeoMarkdownRun]]] }`, where `Alignment` is `.leading/.center/.trailing`.
  - `struct LeoMarkdownRun { text: String; traits: Traits; link: URL? }`, where `Traits: OptionSet` holds `emphasis, strong, code, strikethrough, image`.
- `LeoMarkdownLinkPolicy.swift`: `enum LeoMarkdownLinkPolicy { static let schemes: Set<String> = ["http","https","mailto"]; static func allows(_ url: URL) -> Bool }`. The scheme check is case-insensitive.
- `LeoMarkdownParser.swift` (internal). Parse with `AttributedString(markdown:options:)` using `.full` and `.returnPartiallyParsedIfPossible`, the same options as the Mac.
  - For each run, take `presentationIntent.components.reversed()` as a path of (kind, identity), outermost first.
  - Insert each run into a tree keyed by identity, keeping children in first-seen order. Then fold the tree into blocks.
  - Soft break becomes `" "` and hard break becomes `"\n"`.
  - An image run becomes its alt text with `.image` and `link == nil`.
  - A link survives only if `LeoMarkdownLinkPolicy.allows` passes.
  - Trim trailing `"\n"` from code text.
  - The ordered-list `start` is the first item's ordinal.
  - Pad or truncate each table row to the column count.
  - A run with no intent becomes a paragraph.
  - If the parser throws, return `[.paragraph([plain text])]`.
- Tests go in `Packages/LeoKit/Tests/LeoKitTests/LeoMarkdownParserTests.swift` (Swift Testing). Write each one red first, in this order:
  1. `# A` … `###### F` give `heading(level:)` 1–6 with their text.
  2. Paragraph inline traits: `*em*`, `**strong**`, `` `code` ``, `~~del~~`, and `***both***` (strong + emphasis).
  3. Nested list: `- a\n  - b\n1. x` gives an unordered list whose item holds a nested list, plus a separate ordered list; `3. x` gives `start == 3`.
  4. Fenced code with ` ```swift ` gives `code(language: "swift", …)` with the text exact and no trailing newline.
  5. `> q` gives `quote([paragraph])`, and `---` gives `rule`.
  6. GitHub table: header cells, alignment from `:--:`, row cells, and a ragged row padded to the column count.
  7. Links: `http`, `https`, `HTTPS` and `mailto` are kept. `javascript:`, `file:`, `tel:` and relative `foo.md` give `link == nil` with the text kept.
  8. Image `![alt](https://x/y.png)` gives a run with text `alt`, `.image`, and no link.
  9. Malformed input never crashes and returns something sensible: `""` gives no blocks; an unterminated fence gives a code block to EOF; 200 nested `>`; NUL/control bytes; `|` noise lines.
- Verify with `cd Packages/LeoKit && swift test --filter LeoMarkdown`.
- Commit: `feat(leokit): Markdown block model and parser`.

## Step 2: LeoKit attachment classification (TDD)
- Add `public var isMarkdown: Bool` to `LeoChatAttachment` in `Chat/LeoChatModels.swift`. It is true when the filename extension is `md` or `markdown` (case-insensitive), or the mime is `text/markdown` or `text/x-markdown`.
- Write the failing test first in `LeoKitTests/LeoChatAttachmentKindTests.swift`. Cases: `README.md`, `notes.MARKDOWN`, `x.txt` with mime `text/markdown`, `x.md.txt` (false), and `x.pdf` (false).
- Commit: `feat(leokit): classify Markdown chat attachments`.

## Step 3: iOS inline text (hosted TDD)
- `ios/Leo/Chat/Markdown/ChatMarkdownText.swift`: `enum ChatMarkdownText { static func attributed(_ runs: [LeoMarkdownRun], style: Style, traits: UITraitCollection) -> NSAttributedString }`.
  - `Style` is one of `.body`, `.heading(Int)`, `.tableHeader`, `.quote`.
  - Headings map to text styles: h1 `.title1` bold, h2 `.title2` bold, h3 `.title3` semibold, h4 `.headline`, h5 `.subheadline` semibold, h6 `.footnote` semibold.
  - Code uses `UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont)` on a tertiary fill.
  - Bold and italic come from symbolic traits. Images use secondary color plus italic. Quotes use `secondaryLabel`.
  - The `.link` attribute is set only from `run.link`.
- Tests in `ios/LeoTests/ChatMarkdownTextTests.swift`, red first:
  - An allowed link carries `.link`; a filtered run carries none.
  - Strong and emphasis give bold+italic font traits.
  - Font size grows under `.accessibilityExtraLarge` traits.
- Commit.

## Step 4: iOS block views
`ios/Leo/Chat/Markdown/ChatMarkdownBlockViews.swift`: `enum ChatMarkdownBlockViews { static func view(for: LeoMarkdownBlock, traits:) -> UIView }`. It is recursive and returns a vertical `UIStackView` of views.
- Text blocks use a non-editable, selectable `UITextView` with `isScrollEnabled = false`. `dataDetectorTypes = []` so no automatic links appear outside the allowlist.
- Lists: one row per item, with a marker label (`1.` / `•` `◦` `▪` by depth) and a stack of the item's child blocks.
- Quotes: a 3 pt `tertiaryLabel` bar view plus a child stack.
- Code: a horizontal `UIScrollView` around an unwrapped monospaced text view on `secondarySystemBackground`.
- Rule: a hairline `separator` view.
- Tables: a horizontal `UIScrollView` (`accessibilityIdentifier "markdown.table"`) around a grid of cell text views.
  - Column width = `min(maxColumnWidth = 280pt, widest natural cell)`, so cells wrap inside that width.
  - Borders are 1 px views. The header row gets a fill.
  - Every color is a dynamic `UIColor` and no layer `CGColor` is used, so light and dark switch without a refresh.
- Tests in `ios/LeoTests/ChatMarkdownBlockViewsTests.swift`, red first, laid out at 390 pt width:
  - An 8-column table's scroll view has `contentSize.width > bounds.width`.
  - A 2-column table fits the width.
  - A nested list renders markers `•` then `◦`.
  - A code block does not wrap: its content is wider than the bounds for a long line.
- Styling details are a TDD exception (UI styling), checked by screenshots instead.
- Commit.

## Step 5: iOS viewer controller
`ios/Leo/Chat/Markdown/ChatMarkdownViewController.swift` takes `init(text: String, fileURL: URL, title: String)`.
- Nav bar:
  - `titleView`: a `UISegmentedControl` [Rendered, Raw], default 0, id `markdown.mode`. The filename goes in `navigationItem.title` for VoiceOver.
  - Left: a Done button.
  - Right: Share (`UIBarButtonItem(systemItem: .action)`), which opens `UIActivityViewController([fileURL])` anchored on `barButtonItem` for iPad. The sheet covers Open in / Save to Files.
- Rendered view: a vertical `UIScrollView` (`markdown.rendered`) containing the block stack, with readable-width margins.
- Raw view: a `UITextView` (`markdown.raw`) that is non-editable, selectable, monospaced and Dynamic Type scaled, with `dataDetectorTypes = []`.
- `registerForTraitChanges([UITraitPreferredContentSizeCategory.self])` rebuilds the rendered stack.
- Parsing runs once in `viewDidLoad`. That is synchronous; accepted risk because chat attachments are small. Note it in the commit.
- Tests in `ios/LeoTests/ChatMarkdownViewerTests.swift`:
  - Rendered shows by default and Raw is hidden.
  - Toggling shows Raw with `text == input`.
  - The Share item exists.
- Commit.

## Step 6: open-path selection (hosted TDD)
- `ChatPresentation.swift`: add `@MainActor static func viewer(for attachment: LeoChatAttachment, url: URL) -> UIViewController`.
  - If `attachment.isMarkdown` and `Data(contentsOf: url)` succeeds, return `UINavigationController(root: ChatMarkdownViewController(text: String(decoding: data, as: UTF8.self), …))`. Lossy decoding means it never crashes.
  - Otherwise return `ChatQuickLookController(url:title:)`. QuickLook also covers an unreadable file and shows its own error.
- `ChatThreadViewController.swift:477`: replace the hard-coded `ChatQuickLookController` with `present(ChatPresentation.viewer(for: attachment, url: url), animated: true)`. Images still go to the gallery before this point, so they are unaffected.
- `ChatMessageCell.swift` file chip (around line 342): add `accessibilityIdentifier = "chat.file.\(attachment.id)"` for the UI test.
- Tests in `ios/LeoTests/ChatPresentationViewerTests.swift`, red first:
  - `.md` with a temp file gives a nav controller whose top is `ChatMarkdownViewController`.
  - `.pdf` gives `ChatQuickLookController`.
  - `.md` with a missing file gives `ChatQuickLookController`.
- Commit.

## Step 7: fixture, UI test, project
- `ios/Leo/App/ChatMarkdownFixture.swift` (`#if DEBUG`), started with the `-chatMarkdownFixture` launch argument and layered on `-navFixture`. Wire it into `NavFixture.isRequested` and `NavFixture.prepare`, copying `ChatImagesFixture`.
  - agent-0's thread gets one message with `sample.md` (`text/markdown`) and `notes.txt`.
  - `download` writes a sample doc to temp. The sample covers h1–h3, emphasis/strong/code/strike, a nested ordered+unordered list, a Swift code block, a quote, a rule, an https link, a `javascript:` link, an image, and an 8-column wide table.
- `ios/LeoUITests/LeoChatMarkdownViewerTests.swift` (XCTest). Reuse the `snapshot(_:)` helper pattern from `LeoChatImageViewerTests`.
  - Open thread, tap `chat.file.sample`, and assert the `markdown.mode` segment, the h1 text, and `markdown.rendered`. Snapshot `md-rendered`.
  - Select Raw and assert `markdown.raw`. Snapshot `md-raw`.
  - Back on Rendered, scroll to `markdown.table` and swipe left. Snapshot `md-table-scrolled`.
  - A second test taps `chat.file.notes` and asserts the QuickLook view, not `markdown.mode`.
- Run `cd ios && xcodegen generate` and commit `Leo.xcodeproj`, because CI fails on drift.
- Commit: `feat(ios): render Markdown chat attachments natively`.

## Verification
- **LeoKit (each fix round):** `cd Packages/LeoKit && swift test --filter 'LeoMarkdown|LeoChatAttachmentKind'`.
- **iOS build** (`heavy`, run in the background, from `ios/`): `heavy xcodebuild build-for-testing -project Leo.xcodeproj -scheme Leo -destination "platform=iOS Simulator,name=iPhone 17 Pro" -derivedDataPath <scratchpad>/dd-ios -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`.
- **Targeted iOS tests:**
  ```
  xcodebuild test-without-building <same project/scheme/destination/derivedData> \
    -only-testing:LeoTests/ChatMarkdownTextTests \
    -only-testing:LeoTests/ChatMarkdownBlockViewsTests \
    -only-testing:LeoTests/ChatMarkdownViewerTests \
    -only-testing:LeoTests/ChatPresentationViewerTests
  ```
- **Screenshots:**
  1. `xcrun simctl ui "iPhone 17 Pro" appearance light`.
  2. `TEST_RUNNER_LEO_SCREENSHOTS=<abs scratchpad>/md-light xcodebuild test-without-building … -only-testing:LeoUITests/LeoChatMarkdownViewerTests`.
  3. Repeat both commands with `appearance dark` into `md-dark`.
  4. Open and audit every PNG at native pixels: table borders, list markers, code fill, the `javascript:` link shown plain, and no clipped text.
  5. The orchestrator posts them with `leo_chat_post`.
- **Merge gate (once):**
  - Full `swift test` in `Packages/LeoKit` and `ios/LeoFeatures`.
  - Full app tests with CI's `-skip-testing` list.
  - `swiftlint lint --strict` on the touched files.
  - `git diff --exit-code ios/Leo.xcodeproj` after `xcodegen generate`.

