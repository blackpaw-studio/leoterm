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
    /// The selection when the pending user edit began.
    private var selectionBeforeEdit: NSRange?

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
    /// a caret where the selection began, if it still fits: the new text
    /// may be unrelated, so a selection over it would be meaningless.
    func load(_ text: String, keepingSelection: Bool) {
        let location = keepingSelection ? selectedRange().location : 0
        load(text, selecting: NSRange(location: location, length: 0))
        if !keepingSelection { scrollToBeginningOfDocument(nil) }
    }

    /// Undoes a refused user edit: back to `text`, with the selection the
    /// edit replaced (typing collapses it to a caret).
    func revertEdit(to text: String) {
        let selection = selectionBeforeEdit ?? selectedRange()
        selectionBeforeEdit = nil
        load(text, selecting: selection)
    }

    /// Sets `text` and selects `selection`, clamped to it and widened to
    /// whole composed characters (never half a surrogate pair).
    private func load(_ text: String, selecting selection: NSRange) {
        string = text
        highlightAll()
        pendingHighlight = nil
        let nsText = text as NSString
        let location = min(selection.location, nsText.length)
        let clamped = NSRange(location: location, length: min(selection.length, nsText.length - location))
        let snapped = clamped.length > 0
            ? nsText.rangeOfComposedCharacterSequences(for: clamped)
            : NSRange(location: location < nsText.length ? nsText.rangeOfComposedCharacterSequence(at: location).location : location, length: 0)
        setSelectedRange(snapped)
    }

    /// Records the selection before the first step of a user edit (a
    /// compound one, like a smart substitution, asks more than once). A
    /// vetoed first step never reaches `didChangeText`, so it drops its
    /// own record.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let isFirstStep = selectionBeforeEdit == nil
        if isFirstStep { selectionBeforeEdit = selectedRange() }
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if !allowed, isFirstStep { selectionBeforeEdit = nil }
        return allowed
    }

    /// The edit has landed (and `textDidChange` has run): forget it.
    override func didChangeText() {
        super.didChangeText()
        selectionBeforeEdit = nil
    }

    /// Where `reveal` puts the caret, and the line it's on.
    struct Caret: Equatable {
        let location: Int
        let line: NSRange
    }

    /// Puts the caret on `line` (and `column`), 1-based, and scrolls to it.
    func reveal(line: Int, column: Int?) {
        let caret = Self.caret(line: line, column: column, in: string as NSString)
        setSelectedRange(NSRange(location: caret.location, length: 0))
        scrollRangeToVisible(caret.line)
        showFindIndicator(for: caret.line.length > 0 ? caret.line : NSRange(location: caret.location, length: 0))
    }

    /// The caret for `line` and `column` (1-based) in `text`: past the
    /// last line, on it; past the end of its line, at the end. Any `Int`
    /// is safe.
    static func caret(line: Int, column: Int?, in text: NSString) -> Caret {
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
        // Clamped before adding: `column` comes from terminal output.
        let offset = min(max(column ?? 1, 1) - 1, text.length)
        return Caret(location: min(location + offset, lineEnd), line: lineRange)
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
