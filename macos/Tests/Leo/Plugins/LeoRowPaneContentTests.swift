import AppKit
import Combine
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// A fake of what the pane asks of the plugin system.
@MainActor final class FakePluginPaneHost: LeoPluginPaneHosting {
    private(set) var opened: [LeoPluginViewRef] = []
    private(set) var retried: [LeoPluginSlotKey] = []
    private(set) var popped: [LeoPluginSlotKey] = []
    private(set) var performed: [(LeoPluginAction, LeoPluginSlotKey)] = []
    private(set) var visibility: [LeoPluginSlotKey: Bool] = [:]
    var content: LeoPluginSlotContent = .loading
    private let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    func content(for key: LeoPluginSlotKey) -> LeoPluginSlotContent { content }
    func open(_ ref: LeoPluginViewRef) { opened.append(ref) }
    func retry(_ key: LeoPluginSlotKey) { retried.append(key) }
    func pop(_ key: LeoPluginSlotKey) { popped.append(key) }
    func perform(_ action: LeoPluginAction, gesture: LeoPluginGesture?, in key: LeoPluginSlotKey) { performed.append((action, key)) }
    func setVisible(_ key: LeoPluginSlotKey, _ visible: Bool) { visibility[key] = visible }
    func changed() { subject.send() }
}

