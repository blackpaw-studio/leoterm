import AppKit
import SwiftUI

/// A downloaded attachment, read-only, in the chat pane. It reuses the
/// editor's content row (text, rendered Markdown, image, movie, Quick Look)
/// but never edits: the text view is not editable, and there is no save.
final class LeoChatFileViewerView: NSView {
    private static let escapeKeyCode: UInt16 = 53

    let contentHost: LeoEditorContentHostView
    private let openExternally: (URL) -> Void
    private let onBack: () -> Void
    /// Set when this view fills the window, so nothing else is left for Escape
    /// to mean: it counts with focus anywhere (bar a field editor).
    private let coversWindow: Bool
    private var shownDocument: LeoChatViewerDocument?
    private var keyMonitor: Any?

    init(coversWindow: Bool = false, openExternally: @escaping (URL) -> Void, onBack: @escaping () -> Void) {
        let (scrollView, textView) = LeoEditorTextView.make()
        textView.isEditable = false
        contentHost = LeoEditorContentHostView(textScrollView: scrollView, textView: textView)
        self.openExternally = openExternally
        self.onBack = onBack
        self.coversWindow = coversWindow
        super.init(frame: .zero)
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentHost)
        NSLayoutConstraint.activate([
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        contentHost.onUnavailableAction = { [weak self] _ in
            guard let url = self?.shownDocument?.url else { return }
            self?.openExternally(url)
        }
        setAccessibilityLabel("Attachment")
    }

    required init?(coder: NSCoder) { nil }

    deinit { removeKeyMonitor() }

    func show(_ document: LeoChatViewerDocument) {
        guard document != shownDocument else { return }
        shownDocument = document
        var text = ""
        if case let .text(body, _) = document.body {
            text = body
            contentHost.textView.language = LeoEditorLanguage(path: document.filename)
            contentHost.textView.load(body, keepingSelection: false)
        }
        contentHost.show(document.content, source: { text }, name: document.displayName, revealTitle: "Open in Default App")
    }

    /// Lets go of a previewed movie or Quick Look file.
    func clear() {
        shownDocument = nil
        contentHost.clear()
        removeKeyMonitor()
    }

    /// Escape is Back, unless the key belongs to something inside: the find
    /// bar's field, or (side by side) a terminal that isn't this view. A view
    /// that covers the window owns every key that isn't in a field.
    static func closesOnEscape(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isInViewer: Bool, isFieldEditor: Bool, coversWindow: Bool = false
    ) -> Bool {
        keyCode == escapeKeyCode && modifiers.isDisjoint(with: .deviceIndependentFlagsMask) && (isInViewer || coversWindow) && !isFieldEditor
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return removeKeyMonitor() }
        installKeyMonitor()
        focusContent()
    }

    /// A view just shown may join its window only on the next layout, so a
    /// focus request that can't land yet is retried once, next turn.
    private func focusContent() {
        if let window, window.makeFirstResponder(contentHost.focusTarget) { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(contentHost.focusTarget)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window, handlesEscape(event) else { return event }
            onBack()
            return nil
        }
    }

    private func handlesEscape(_ event: NSEvent) -> Bool {
        let responder = window?.firstResponder
        return Self.closesOnEscape(
            keyCode: event.keyCode, modifiers: event.modifierFlags,
            isInViewer: (responder as? NSView)?.isDescendant(of: self) == true,
            isFieldEditor: (responder as? NSText)?.isFieldEditor == true,
            coversWindow: coversWindow
        )
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }
}

/// The viewer inside the chat pane. Key it by `document.attachmentID` so
/// opening another file makes a fresh view.
struct LeoChatFileViewerRepresentable: NSViewRepresentable {
    let document: LeoChatViewerDocument
    var coversWindow = false
    let onBack: () -> Void
    let openExternally: (URL) -> Void

    func makeNSView(context: Context) -> LeoChatFileViewerView {
        let view = LeoChatFileViewerView(coversWindow: coversWindow, openExternally: openExternally, onBack: onBack)
        view.show(document)
        return view
    }

    func updateNSView(_ view: LeoChatFileViewerView, context: Context) {
        view.show(document)
    }

    static func dismantleNSView(_ view: LeoChatFileViewerView, coordinator: ()) {
        view.clear()
    }
}
