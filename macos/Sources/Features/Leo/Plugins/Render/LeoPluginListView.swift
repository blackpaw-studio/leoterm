import AppKit
import LeoKit

/// A List node: sectioned rows with accessories. A thin AppKit shell over
/// `LeoPluginListModel`, which owns selection, keys and action rules.
final class LeoPluginListView: NSView {
    private final class Table: NSTableView {
        weak var owner: LeoPluginListView?

        override func keyDown(with event: NSEvent) {
            if owner?.handleKeyDown(event) != true { super.keyDown(with: event) }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            owner?.menu(at: convert(event.locationInWindow, from: nil))
        }
    }

    private let model: LeoPluginListModel
    private let table = Table()
    private let scroll = NSScrollView()
    private let embedded: Bool
    private var panel: NSPopover?
    private var shownPanelEntries: [LeoPluginActionEntry] = []
    private var isApplyingSelection = false

    init(list: LeoPluginNode.List, emitter: LeoPluginActionEmitter, embedded: Bool) {
        self.embedded = embedded
        self.model = LeoPluginListModel(list: list, mint: emitter.mint, handler: emitter.handler)
        super.init(frame: .zero)
        configureTable()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = !embedded
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = embedded ? .none : .automatic
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        table.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var list: LeoPluginNode.List { model.list }

    override var intrinsicContentSize: NSSize {
        guard embedded else { return super.intrinsicContentSize }
        // The table's own geometry (row spacing and style insets included), not a sum of row heights.
        let height = model.rows.isEmpty ? 0 : table.rect(ofRow: model.rows.count - 1).maxY
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // MARK: Updates

    /// Applies a keyed patch in place: only changed rows are touched, the
    /// selection stays on the same item id, and the first visible row stays
    /// where it was, so a refresh never jumps the list.
    func apply(patch: LeoPluginListPatch) {
        apply(list: LeoPluginTreeDiff.apply(patch, to: model.list))
    }

    func apply(list newList: LeoPluginNode.List) {
        let anchor = scrollAnchor()
        let change = model.apply(list: newList)
        guard !change.isEmpty else { return }
        table.beginUpdates()
        if !change.removed.isEmpty { table.removeRows(at: change.removed, withAnimation: []) }
        if !change.inserted.isEmpty { table.insertRows(at: change.inserted, withAnimation: []) }
        if !change.updated.isEmpty {
            table.reloadData(forRowIndexes: change.updated, columnIndexes: IndexSet(integer: 0))
            table.noteHeightOfRows(withIndexesChanged: change.updated)
        }
        table.endUpdates()
        restoreSelection()
        restoreScroll(anchor)
        if embedded { invalidateIntrinsicContentSize() }
        // A popover showing stale actions would misroute a click; close it.
        if panel != nil, model.actionPanel?.entries != shownPanelEntries { panel?.close() }
    }

    // MARK: Scroll anchoring

    private struct ScrollAnchor { let key: String; let offset: CGFloat }

    private func scrollAnchor() -> ScrollAnchor? {
        guard !embedded else { return nil }
        let visible = scroll.contentView.bounds
        let row = table.row(at: NSPoint(x: 1, y: visible.minY + 1))
        guard model.rows.indices.contains(row) else { return nil }
        return ScrollAnchor(key: model.rows[row].key, offset: table.rect(ofRow: row).minY - visible.minY)
    }

    private func restoreScroll(_ anchor: ScrollAnchor?) {
        guard let anchor, let index = model.rowIndex(forKey: anchor.key) else { return }
        let target = table.rect(ofRow: index).minY - anchor.offset
        let clip = scroll.contentView
        let maxY = max(0, table.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, target), maxY)))
        scroll.reflectScrolledClipView(clip)
    }

    private func restoreSelection() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        guard let id = model.selectedItemID, let row = model.rowIndex(forKey: "i:\(id)") else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: Keys and menus

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else { return false }
        let key: LeoPluginListKey = event.modifierFlags.contains(.command) ? .commandReturn : .return
        guard model.handleKey(key) else { return false }
        if key == .commandReturn { showActionPanel() }
        return true
    }

    private func menu(at point: NSPoint) -> NSMenu? {
        let row = table.row(at: point)
        guard model.rows.indices.contains(row), let id = model.rows[row].itemID else { return nil }
        model.select(itemID: id)
        restoreSelection()
        let entries = model.contextMenu(forItem: id)
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(contextMenuChosen(_:)), keyEquivalent: "")
            item.target = self
            item.image = LeoPluginRenderStyle.symbol(entry.sfSymbol, pointSize: 12)
            item.representedObject = ContextMenuTarget(itemID: id, index: entry.index)
            menu.addItem(item)
        }
        return menu
    }

    private final class ContextMenuTarget: NSObject {
        let itemID: String
        let index: Int
        init(itemID: String, index: Int) { self.itemID = itemID; self.index = index }
    }

    @objc private func contextMenuChosen(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ContextMenuTarget else { return }
        model.performContextMenuEntry(item: target.itemID, at: target.index)
    }

    private func showActionPanel() {
        guard let state = model.actionPanel, let id = model.selectedItemID,
              let row = model.rowIndex(forKey: "i:\(id)") else { return }
        panel?.close()
        shownPanelEntries = state.entries
        let controller = LeoPluginActionPanelController(entries: state.entries) { [weak self] index, origin in
            self?.panel?.close()
            self?.model.performPanelEntry(at: index, origin: origin)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        panel = popover
        popover.show(relativeTo: table.rect(ofRow: row), of: table, preferredEdge: .maxX)
    }

    // MARK: Table

    private func configureTable() {
        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.owner = self
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel("Plugin list")
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, let id = model.rows[table.clickedRow].itemID else { return }
        model.performPrimary(item: id, origin: .click)
    }

    private func rowHeight(for row: Int) -> CGFloat {
        switch model.rows[row] {
        case .header: LeoPluginRenderStyle.headerRowHeight
        case .item(let item): item.subtitle?.isEmpty == false ? LeoPluginRenderStyle.itemRowHeight : LeoPluginRenderStyle.compactRowHeight
        }
    }
}

extension LeoPluginListView: NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(for: row) }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = model.rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        model.rows[row].itemID != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch model.rows[row] {
        case .header(_, let title):
            let label = LeoPluginRenderStyle.label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
            return label
        case .item(let item):
            return LeoPluginListRowView(item: item)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = table.selectedRow
        model.select(itemID: model.rows.indices.contains(row) ? model.rows[row].itemID : nil)
    }

    func popoverDidClose(_ notification: Notification) {
        model.closeActionPanel()
        panel = nil
        window?.makeFirstResponder(table)
    }
}

/// One item row: symbol, title over subtitle, accessories trailing.
final class LeoPluginListRowView: NSView {
    init(item: LeoPluginNode.Item) {
        super.init(frame: .zero)
        var leading: [NSView] = []
        if let image = LeoPluginRenderStyle.symbol(item.sfSymbol, pointSize: 15) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            leading.append(icon)
        }
        let title = LeoPluginRenderStyle.label(item.title, font: .systemFont(ofSize: 13))
        let text = NSStackView(views: [title])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            text.addArrangedSubview(LeoPluginRenderStyle.label(subtitle, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leading.append(text)
        let accessories = item.accessories.map { LeoPluginAccessoryView(accessory: $0) as NSView }
        let row = NSStackView(views: leading + accessories)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
