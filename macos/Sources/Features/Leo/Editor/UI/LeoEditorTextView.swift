import AppKit

/// The editor's text view: plain monospaced text with the built-in
/// highlighter, and its own undo stack (the window's undo manager is the
/// app's, which undoes closing tabs, not typing).
final class LeoEditorTextView: NSTextView {
    /// Highlight the whole document on every edit up to this size (UTF-16
    /// units); beyond it, only the edited lines (a construct opened above
    /// them, like a block comment, may then be coloured stale).
    static let fullHighlightLimit = 256_000
    /// Beyond this, no highlighting at all (a read-only 20 MB log shows as
    /// plain text rather than stalling on the regex pass).
    static let highlightLimit = 2_000_000

    var language = LeoEditorLanguage.plainText
    let theme = LeoSyntaxTheme.system()
    /// Set per document, so switching files never undoes into another file.
    var documentUndoManager = UndoManager()
    /// Where edits landed since the last highlight pass.
    private var pendingHighlight: NSRange?

    static func make() -> (NSScrollView, LeoEditorTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = LeoEditorTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.configure()
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = NSSize(width: 6, height: 8)
        font = theme.font
        textColor = theme.plainColor
        backgroundColor = .textBackgroundColor
        typingAttributes = [.font: theme.font, .foregroundColor: theme.plainColor]
        textStorage?.delegate = self
        setAccessibilityLabel("Editor")
    }

    /// Replaces the whole text (a newly opened or reloaded file), keeping
    /// the selection where it still fits.
    func load(_ text: String, keepingSelection: Bool) {
        let selection = selectedRange()
        string = text
        highlightAll()
        pendingHighlight = nil
        let length = (text as NSString).length
        let location = keepingSelection ? min(selection.location, length) : 0
        setSelectedRange(NSRange(location: location, length: 0))
        if !keepingSelection { scrollToBeginningOfDocument(nil) }
    }

    /// Puts the caret on `line` (and `column`), 1-based, and scrolls to it.
    func reveal(line: Int, column: Int?) {
        let text = string as NSString
        var location = 0
        var current = 1
        while current < line, location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            current += 1
        }
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        var lineEnd = NSMaxRange(lineRange)
        while lineEnd > lineRange.location, let scalar = UnicodeScalar(text.character(at: lineEnd - 1)),
              CharacterSet.newlines.contains(scalar) {
            lineEnd -= 1
        }
        let caret = min(location + max((column ?? 1) - 1, 0), lineEnd)
        setSelectedRange(NSRange(location: caret, length: 0))
        scrollRangeToVisible(lineRange)
        showFindIndicator(for: lineRange.length > 0 ? lineRange : NSRange(location: caret, length: 0))
    }

    /// Re-highlights after a user edit.
    func highlightEdits() {
        guard let storage = textStorage, let edited = pendingHighlight else { return }
        pendingHighlight = nil
        guard storage.length <= Self.highlightLimit else { return }
        if storage.length <= Self.fullHighlightLimit {
            highlightAll()
        } else {
            let range = (storage.string as NSString).paragraphRange(for: NSIntersectionRange(edited, NSRange(location: 0, length: storage.length)))
            LeoSyntaxHighlighter.apply(to: storage, language: language, theme: theme, in: range)
        }
    }

    private func highlightAll() {
        guard let storage = textStorage else { return }
        let language = storage.length <= Self.highlightLimit ? language : .plainText
        LeoSyntaxHighlighter.apply(to: storage, language: language, theme: theme)
    }

    /// At least as tall as the visible area, so a click below a short
    /// file's last line still lands in the text.
    func fillVisibleHeight() {
        guard let height = enclosingScrollView?.contentSize.height, minSize.height != height else { return }
        minSize = NSSize(width: 0, height: height)
        sizeToFit()
    }

    // MARK: - Undo (own stack)

    override var undoManager: UndoManager? { documentUndoManager }

    @objc func undo(_ sender: Any?) {
        documentUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        documentUndoManager.redo()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            item.title = documentUndoManager.undoMenuItemTitle
            return isEditable && documentUndoManager.canUndo
        case #selector(redo(_:)):
            item.title = documentUndoManager.redoMenuItemTitle
            return isEditable && documentUndoManager.canRedo
        default:
            return super.validateMenuItem(item)
        }
    }
}

extension LeoEditorTextView: NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        pendingHighlight = pendingHighlight.map { NSUnionRange($0, editedRange) } ?? editedRange
    }
}
