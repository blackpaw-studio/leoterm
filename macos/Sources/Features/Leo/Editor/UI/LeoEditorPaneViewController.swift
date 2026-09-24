import AppKit
import Combine

/// The window's editor pane (the trailing split item beside the terminal):
/// header, inline banner, and text view, bound to a `LeoEditorPaneModel`.
/// It collapses its own split item while no file is open, checks the disk
/// whenever its window becomes key, and closes on ⌘W while it has focus.
final class LeoEditorPaneViewController: NSViewController {
    static let minimumWidth: CGFloat = 320

    let model: LeoEditorPaneModel
    private let header = LeoEditorHeaderView()
    let banner = LeoEditorBannerView()
    private let scrollView: NSScrollView
    let textView: LeoEditorTextView
    private var modelSubscriptions: Set<AnyCancellable> = []
    private var documentSubscriptions: Set<AnyCancellable> = []
    private var keyWindowObserver: NSObjectProtocol?
    private weak var shownDocument: LeoEditorDocument?
    private var shownRevision = 0
    private var appliedReveal: UUID?

    /// Binds to the model right away: a collapsed split item's view isn't
    /// loaded until it is shown, so binding in `loadView` would never show it.
    init(model: LeoEditorPaneModel) {
        self.model = model
        (scrollView, textView) = LeoEditorTextView.make()
        super.init(nibName: nil, bundle: nil)
        textView.delegate = self
        header.onSelectRecent = { [weak self] fileID in self?.openRecent(fileID) }
        header.onClose = { [weak self] in self?.closePane() }
        banner.onAction = { [weak self] action in self?.perform(action) }
        model.confirmUnsaved = { [weak self] document in
            await self?.confirmUnsavedChanges(document) ?? .cancel
        }
        bindModel()
        observeKeyWindow()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    }

    override func loadView() {
        let separator = NSBox()
        separator.boxType = .separator
        let rows = [header, separator, banner, scrollView]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        stack.setAccessibilityLabel("Editor pane")
        // `.width` alignment alone leaves a row as narrow as its content:
        // the banner then sat at the trailing edge (B-045). Every row spans
        // the pane.
        NSLayoutConstraint.activate(rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        view = stack
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth).isActive = true
    }

    // MARK: - Actions (responder chain, while focus is in the pane)

    /// ⌘W with focus in the pane closes the editor, not the terminal.
    @objc func close(_ sender: Any?) {
        closePane()
    }

