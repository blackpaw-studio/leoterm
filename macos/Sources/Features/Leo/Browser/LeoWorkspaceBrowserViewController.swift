import AppKit
import Combine

/// The window's workspace browser (B-005): a split item on the leading
/// edge of the editor pane, showing `LeoWorkspaceBrowserModel` as an
/// outline. It collapses its own split item while the browser is closed,
/// reloads whenever its window becomes key (never on a timer), and closes
/// on ⌘W while it has focus.
final class LeoWorkspaceBrowserViewController: NSViewController {
    static let minimumWidth: CGFloat = 180

    let model: LeoWorkspaceBrowserModel
    let outlineView = LeoWorkspaceOutlineView()
    /// Escape: back to the terminal beside the browser.
    var onEscape: () -> Void = {}
    private let titleLabel = NSTextField(labelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let footerBox = NSStackView()
    /// The outline's items for what it shows now; during a sync, the ones
    /// shown before, reused so expansion and selection stick.
    private var items: [LeoWorkspaceItem: LeoWorkspaceOutlineItem] = [:]
    private var reusable: [LeoWorkspaceItem: LeoWorkspaceOutlineItem] = [:]
    private var childCache: [String: [LeoWorkspaceOutlineItem]] = [:]
    /// While the outline is being made to match the model, its expand and
    /// collapse callbacks aren't the user's.
    private var isSyncing = false
    private var subscriptions: Set<AnyCancellable> = []
    private var keyWindowObserver: NSObjectProtocol?

    /// Binds to the model right away, as the editor pane does: a collapsed
    /// split item's view isn't loaded until it is shown.
    init(model: LeoWorkspaceBrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        onEscape = { [weak self] in self?.focusTerminal() }
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sync() }
            .store(in: &subscriptions)
        observeKeyWindow()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    }

    override func loadView() {
        configureOutline()
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [makeHeader(), separator, scrollView, makeFooter()])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        stack.setAccessibilityLabel("Workspace files")
        view = stack
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth).isActive = true
        sync()
    }

    // MARK: - Focus and actions

    var hasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    /// Selects the first row when nothing is, so the arrows work at once.
    /// A pane just shown may join its window only on the next layout, so
    /// a focus request that can't land yet is retried once, next turn.
    func focusList() {
        if outlineView.selectedRow < 0, let first = (0..<outlineView.numberOfRows).first(where: isSelectable) {
            outlineView.selectRowIndexes([first], byExtendingSelection: false)
        }
        if let window = view.window, window.makeFirstResponder(outlineView) { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = view.window else { return }
            window.makeFirstResponder(outlineView)
        }
    }

    /// ⌘W with focus in the browser closes it, not the terminal.
    @objc func close(_ sender: Any?) {
        closeBrowser()
    }

    // MARK: - Showing the model

    /// Makes the outline match the model: rows rebuilt, expanded folders
    /// expanded, the selected path kept selected.
    func sync() {
        setCollapsed(!model.isOpen)
        titleLabel.stringValue = headerTitle
        footer.stringValue = model.openError ?? ""
        footerBox.isHidden = model.openError == nil
        guard isViewLoaded else { return }
        let selectedPath = entry(atRow: outlineView.selectedRow)?.path
        isSyncing = true
        defer { isSyncing = false }
        childCache = [:]
        reusable = items
        items = [:]
        outlineView.reloadData()
        expandShown(in: nil)
        reusable = [:]
        restoreSelection(selectedPath)
    }

    /// The workspace folder's name.
    var headerTitle: String {
        guard let root = model.root else { return "" }
        let name = root.path.map { ($0 as NSString).lastPathComponent } ?? root.agent
        return LeoSFTPServerText.sanitized(name.isEmpty ? "/" : name)
    }

    var footerMessage: String? { footerBox.isHidden ? nil : footer.stringValue }

    /// What row `row` shows (for tests and accessibility).
    func title(ofRow row: Int) -> String? {
        guard row >= 0, let item = outlineView.item(atRow: row) as? LeoWorkspaceOutlineItem else { return nil }
        return item.title
    }

    // MARK: - Helpers

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.onActivate = { [weak self] in self?.activateSelection() }
        outlineView.onEscape = { [weak self] in self?.onEscape() }
        outlineView.setAccessibilityLabel("Workspace files")
    }

    private func makeHeader() -> NSView {
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reload = Self.button(symbol: "arrow.clockwise", label: "Reload Files", action: #selector(reloadClicked(_:)), target: self)
        let close = Self.button(symbol: "xmark", label: "Close Files", action: #selector(close(_:)), target: self)
        let header = NSStackView(views: [titleLabel, NSView(), reload, close])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        return header
    }

    private func makeFooter() -> NSView {
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error") ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let dismiss = Self.button(symbol: "xmark.circle", label: "Dismiss", action: #selector(dismissClicked(_:)), target: self)
        footerBox.setViews([icon, footer, dismiss], in: .leading)
        footerBox.orientation = .horizontal
        footerBox.alignment = .top
        footerBox.spacing = 6
        footerBox.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 8)
        footerBox.isHidden = true
        return footerBox
    }

    private static func button(symbol: String, label: String, action: Selector, target: AnyObject) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func outlineItem(_ item: LeoWorkspaceItem) -> LeoWorkspaceOutlineItem {
        if let existing = items[item] { return existing }
        let created = reusable[item] ?? LeoWorkspaceOutlineItem(item)
        items[item] = created
        return created
    }

    private func childItems(of item: LeoWorkspaceOutlineItem?) -> [LeoWorkspaceOutlineItem] {
        let folder = item?.folderPath ?? ""
        if let cached = childCache[folder] { return cached }
        let made = (item?.folderPath.map(model.items(in:)) ?? model.rootItems).map(outlineItem)
        childCache[folder] = made
        return made
    }

    private func expandShown(in parent: LeoWorkspaceOutlineItem?) {
        for child in childItems(of: parent) {
            guard let folder = child.folderPath else { continue }
            if model.isExpanded(folder) {
                outlineView.expandItem(child)
                expandShown(in: child)
            } else if outlineView.isItemExpanded(child) {
                outlineView.collapseItem(child)
            }
        }
    }

    private func restoreSelection(_ path: String?) {
        let row = path.flatMap { path in
            items.first { key, _ in if case let .entry(entry) = key { entry.path == path } else { false } }
        }.map { outlineView.row(forItem: $0.value) } ?? -1
        if row >= 0 {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    private func entry(atRow row: Int) -> LeoWorkspaceEntry? {
        guard row >= 0, let item = outlineView.item(atRow: row) as? LeoWorkspaceOutlineItem,
              case let .entry(entry) = item.item else { return nil }
        return entry
    }

    private func isSelectable(_ row: Int) -> Bool { entry(atRow: row) != nil }

    private func activateSelection() {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? LeoWorkspaceOutlineItem,
              case let .entry(entry) = item.item else { return }
        guard entry.isFolder else {
            Task { await model.openFile(entry.path) }
            return
        }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        activateSelection()
    }

    @objc private func reloadClicked(_ sender: Any?) {
        Task { await model.reload() }
    }

    @objc private func dismissClicked(_ sender: Any?) {
        model.dismissOpenError()
    }

    private func closeBrowser() {
        let hadFocus = hasFocus
        Task { [weak self] in
            await self?.model.close()
            if hadFocus { self?.focusTerminal() }
        }
    }

    private func focusTerminal() {
        guard let controller = view.window?.windowController as? BaseTerminalController, let surface = controller.focusedSurface else { return }
        Ghostty.moveFocus(to: surface)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard let item = (parent as? NSSplitViewController)?.splitViewItem(for: self), item.isCollapsed != collapsed else { return }
        item.isCollapsed = collapsed
    }

    /// No timers: the workspace is listed again when the window becomes
    /// key, and on Reload.
    private func observeKeyWindow() {
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isViewLoaded, let window = self.view.window, notification.object as? NSWindow === window,
                      self.model.isOpen else { return }
                Task { await self.model.reload() }
            }
        }
    }
}

