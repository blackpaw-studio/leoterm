import AppKit
import Combine
import LeoKit

/// Shows each workspace pick in its own `LeoBrowserUploadPanel`.
@MainActor struct LeoBrowserUploadPanelPresenter: LeoBrowserUploadPanelPresenting {
    func show(_ pick: LeoBrowserWorkspacePick) -> any LeoBrowserUploadPanelHandle {
        let panel = LeoBrowserUploadPanel(pick: pick)
        panel.present()
        return panel
    }
}

/// The chooser for a page's `<input type=file>`: the agent's workspace as an
/// outline rooted at the workspace (no way above it), with "Choose from
/// Mac…" for anything else. A standalone panel, never a sheet: the browser
/// pane shares its window with terminals, and an agent-driven click must
/// never freeze that window. Return chooses, Escape cancels, a double-click
/// on a file chooses it, ⌘⇧. shows hidden files.
@MainActor final class LeoBrowserUploadPanel: NSPanel, NSWindowDelegate, LeoBrowserUploadPanelHandle {
    private static let size = NSSize(width: 520, height: 420)
    private static let minimumSize = NSSize(width: 400, height: 300)
    private static let periodKeyCode: UInt16 = 47

    let pick: LeoBrowserWorkspacePick
    let outlineView = LeoWorkspaceOutlineView()
    let chooseButton = NSButton(title: "Choose", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let fromMacButton = NSButton(title: "Choose from Mac…", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var items: [LeoWorkspaceItem: LeoWorkspaceOutlineItem] = [:]
    private var reusable: [LeoWorkspaceItem: LeoWorkspaceOutlineItem] = [:]
    private var childCache: [String: [LeoWorkspaceOutlineItem]] = [:]
    private var isSyncing = false
    private var isClosing = false
    private var subscriptions: Set<AnyCancellable> = []

    init(pick: LeoBrowserWorkspacePick) {
        self.pick = pick
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        title = "Choose from Workspace"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        minSize = Self.minimumSize
        delegate = self
        contentView = makeContent()
        Publishers.Merge(pick.objectWillChange, pick.model.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sync() }
            .store(in: &subscriptions)
        sync()
    }

    func present() {
        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(outlineView)
    }

    // MARK: - LeoBrowserUploadPanelHandle

    func dismiss() {
        isClosing = true
        subscriptions = []
        close()
    }

    /// The close button cancels; a finished pick closes through `dismiss()`.
    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        pick.cancel()
    }

    // MARK: - Keys

    /// ⌘⇧. as Finder's open panel has it, by key position, so the layout's
    /// shifted period doesn't matter.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == [.command, .shift], event.keyCode == Self.periodKeyCode {
            Task { await pick.model.toggleHiddenFiles() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        pick.cancel()
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let header = NSTextField(wrappingLabelWithString: pick.request.message)
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let path = NSTextField(labelWithString: pick.workspaceLabel)
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.toolTip = pick.workspace
        let folder = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        folder.contentTintColor = .secondaryLabelColor
        folder.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        let pathRow = NSStackView(views: [folder, path])
        pathRow.spacing = 4

        let headerStack = NSStackView(views: [header, pathRow])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true
        errorLabel.setAccessibilityRole(.staticText)

        let content = NSStackView(views: [headerStack, makeOutline(), errorLabel, makeButtons()])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        content.setHuggingPriority(.defaultLow, for: .vertical)
        return content
    }

    private func makeOutline() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .inset
        outlineView.rowSizeStyle = .default
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.allowsMultipleSelection = pick.request.allowsMultipleSelection
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.onActivate = { [weak self] in self?.activateSelection() }
        outlineView.onEscape = { [weak self] in self?.pick.cancel() }
        outlineView.setAccessibilityLabel("Workspace files")

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        return scrollView
    }

    private func makeButtons() -> NSView {
        fromMacButton.target = self
        fromMacButton.action = #selector(fromMacClicked(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        chooseButton.target = self
        chooseButton.action = #selector(chooseClicked(_:))
        chooseButton.keyEquivalent = "\r"
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [fromMacButton, progress, statusLabel, spacer, cancelButton, chooseButton])
        row.spacing = 8
        row.setCustomSpacing(12, after: fromMacButton)
        return row
    }

    // MARK: - Showing the pick

    /// Rows rebuilt from the model, expanded folders expanded, the
    /// selection kept; buttons and status from the pick.
    private func sync() {
        guard !isClosing else { return }
        let isCopying = pick.copyingName != nil
        chooseButton.isEnabled = pick.canChoose
        cancelButton.isEnabled = true
        fromMacButton.isEnabled = !isCopying
        outlineView.isEnabled = !isCopying
        statusLabel.stringValue = pick.copyingName.map { "Copying “\($0)”…" } ?? ""
        statusLabel.isHidden = !isCopying
        if isCopying { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        errorLabel.stringValue = pick.error ?? ""
        errorLabel.isHidden = pick.error == nil

        let selected = Set(outlineView.selectedRowIndexes.compactMap { entry(atRow: $0)?.path })
        isSyncing = true
        defer { isSyncing = false }
        childCache = [:]
        reusable = items
        items = [:]
        outlineView.reloadData()
        expandShown(in: nil)
        reusable = [:]
        let rows = IndexSet((0..<outlineView.numberOfRows).filter { entry(atRow: $0).map { selected.contains($0.path) } ?? false })
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
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
        let made = (item?.folderPath.map(pick.model.items(in:)) ?? pick.model.rootItems).map(outlineItem)
        childCache[folder] = made
        return made
    }

    private func expandShown(in parent: LeoWorkspaceOutlineItem?) {
        for child in childItems(of: parent) {
            guard let folder = child.folderPath, pick.model.isExpanded(folder) else { continue }
            outlineView.expandItem(child)
            expandShown(in: child)
        }
    }

    private func entry(atRow row: Int) -> LeoWorkspaceEntry? {
        guard row >= 0, let item = outlineView.item(atRow: row) as? LeoWorkspaceOutlineItem,
              case let .entry(entry) = item.item else { return nil }
        return entry
    }

    // MARK: - Actions

    /// Return or a double-click: a file is chosen, a folder opens or closes.
    private func activateSelection() {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? LeoWorkspaceOutlineItem,
              case let .entry(entry) = item.item else { return }
        guard entry.isFolder else { return pick.choose() }
        if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        if !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        activateSelection()
    }

    @objc private func chooseClicked(_ sender: Any?) { pick.choose() }
    @objc private func cancelClicked(_ sender: Any?) { pick.cancel() }
    @objc private func fromMacClicked(_ sender: Any?) { pick.chooseFromMac() }
}

// MARK: - NSOutlineViewDataSource, NSOutlineViewDelegate

extension LeoBrowserUploadPanel: NSOutlineViewDataSource, NSOutlineViewDelegate {
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
        cell.show(item, isUploading: false)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing else { return }
        pick.select(outlineView.selectedRowIndexes.compactMap { entry(atRow: $0) })
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isSyncing, let folder = (notification.userInfo?["NSObject"] as? LeoWorkspaceOutlineItem)?.folderPath else { return }
        Task { await pick.model.expand(folder) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isSyncing, let folder = (notification.userInfo?["NSObject"] as? LeoWorkspaceOutlineItem)?.folderPath else { return }
        pick.model.collapse(folder)
    }
}
