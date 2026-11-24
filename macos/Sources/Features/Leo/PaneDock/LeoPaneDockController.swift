import AppKit
import Combine

/// A window's docks (B-439). Each pane has one container -- Files' outline,
/// Files' tab strip, and a strip for the Browser when it docks apart from
/// Files -- and each edge has a slot per column. Applying the store's layout
/// moves each container to its edge's slot, tells the strips what they host
/// now, and opens or closes every slot to match.
///
/// Right: the slots are the window split's trailing items. Below: they're
/// the bottom dock's columns, in the terminal column over the agent drawer.
@MainActor final class LeoPaneDockController {
    let store: LeoPaneDockStore
    /// Files' outline; nil without one (a split built around an editor alone).
    let outline: LeoRowPaneContainerViewController?
    /// Files' tabs (and the Browser item while it shares Files' edge).
    let filesStrip: LeoRowPaneContainerViewController?
    /// The Browser's own strip, used while it docks apart from Files.
    let browserStrip: LeoRowPaneContainerViewController?
    let rightOutline: LeoDockSlotViewController?
    let rightStrip: LeoDockSlotViewController?
    let belowOutline: LeoDockSlotViewController?
    let belowStrip: LeoDockSlotViewController?
    let bottom: LeoBottomDockViewController
    /// The terminal over the bottom dock: the window split's detail.
    let terminalDock: LeoTerminalDockController

    private let windowInset: LeoToolbarInset?
    /// Each container's header inset: the window's on the right, under the
    /// toolbar; none below.
    private var insets: [ObjectIdentifier: LeoToolbarInset] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    init(
        store: LeoPaneDockStore, panes: LeoRowPanes, terminal: NSViewController, hasOutline: Bool, hasStrip: Bool,
        headerTopInset: LeoToolbarInset?
    ) {
        self.store = store
        windowInset = headerTopInset
        let mover = Mover()
        // Before the containers: each makes its row's strip now, which asks what it hosts.
        mover.store = store
        let makeInset = { headerTopInset.map { LeoToolbarInset(height: $0.height) } }
        let outlineInset = makeInset()
        let filesInset = makeInset()
        let browserInset = makeInset()
        outline = hasOutline ? LeoRowPaneContainerViewController(role: .browser, panes: panes) {
            LeoWorkspaceBrowserViewController(model: $0.browser, headerTopInset: outlineInset)
        } : nil
        filesStrip = hasStrip ? LeoRowPaneContainerViewController(role: .editor, panes: panes) { pane in
            LeoEditorTabsViewController(
                tabs: pane.tabs, rowPane: pane, headerTopInset: filesInset,
                dock: mover.context { $0.isShared ? [.browser, .files] : [.files] })
        } : nil
        browserStrip = hasStrip ? LeoRowPaneContainerViewController(role: .agentBrowser, panes: panes) { pane in
            LeoEditorTabsViewController(
                tabs: pane.tabs, rowPane: pane, headerTopInset: browserInset,
                dock: mover.context { $0.isShared ? [] : [.browser] })
        } : nil
        rightOutline = hasOutline ? LeoDockSlotViewController(edge: .right, column: .outline) : nil
        belowOutline = hasOutline ? LeoDockSlotViewController(edge: .below, column: .outline) : nil
        rightStrip = hasStrip ? LeoDockSlotViewController(edge: .right, column: .strip) : nil
        belowStrip = hasStrip ? LeoDockSlotViewController(edge: .below, column: .strip) : nil
        bottom = LeoBottomDockViewController(outline: belowOutline, strip: belowStrip)
        terminalDock = LeoTerminalDockController(terminal: terminal, bottom: bottom, store: store)
        for (container, inset) in [(outline, outlineInset), (filesStrip, filesInset), (browserStrip, browserInset)] {
            if let container, let inset { insets[ObjectIdentifier(container)] = inset }
        }
        mover.dock = self
        terminalDock.dropOverlay.onDrop = { [weak self] in self?.move($0, to: $1) }
        place(store.layout)
        // Before any view loads: the slots below start as their panes are.
        for case let (item?, slot?) in [(bottom.outlineItem, belowOutline), (bottom.stripItem, belowStrip)] {
            item.isCollapsed = !slot.isPaneOpen
        }
        terminalDock.setBottomOpen(bottom.isOpen)
        updateInsets()
        observe()
    }

    var containers: [LeoRowPaneContainerViewController] { [outline, filesStrip, browserStrip].compactMap { $0 } }

    /// The window split's trailing slots, in order.
    var rightSlots: [LeoDockSlotViewController] { [rightOutline, rightStrip].compactMap { $0 } }
    private var belowSlots: [LeoDockSlotViewController] { [belowOutline, belowStrip].compactMap { $0 } }

