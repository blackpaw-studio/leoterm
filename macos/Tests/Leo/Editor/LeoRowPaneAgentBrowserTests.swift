import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// E1: an agent's browser is a content case of its row's pane, beside the
/// editor tabs. It opens the pane when the agent starts it, without taking
/// focus, and closing it closes the browser.
@MainActor
struct LeoRowPaneAgentBrowserTests {
    private static let agentA = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "alpha"))
    private static let agentB = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "beta"))
    private static let keyA = LeoAgentBrowserKey(host: .local, agent: "alpha")

    private let presence = FakePresence()

    private func makePanes() -> LeoRowPanes {
        LeoRowPanes(makeAccess: { _ in LeoFileAccessor.local() }, confirm: { _, _ in .cancel }, presence: presence)
    }

    // MARK: - Model

    @Test
    func aBrowserTheAgentOpensIsTheRowsContent() {
        let panes = makePanes()
        let pane = panes.pane(for: Self.agentA)
        #expect(pane.content == .editor)
        #expect(pane.agentBrowser == nil)

        let source = presence.open(Self.keyA)

        #expect(pane.agentBrowser === source)
        #expect(pane.content == .agentBrowser)
        #expect(pane.isAgentBrowserOpen)
    }

    @Test
    func rowsWithoutABrowserAreUnchanged() {
        let panes = makePanes()
        let other = panes.pane(for: Self.agentB)
        presence.open(Self.keyA)

        #expect(other.agentBrowser == nil)
        #expect(other.content == .editor)
        #expect(!other.isAgentBrowserOpen)
        #expect(panes.pane(for: .terminal(UUID())).agentBrowser == nil)
    }

    @Test
    func aPaneMadeAfterTheBrowserFindsIt() {
        let source = presence.open(Self.keyA)

        #expect(makePanes().pane(for: Self.agentA).agentBrowser === source)
    }

    @Test
    func dispatchRowsGetTheirDispatchsBrowser() {
        let panes = makePanes()
        let dispatch = panes.pane(for: .agent(host: .local, name: "alpha", dispatchID: "d1"))
        let parent = panes.pane(for: Self.agentA)

        let source = presence.open(.dispatch(host: .local, id: "d1"))

        #expect(dispatch.agentBrowser === source)
        #expect(parent.agentBrowser == nil)
    }

    @Test
    func aBrowserOpensBehindOpenFiles() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let panes = makePanes()
            let pane = panes.pane(for: Self.agentA)
            try await pane.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))

            presence.open(Self.keyA)

            #expect(pane.content == .editor, "what the user is editing stays")
            #expect(pane.isAgentBrowserOpen)
            pane.showAgentBrowser()
            #expect(pane.content == .agentBrowser)
            pane.showEditor()
            #expect(pane.content == .editor)
            await panes.releaseAll()
        }
    }

    @Test
    func theBrowserTakesOverWhenTheLastFileCloses() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let panes = makePanes()
            let pane = panes.pane(for: Self.agentA)
            try await pane.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            presence.open(Self.keyA)

            _ = await pane.tabs.closeAll()

            #expect(pane.content == .agentBrowser)
            await panes.releaseAll()
        }
    }

    @Test
    func aFileAddedBehindTheBrowserLeavesItOnScreen() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let panes = makePanes()
            let pane = panes.pane(for: Self.agentA)
            presence.open(Self.keyA)

            try await pane.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")), mode: .background)

            #expect(pane.content == .agentBrowser)
            await panes.releaseAll()
        }
    }

    @Test
    func closingTheBrowserClosesIt() {
        let panes = makePanes()
        let pane = panes.pane(for: Self.agentA)
        presence.open(Self.keyA)

        pane.closeAgentBrowser()

        #expect(presence.closeRequests == [Self.keyA])
        #expect(pane.agentBrowser == nil)
        #expect(pane.content == .editor)
    }

    @Test
    func aStoppedAgentsBrowserLeavesThePane() {
        let panes = makePanes()
        let pane = panes.pane(for: Self.agentA)
        presence.open(Self.keyA)

        presence.remove(Self.keyA)

        #expect(pane.agentBrowser == nil)
        #expect(presence.closeRequests.isEmpty)
    }

    // MARK: - On screen

    private final class TerminalStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct StandIn: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @MainActor private final class Harness {
        let panes: LeoRowPanes
        let terminal = TerminalStandIn()
        let split: LeoSplitViewController
        let window: NSWindow

        init(_ panes: LeoRowPanes) {
            self.panes = panes
            split = LeoSplitViewControllerFactory.make(
                isSidebarVisible: false, preferredWidth: 240, onDividerWidthChange: { _ in },
                sidebar: AnyView(Color.clear), detail: AnyView(StandIn(view: terminal).frame(maxWidth: .infinity, maxHeight: .infinity)),
                panes: panes
            ).controller
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = split
            window.setContentSize(NSSize(width: 1_400, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        var editorItem: NSSplitViewItem? { split.splitViewItems.first { $0.leoPaneRole == .editor } }
        var tabsView: LeoEditorTabsViewController? {
            (editorItem?.viewController as? LeoRowPaneContainerViewController)?.activeChild as? LeoEditorTabsViewController
        }
    }

    @Test
    func theAgentOpeningABrowserShowsThePaneWithoutTakingFocus() async {
        let panes = makePanes()
        panes.activate(Self.agentA)
        let harness = Harness(panes)
        #expect(harness.window.makeFirstResponder(harness.terminal))
        #expect(harness.editorItem?.isCollapsed == true)

        let source = presence.open(Self.keyA)
        source.activeRemoteURL = URL(string: "http://localhost:5173")
        await drainMainQueue()
        harness.window.contentView?.layoutSubtreeIfNeeded()

        #expect(harness.editorItem?.isCollapsed == false)
        #expect(harness.tabsView?.shownBrowser != nil)
        #expect(harness.window.firstResponder === harness.terminal)
    }

    @Test
    func closingTheBrowserItemClosesTheBrowserAndCollapsesThePane() async {
        let panes = makePanes()
        panes.activate(Self.agentA)
        let harness = Harness(panes)
        presence.open(Self.keyA)
        await drainMainQueue()
        #expect(harness.tabsView?.tabBar.items.first?.isBrowser == true)

        harness.tabsView?.tabBar.onClose(0)
        await drainMainQueue()

        #expect(presence.closeRequests == [Self.keyA])
        #expect(harness.tabsView?.shownBrowser == nil)
        #expect(harness.editorItem?.isCollapsed == true)
    }

    @Test
    func rowsWithoutABrowserKeepTheirPaneClosed() async {
        let panes = makePanes()
        panes.activate(Self.agentB)
        let harness = Harness(panes)

        presence.open(Self.keyA)
        await drainMainQueue()

        #expect(harness.editorItem?.isCollapsed == true)
        #expect(harness.tabsView?.shownBrowser == nil)
        #expect(harness.tabsView?.tabBar.items.isEmpty == true)
    }
}
