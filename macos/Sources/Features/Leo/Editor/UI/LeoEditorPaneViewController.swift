import AppKit
import Combine

/// One editor tab's view (B-273): header, inline banner, and text view,
/// bound to a `LeoEditorPaneModel`. It checks the disk whenever its window
/// becomes key (or it's shown again), and closes on ⌘W while it has
/// focus. It never takes focus by itself -- not on a new document, not on
/// a reveal -- so a file opened in the background leaves focus where it
/// is; `LeoEditorTabsViewController` focuses it when the user asks. One
/// per tab, so undo, scroll and selection survive switching tabs.
final class LeoEditorPaneViewController: NSViewController {
    static let minimumWidth: CGFloat = 320

    let model: LeoEditorPaneModel
    /// How far below the pane's top edge its header row starts, centred on
    /// the sidebar header's line; nil keeps the header's own row. See
    /// `LeoTitlebarInsets.sidePaneHeaderTopInset`.
    private let headerTopInset: CGFloat?
    private let header = LeoEditorHeaderView()
    private let separator = NSBox()
    let banner = LeoEditorBannerView()
    private let scrollView: NSScrollView
    let textView: LeoEditorTextView
    private var modelSubscriptions: Set<AnyCancellable> = []
    private var documentSubscriptions: Set<AnyCancellable> = []
    private var keyWindowObserver: NSObjectProtocol?
    private weak var shownDocument: LeoEditorDocument?
    private var shownRevision = 0
    private var appliedReveal: UUID?
    /// The files the header's pop-up offers; the model's own by default.
    var recents: () -> [LeoEditorFileID]
    /// Opens a file the header's pop-up offers.
    var onSelectRecent: ((LeoEditorFileID) -> Void)?
    /// Closes this tab (the header's button, ⌘W); closes the document by default.
    var onCloseRequest: (() -> Void)?

    /// Binds to the model right away: a collapsed split item's view isn't
    /// loaded until it is shown, so binding in `loadView` would never show it.
    init(model: LeoEditorPaneModel, headerTopInset: CGFloat? = nil) {
        self.model = model
        self.headerTopInset = headerTopInset
        (scrollView, textView) = LeoEditorTextView.make()
        recents = { [weak model] in model?.recents ?? [] }
        super.init(nibName: nil, bundle: nil)
        textView.delegate = self
        header.onSelectRecent = { [weak self] fileID in self?.openRecent(fileID) }
        header.onClose = { [weak self] in self?.closePane() }
        banner.onAction = { [weak self] action in self?.perform(action) }
        bindModel()
        observeKeyWindow()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    }

    override func loadView() {
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
        if let headerTopInset {
            LeoTitlebarInsets.insetHeader(of: stack, at: headerTopInset, centring: header.closeControl)
        }
        view = stack
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth).isActive = true
    }

    /// Puts the pane's tab strip (B-273) under this tab's header. One strip
    /// serves every tab: it moves to the tab on screen.
    func install(tabBar: NSView) {
        guard let stack = view as? NSStackView, tabBar.superview !== stack,
              let index = stack.arrangedSubviews.firstIndex(of: separator) else { return }
        tabBar.removeFromSuperview()
        stack.insertArrangedSubview(tabBar, at: index + 1)
        tabBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: - Actions (responder chain, while focus is in the pane)

    /// ⌘W with focus in the pane closes the tab, not the terminal.
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

    func refreshChrome() {
        header.update(document: model.document, recents: recents())
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
        if let onSelectRecent { return onSelectRecent(fileID) }
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
        if let onCloseRequest { return onCloseRequest() }
        let window = view.window
        Task { [weak self] in
            guard let self, await model.close() else { return }
            // Focus goes back to the terminal beside the pane.
            if let controller = window?.windowController as? BaseTerminalController, let surface = controller.focusedSurface {
                Ghostty.moveFocus(to: surface)
            }
        }
    }
}

extension LeoEditorPaneViewController: LeoRowPaneChild {
    var isPaneOpen: Bool { model.isOpen }

    /// Back on screen (B-274): its file may have changed meanwhile.
    func onShown() {
        guard let document = model.document else { return }
        Task { await document.checkDisk() }
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
