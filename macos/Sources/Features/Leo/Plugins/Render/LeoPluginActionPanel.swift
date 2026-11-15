import AppKit
import LeoKit

/// The ⌘↩ popover: every action of the selected item. Up/Down move, Return
/// or a click runs the highlighted one, Escape closes (popover default).
final class LeoPluginActionPanelController: NSViewController {
    private let entries: [LeoPluginActionEntry]
    private let onChoose: (Int, LeoPluginGesture.Origin) -> Void
    private let table = PanelTable()

    private static let rowHeight: CGFloat = 26
    private static let width: CGFloat = 240

    init(entries: [LeoPluginActionEntry], onChoose: @escaping (Int, LeoPluginGesture.Origin) -> Void) {
        self.entries = entries
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("action"))
        column.width = Self.width - 16
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onReturn = { [weak self] in self?.chooseSelected(origin: .keyboard) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let height = min(CGFloat(entries.count), 10) * Self.rowHeight + 12
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        view = scroll
        preferredContentSize = scroll.frame.size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        onChoose(table.clickedRow, .click)
    }

    private func chooseSelected(origin: LeoPluginGesture.Origin) {
        guard table.selectedRow >= 0 else { return }
        onChoose(table.selectedRow, origin)
    }

    private final class PanelTable: NSTableView {
        var onReturn: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
        }
    }
}

extension LeoPluginActionPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let icon = NSImageView(image: LeoPluginRenderStyle.symbol(entry.sfSymbol, pointSize: 12) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = LeoPluginRenderStyle.label(entry.title, font: .systemFont(ofSize: 13))
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return stack
    }
}