    /// A pane just shown may join its window only on the next layout, so
    /// a focus request that can't land yet is retried once, next turn.
    func focusText() {
        if let window = view.window, window.makeFirstResponder(textView) { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = view.window else { return }
            window.makeFirstResponder(textView)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        textView.fillVisibleHeight()
    }

    var hasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    // MARK: - Binding

    private func bindModel() {
        model.$document
            .receive(on: DispatchQueue.main)
            .sink { [weak self] document in self?.show(document) }
            .store(in: &modelSubscriptions)
        model.$recents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshChrome() }
            .store(in: &modelSubscriptions)
        model.$reveal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reveal in self?.apply(reveal) }
            .store(in: &modelSubscriptions)
        // A close waiting on the document says so (a pending quit offers to
        // quit anyway), and locks the text once it's decided.
        model.$leaveAnyway.map { _ in () }
            .merge(with: model.$isWaitingToClose.map { _ in () }, model.$isOfferShowing.map { _ in () }, model.$isCommittedToClose.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshChrome() }
            .store(in: &modelSubscriptions)
    }

    private func show(_ document: LeoEditorDocument?) {
        setLeoSplitItemCollapsed(document == nil, openingAtHalfWidth: true)
        documentSubscriptions.removeAll()
        guard let document else {
            shownDocument = nil
            refreshChrome()
            return
        }
        if document !== shownDocument {
            shownDocument = document
            shownRevision = document.contentRevision
            textView.documentUndoManager = UndoManager()
            textView.language = document.language
            textView.isEditable = isEditable(document)
            textView.load(document.text, keepingSelection: false)
            appliedReveal = nil
            apply(model.reveal)
            focusText()
        }
        // Chrome follows every published change (the next run-loop turn,
        // after the value has landed).
        document.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.documentChanged() }
            .store(in: &documentSubscriptions)
        refreshChrome()
    }

    private func documentChanged() {
        guard let document = shownDocument else { return }
        if document.contentRevision != shownRevision {
            shownRevision = document.contentRevision
            textView.documentUndoManager.removeAllActions()
            textView.isEditable = isEditable(document)
            textView.load(document.text, keepingSelection: true)
        }
        refreshChrome()
    }

    private func refreshChrome() {
        header.update(document: model.document, recents: model.recents)
        banner.show(shownBanner)
        if let document = shownDocument { textView.isEditable = isEditable(document) }
    }

    /// Read-only once a close is decided (its prompt answered, or none
    /// needed) and waits on the document: nothing typed then would be
    /// kept, or a save queued behind it would write it after Don't Save.
    /// Still editable while the close merely waits its turn.
    private func isEditable(_ document: LeoEditorDocument) -> Bool {
        !document.isReadOnly && !model.isCommittedToClose
    }

    /// The banner for the model as it is now.
    var shownBanner: LeoEditorBanner? {
        LeoEditorBanner.current(
            for: model.document, isQuitWaiting: model.leaveAnyway != nil && model.isWaitingToClose, canLeave: !model.isOfferShowing,
            isWaitingToClose: model.isWaitingToClose
        )
    }

    private func apply(_ reveal: LeoEditorReveal?) {
        guard let reveal, reveal.id != appliedReveal, reveal.fileID == shownDocument?.fileID else { return }
        appliedReveal = reveal.id
        textView.reveal(line: reveal.line, column: reveal.column)
        focusText()
    }

    // MARK: - Disk checks

    /// No timers: the disk is checked when the window becomes key (and by
    /// every save). Observed for every window, since the pane can be built
    /// before it has one.
    private func observeKeyWindow() {
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isViewLoaded, let window = self.view.window, notification.object as? NSWindow === window,
                      let document = self.model.document else { return }
                Task { await document.checkDisk() }
            }
        }
    }

    // MARK: - Helpers

    func perform(_ action: LeoEditorBanner.Action) {
        guard let document = model.document else { return }
        switch action {
        case .quitAnyway: model.leaveAnyway?()
        case .reload: Task { await document.reload() }
        case .keepMine: document.keepMine()
        case .dismissError: document.dismissError()
        }
    }

    private func openRecent(_ fileID: LeoEditorFileID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await model.open(fileID)
            } catch {
                LeoEditorAlerts.presentError(error, on: view.window)
            }
            // A cancelled switch leaves the pop-up on the open file.
            refreshChrome()
        }
    }

    private func closePane() {
        let window = view.window
        Task { [weak self] in
            guard let self, await model.close() else { return }
            // Focus goes back to the terminal beside the pane.
            if let controller = window?.windowController as? BaseTerminalController, let surface = controller.focusedSurface {
                Ghostty.moveFocus(to: surface)
            }
        }
    }

    private func confirmUnsavedChanges(_ document: LeoEditorDocument) async -> LeoUnsavedChangesChoice {
        guard let window = view.window else { return .cancel }
        return await LeoEditorAlerts.confirmUnsavedChanges(to: document.displayName, on: window)
    }
}

extension LeoEditorPaneViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard model.edit(textView.string, revision: shownRevision) else {
            // A close is decided and the lock hadn't landed yet: put the
            // document's text back and lock now.
            guard let document = shownDocument else { return }
            textView.revertEdit(to: document.text)
            textView.isEditable = isEditable(document)
            return
        }
        textView.highlightEdits()
    }
}