    /// Moves `pane` to `edge` in every window (the one way a pane moves),
    /// then gives it focus here. Its own edge changes nothing.
    func move(_ pane: LeoDockPane, to edge: LeoDockEdge) {
        guard store.layout.edge(of: pane) != edge else { return }
        store.setEdge(edge, for: pane)
        focus(pane)
    }

    /// A tab of `pane` is being dragged (B-440): the terminal shows the one
    /// zone it can land in, until `endDrag`.
    func beginDrag(_ pane: LeoDockPane) {
        terminalDock.dropOverlay.begin(pane: pane, edge: LeoDockDropZone.target(for: pane, layout: store.layout))
    }

    /// The drag ended, dropped or not.
    func endDrag() {
        terminalDock.dropOverlay.end()
    }

    /// Focus goes to `pane`: Files' open file, else its outline; the
    /// Browser's page.
    func focus(_ pane: LeoDockPane) {
        terminalDock.view.window?.contentView?.layoutSubtreeIfNeeded()
        switch pane {
        case .files:
            if let tabs = filesStrip?.activeChild as? LeoEditorTabsViewController, tabs.tabs.isOpen {
                tabs.focusText()
            } else if let list = outline?.activeChild as? LeoWorkspaceBrowserViewController, list.model.isOpen {
                list.focusList()
            }
        case .browser:
            let strip = store.layout.isShared ? filesStrip : browserStrip
            (strip?.activeChild as? LeoEditorTabsViewController)?.focusBrowser()
        }
    }

    // MARK: - Applying the layout

    private func observe() {
        store.changes
            .sink { [weak self] in self?.apply($0) }
            .store(in: &subscriptions)
        windowInset?.$height
            // `@Published` sends before it stores: the value is the new height.
            .sink { [weak self] in self?.updateInsets(windowHeight: $0) }
            .store(in: &subscriptions)
    }

    private func apply(_ layout: LeoPaneDockLayout) {
        place(layout)
        containers.forEach { $0.dockDidChange() }
        updateInsets()
        reconcile()
    }

    /// Every container goes to its edge's slot; the Browser's own strip
    /// leaves the docks while it shares Files' edge.
    private func place(_ layout: LeoPaneDockLayout) {
        let files = layout.edge(of: .files)
        let wanted: [(LeoDockSlotViewController?, LeoRowPaneContainerViewController?)] = [
            (outlineSlot(on: files), outline), (outlineSlot(on: files.opposite), nil),
            (stripSlot(on: files), filesStrip), (stripSlot(on: files.opposite), layout.isShared ? nil : browserStrip),
        ]
        // First every slot lets go of a container that moves, then each takes its own.
        for case let (slot?, container) in wanted where slot.hosted !== container { slot.host(nil) }
        for case let (slot?, container) in wanted { slot.host(container) }
    }

    /// Each slot opens while what it hosts has something to show. A strip
    /// opening on the right opens at the dock's remembered width.
    private func reconcile() {
        for slot in rightSlots { slot.setLeoSplitItemCollapsed(!slot.isPaneOpen, openingAtHalfWidth: slot.column == .strip) }
        for slot in belowSlots { slot.setLeoSplitItemCollapsed(!slot.isPaneOpen) }
    }

    private func outlineSlot(on edge: LeoDockEdge) -> LeoDockSlotViewController? { edge == .right ? rightOutline : belowOutline }
    private func stripSlot(on edge: LeoDockEdge) -> LeoDockSlotViewController? { edge == .right ? rightStrip : belowStrip }

    private func edge(of container: LeoRowPaneContainerViewController) -> LeoDockEdge {
        store.layout.edge(of: container === browserStrip ? .browser : .files)
    }

    private func updateInsets(windowHeight: CGFloat? = nil) {
        guard let windowInset else { return }
        let height = windowHeight ?? windowInset.height
        for container in containers {
            insets[ObjectIdentifier(container)]?.setHeight(edge(of: container) == .right ? height : 0)
        }
    }
}

extension LeoDockEdge {
    var opposite: LeoDockEdge { self == .right ? .below : .right }
}

/// Lets the strips' children reach the dock controller that owns them,
/// which doesn't exist yet when their containers are made.
@MainActor private final class Mover {
    weak var dock: LeoPaneDockController?
    weak var store: LeoPaneDockStore?

    /// A strip's dock context: it shows `hosts(layout)`, and its tabs' menus
    /// move panes through the dock controller.
    func context(hosts: @escaping (LeoPaneDockLayout) -> Set<LeoDockPane>) -> LeoPaneDockStripContext {
        LeoPaneDockStripContext(
            hosts: { [weak self] in self?.store.map { hosts($0.layout) } ?? [] },
            edge: { [weak self] in self?.store?.layout.edge(of: $0) ?? .right },
            move: { [weak self] in self?.dock?.move($0, to: $1) },
            beginDrag: { [weak self] in self?.dock?.beginDrag($0) },
            endDrag: { [weak self] in self?.dock?.endDrag() })
    }
}
