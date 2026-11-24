import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// A real window around the window split and its docks (B-439), shared by the
/// dock tests (B-440 moved it out of `LeoPaneDockSplitTests`).
@MainActor final class LeoPaneDockTestHarness {
    static let agent = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "alpha"))
    static let windowSize = NSSize(width: 1_200, height: 600)

    let panes: LeoRowPanes
    let split: LeoSplitViewController
    let terminalView: NSView
    let window: NSWindow
    let agentPaneModel: LeoAgentPaneModel?

    /// The row's panes, for a test that opens some before the window exists.
    static func makePanes(presence: FakePresence) -> LeoRowPanes {
        let panes = LeoRowPanes(makeAccess: { _ in LeoFileAccessor.local() }, confirm: { _, _ in .cancel }, presence: presence)
        panes.activate(Self.agent)
        return panes
    }

    init(presence: FakePresence, store: LeoPaneDockStore, agentPane: Bool = false, panes: LeoRowPanes? = nil) {
        self.panes = panes ?? Self.makePanes(presence: presence)
        let defaults = LeoInMemoryDefaults()
        agentPaneModel = agentPane
            ? LeoAgentPaneModel(
                surfaces: nil, settings: LeoBuiltInPaneSettings(defaults: defaults), store: LeoAgentPaneStateStore(defaults: defaults))
            : nil
        let components = LeoSplitViewControllerFactory.make(
            isSidebarVisible: false, preferredWidth: 240, onDividerWidthChange: { _ in },
            sidebar: AnyView(Color.clear), detail: AnyView(Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)),
            panes: self.panes, paneDock: store, agentPane: agentPaneModel)
        split = components.controller
        terminalView = components.detailHosting.view
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(Self.windowSize)
        agentPaneModel?.setAgent(LeoAgentPaneAgent(
            ref: LeoPluginAgentRef(machine: "localhost", name: "alpha"),
            identity: LeoAgentIdentity(host: .local, name: "alpha", workspace: "/w/alpha")))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    var dock: LeoPaneDockController { split.paneDock! }
    var terminalDock: LeoTerminalDockController { dock.terminalDock }
    var pane: LeoRowPane { panes.active }
    var rightStripItem: NSSplitViewItem { split.splitViewItem(for: dock.rightStrip!)! }
    var rightStripView: NSView { dock.rightStrip!.view }
    var rightStripWidth: CGFloat { LeoSplitViewController.paneWidth(of: rightStripView, in: split.splitView) }
    var rightOutlineItem: NSSplitViewItem? { dock.rightOutline.flatMap(split.splitViewItem(for:)) }
    var rightOutlineWidth: CGFloat { LeoSplitViewController.paneWidth(of: dock.rightOutline!.view, in: split.splitView) }
    var drawerView: NSView? { (split.detailItem?.viewController as? LeoDetailColumnController)?.paneItem.viewController.view }

    func strip(_ container: LeoRowPaneContainerViewController?) -> LeoEditorTabsViewController? {
        container?.activeChild as? LeoEditorTabsViewController
    }

    func frame(of view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    func openFile(in sandbox: LeoFileSandbox) async throws {
        try await pane.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
    }

    /// Lets main-queue subscriptions and deferred positioning run, then lays out.
    func settle() async {
        await drainMainQueue()
        window.contentView?.layoutSubtreeIfNeeded()
        await drainMainQueue()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Moves the terminal's trailing divider, as a drag does, so the
    /// right dock's strip (the outline closed) is `width` wide.
    func dragRightDock(toWidth width: CGFloat) {
        let index = split.splitViewItems.firstIndex(of: split.detailItem!)!
        let trailingDividers = CGFloat(split.splitViewItems.count - 1 - index)
        let splitView = split.splitView
        splitView.setPosition(splitView.bounds.width - width - trailingDividers * splitView.dividerThickness, ofDividerAt: index)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func dragBottomDock(toHeight height: CGFloat) {
        let dockSplit = terminalDock.splitView
        dockSplit.setPosition(dockSplit.bounds.height - height - dockSplit.dividerThickness, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.close()
    }
}