// MARK: - NSOutlineViewDataSource, NSOutlineViewDelegate

extension LeoWorkspaceBrowserViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        childItems(of: item as? LeoWorkspaceOutlineItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        childItems(of: item as? LeoWorkspaceOutlineItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? LeoWorkspaceOutlineItem)?.folderPath != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? LeoWorkspaceOutlineItem, case .entry = item.item else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? LeoWorkspaceOutlineItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("LeoWorkspaceCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? LeoWorkspaceCellView ?? LeoWorkspaceCellView(identifier: identifier)
        cell.show(item)
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isSyncing, let folder = (notification.userInfo?["NSObject"] as? LeoWorkspaceOutlineItem)?.folderPath else { return }
        Task { await model.expand(folder) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isSyncing, let folder = (notification.userInfo?["NSObject"] as? LeoWorkspaceOutlineItem)?.folderPath else { return }
        model.collapse(folder)
    }
}

/// `NSOutlineView` needs items with identity; one per row the model shows,
/// kept across syncs so expansion and selection stick.
final class LeoWorkspaceOutlineItem: NSObject {
    let item: LeoWorkspaceItem

    init(_ item: LeoWorkspaceItem) {
        self.item = item
    }

    var folderPath: String? {
        guard case let .entry(entry) = item, entry.isFolder else { return nil }
        return entry.path
    }

    var title: String {
        switch item {
        case let .entry(entry): entry.displayName
        case .loading: "Loading…"
        case let .message(_, text): text
        }
    }
}

/// A row: icon and name, or a quiet placeholder or message.
private final class LeoWorkspaceCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [image, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = image
        textField = text
    }

    required init?(coder: NSCoder) { nil }

    func show(_ item: LeoWorkspaceOutlineItem) {
        textField?.stringValue = item.title
        let symbol: String?
        switch item.item {
        case let .entry(entry): symbol = entry.isFolder ? "folder" : "doc"
        case .loading: symbol = nil
        case .message: symbol = "exclamationmark.triangle"
        }
        imageView?.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        imageView?.contentTintColor = item.folderPath != nil ? .controlAccentColor : .secondaryLabelColor
        if case .entry = item.item {
            textField?.textColor = .labelColor
            textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
        } else {
            textField?.textColor = .secondaryLabelColor
            textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        setAccessibilityLabel(item.title)
    }
}