/// Lets the main run loop turn until `condition` holds, at most `limit` times
/// (Combine's `receive(on: .main)` hops land one turn later); counts turns, not time.
@MainActor func pluginTurnsUntil(limit: Int = 50, _ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< limit {
        if condition() { return true }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    return condition()
}

func pluginViewRef(_ viewID: String = "main", agent: String = "alpha", plugin: String = "studio.demo") -> LeoPluginViewRef {
    LeoPluginViewRef(
        pluginID: plugin, pluginName: "Demo", viewID: viewID, title: viewID.capitalized, sfSymbol: "star",
        agent: LeoPluginAgentRef(machine: "This Mac", name: agent))
}

/// Slot 1: a plugin view is a content case of its row's pane, opened once per choice.
@MainActor
struct LeoRowPaneContentTests {
    private static let agentA = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "alpha"))
    private static let agentB = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "beta"))

    private let host = FakePluginPaneHost()

    private func makePanes(host: (any LeoPluginPaneHosting)? = nil) -> LeoRowPanes {
        let panes = LeoRowPanes(makeAccess: { _ in LeoFileAccessor.local() }, confirm: { _, _ in .cancel })
        panes.pluginHost = host ?? self.host
        return panes
    }

    @Test
    func choosingAViewFrontsItAndSendsViewOpenedOnce() {
        let panes = makePanes()
        let ref = pluginViewRef()

        #expect(panes.openPluginView(ref, for: Self.agentA))

        let pane = panes.pane(for: Self.agentA)
        #expect(pane.content == .plugin(ref))
        #expect(pane.isPluginViewOpen)
        #expect(host.opened == [ref])
    }

    @Test
    func choosingTheOpenViewAgainFrontsItWithoutOpeningItAgain() {
        let panes = makePanes()
        let ref = pluginViewRef()
        panes.openPluginView(ref, for: Self.agentA)
        panes.pane(for: Self.agentA).showEditor()
        #expect(panes.pane(for: Self.agentA).content == .editor)

        panes.openPluginView(ref, for: Self.agentA)

        #expect(panes.pane(for: Self.agentA).content == .plugin(ref))
        #expect(host.opened == [ref])
    }

    @Test
    func choosingAnotherViewReplacesTheFirstAndOpensIt() {
        let panes = makePanes()
        let first = pluginViewRef("main"), second = pluginViewRef("other")
        panes.openPluginView(first, for: Self.agentA)
        panes.openPluginView(second, for: Self.agentA)

        #expect(panes.pane(for: Self.agentA).content == .plugin(second))
        #expect(host.opened == [first, second])
    }

    @Test
    func eachRowKeepsItsOwnViewAndNothingIsReopenedBySwitching() {
        let panes = makePanes()
        let a = pluginViewRef(agent: "alpha"), b = pluginViewRef("other", agent: "beta")
        panes.openPluginView(a, for: Self.agentA)
        panes.openPluginView(b, for: Self.agentB)

        panes.activate(Self.agentA)
        panes.activate(Self.agentB)
        panes.activate(Self.agentA)

        #expect(panes.pane(for: Self.agentA).content == .plugin(a))
        #expect(panes.pane(for: Self.agentB).content == .plugin(b))
        #expect(host.opened == [a, b])
    }

    @Test
    func aViewDoesNotFollowItsPaneToAnotherAgentOrToTheStartScreen() {
        let panes = makePanes()
        let ref = pluginViewRef(agent: "alpha")
        // pluginViewRef's machine is "This Mac"; the sidebar's is the host's display name.
        let local = LeoPluginViewRef(
            pluginID: ref.pluginID, pluginName: ref.pluginName, viewID: ref.viewID, title: ref.title, sfSymbol: ref.sfSymbol,
            agent: LeoPluginAgentRef(machine: LeoHostID.local.displayName, name: "alpha"))
        panes.openPluginView(local, for: Self.agentA)

        panes.rekey(Self.agentA, to: Self.agentB)

        #expect(panes.existingPane(for: Self.agentB)?.pluginView == nil)
        #expect(panes.existingPane(for: Self.agentB)?.content == .editor)
    }

    @Test
    func aViewStaysWhenTheSameAgentIsRekeyedToAnotherDispatch() {
        let panes = makePanes()
        let local = LeoPluginViewRef(
            pluginID: "studio.demo", pluginName: "Demo", viewID: "main", title: "Main", sfSymbol: "star",
            agent: LeoPluginAgentRef(machine: LeoHostID.local.displayName, name: "alpha"))
        panes.openPluginView(local, for: Self.agentA)
        let moved = LeoRowKey.agent(host: .local, name: "alpha", dispatchID: "d-1")

        panes.rekey(Self.agentA, to: moved)

        #expect(panes.existingPane(for: moved)?.pluginView == local)
    }

    @Test
    func aKeptPaneOfARemovedAgentLosesItsPluginView() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let panes = makePanes()
            let local = LeoPluginViewRef(
                pluginID: "studio.demo", pluginName: "Demo", viewID: "main", title: "Main", sfSymbol: "star",
                agent: LeoPluginAgentRef(machine: LeoHostID.local.displayName, name: "alpha"))
            panes.openPluginView(local, for: Self.agentA)
            let pane = panes.pane(for: Self.agentA)
            let path = try sandbox.file("a.txt", "a")
            try await pane.tabs.open(LeoEditorFileID(host: .local, path: path))
            pane.tabs.document?.edit("edited")
            panes.activate(Self.agentB)

            panes.rowRemoved(Self.agentA)

            #expect(pane.pluginView == nil)
            pane.tabs.document?.edit("a")
            await panes.releaseAll()
        }
    }

    @Test
    func closingTheViewBringsTheEditorBack() {
        let panes = makePanes()
        panes.openPluginView(pluginViewRef(), for: Self.agentA)
        let pane = panes.pane(for: Self.agentA)

        pane.closePluginView()

        #expect(pane.content == .editor)
        #expect(!pane.isPluginViewOpen)
    }

    @Test
    func theBrowserTheAgentOpensStaysBehindAPluginView() {
        let presence = FakePresence()
        let panes = LeoRowPanes(makeAccess: { _ in LeoFileAccessor.local() }, confirm: { _, _ in .cancel }, presence: presence)
        panes.pluginHost = host
        let ref = pluginViewRef()
        panes.openPluginView(ref, for: Self.agentA)

        presence.open(LeoAgentBrowserKey(host: .local, agent: "alpha"))

        let pane = panes.pane(for: Self.agentA)
        #expect(pane.isAgentBrowserOpen)
        #expect(pane.content == .plugin(ref), "the user chose the view; an agent's browser doesn't take its place")
        pane.showAgentBrowser()
        #expect(pane.content == .agentBrowser)
        #expect(pane.isPluginViewOpen, "the view stays open behind it")
    }

    @Test
    func withoutAPluginSystemNothingOpens() {
        let panes = LeoRowPanes(makeAccess: { _ in LeoFileAccessor.local() }, confirm: { _, _ in .cancel })
        #expect(!panes.openPluginView(pluginViewRef(), for: Self.agentA))
        #expect(panes.pane(for: Self.agentA).content == .editor)
    }

    @Test
    func aPaneMadeLaterGetsTheHost() {
        let panes = makePanes()
        #expect(panes.pane(for: Self.agentB).pluginHost === host)
    }

    @Test
    func theRowsViewIsKeptPerRowAndNotRebuiltBySwitching() async {
        let panes = makePanes()
        let split = LeoSplitViewControllerFactory.make(
            isSidebarVisible: false, preferredWidth: 240, onDividerWidthChange: { _ in },
            sidebar: AnyView(Color.clear), detail: AnyView(Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)),
            panes: panes
        ).controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1_400, height: 700))
        let container = split.splitViewItems[3].viewController as? LeoRowPaneContainerViewController
        func tabs() -> LeoEditorTabsViewController? { container?.activeChild as? LeoEditorTabsViewController }

        panes.activate(Self.agentA)
        panes.openPluginView(pluginViewRef(agent: "alpha"), for: Self.agentA)
        #expect(await pluginTurnsUntil { tabs()?.shownPlugin != nil })
        let first = tabs()?.shownPlugin
        #expect(!split.splitViewItems[3].isCollapsed, "a plugin view opens the pane")

        panes.activate(Self.agentB)
        #expect(tabs()?.shownPlugin == nil)
        panes.activate(Self.agentA)
        #expect(tabs()?.shownPlugin === first)

        await panes.releaseAll()
        window.close()
    }
}
