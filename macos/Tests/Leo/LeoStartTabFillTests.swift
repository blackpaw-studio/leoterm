import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-050: while a window's only tab is an untouched start screen, the first
/// attach asked of that window (sidebar row, palette, Agents ▸ Attach) goes
/// into that tab instead of opening one beside it. ⌘ still forces a new
/// tab, ⌥ a new window, and an agent's open tab still wins (B-047) -- the
/// start tab then closes, as Choose Agent… already does (D-093).
@MainActor struct LeoStartTabFillTests {
    private let agent = LeoAgentIdentity(host: .local, name: "worker")
    private let startWindow = LeoWindowID()

    // MARK: Untouched start tab (pure)

    @Test func aFreshStartTabAloneInItsWindowIsLoneAndUntouched() {
        let state = startTab()

        #expect(state.isUntouched)
        #expect(state.isLoneUntouched)
    }

    @Test(arguments: [
        LeoStartTabState(isUnfilledPlaceholder: false, hasTerminal: false, isEditorOpen: false, isBrowserOpen: false, tabCount: 1),
        LeoStartTabState(isUnfilledPlaceholder: true, hasTerminal: true, isEditorOpen: false, isBrowserOpen: false, tabCount: 1),
        LeoStartTabState(isUnfilledPlaceholder: true, hasTerminal: false, isEditorOpen: true, isBrowserOpen: false, tabCount: 1),
        LeoStartTabState(isUnfilledPlaceholder: true, hasTerminal: false, isEditorOpen: false, isBrowserOpen: true, tabCount: 1),
    ])
    func aTouchedStartTabIsNeverFilled(_ state: LeoStartTabState) {
        #expect(!state.isUntouched)
        #expect(!state.isLoneUntouched)
    }

    @Test func anUntouchedStartTabBesideOtherTabsIsNotLone() {
        let state = startTab(tabCount: 2)

        #expect(state.isUntouched, "still closable after a jump (D-093)")
        #expect(!state.isLoneUntouched)
    }

    // MARK: Sidebar double-click and Agents ▸ Attach (`.reuseOrTab`)

    @Test func attachFromALoneStartTabFillsIt() async {
        let (host, coordinator) = make(loneStartTabs: [startWindow])

        await coordinator.attach(identity: agent, from: startWindow, disposition: .reuseOrTab)

        #expect(host.tabCalls.isEmpty, "no tab beside the start tab")
        #expect(host.placeholderCalls.map(\.origin) == [startWindow])
        #expect(host.placeholderSurfaceIDs == [nil], "the start screen itself, not a pane")
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func attachFromAWindowWithoutALoneStartTabOpensATab() async {
        let (host, coordinator) = make()

        await coordinator.attach(identity: agent, from: startWindow, disposition: .reuseOrTab)

        #expect(host.tabCalls.map(\.origin) == [startWindow])
        #expect(host.placeholderCalls.isEmpty)
    }

    @Test func aLoneStartTabInAnotherWindowIsLeftAlone() async {
        let other = LeoWindowID()
        let (host, coordinator) = make(loneStartTabs: [other])

        await coordinator.attach(identity: agent, from: startWindow, disposition: .reuseOrTab)

        #expect(host.tabCalls.map(\.origin) == [startWindow])
        #expect(host.placeholderCalls.isEmpty)
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func commandClickFromALoneStartTabStillOpensANewTab() async {
        let (host, coordinator) = make(loneStartTabs: [startWindow])

        await coordinator.attach(identity: agent, from: startWindow, disposition: .newTab)

        #expect(host.tabCalls.map(\.origin) == [startWindow])
        #expect(host.placeholderCalls.isEmpty)
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func optionDoubleClickFromALoneStartTabStillOpensAWindow() async {
        let (host, coordinator) = make(loneStartTabs: [startWindow])

        await coordinator.attach(identity: agent, from: startWindow, disposition: .newWindow)

        #expect(host.windowCalls.count == 1)
        #expect(host.placeholderCalls.isEmpty)
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func anAgentWithAnOpenTabIsFocusedAndTheLoneStartTabCloses() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: agent, from: LeoWindowID(), disposition: .reuseOrTab)
        host.loneStartTabs = [startWindow]

        await coordinator.attach(identity: agent, from: startWindow, disposition: .reuseOrTab)

        #expect(host.focused == [host.handles[0]])
        #expect(host.placeholderCalls.isEmpty, "never a duplicate of the open tab")
        #expect(host.discardedPlaceholders == [startWindow])
    }

    @Test func anAgentWithAnOpenTabLeavesAWindowWithOtherTabsAlone() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: agent, from: LeoWindowID(), disposition: .reuseOrTab)

        await coordinator.attach(identity: agent, from: startWindow, disposition: .reuseOrTab)

        #expect(host.focused == [host.handles[0]])
        #expect(host.discardedPlaceholders.isEmpty)
    }

    // MARK: Sidebar single click on an agent with an open tab

    @Test func singleClickOnARowWithATabSaysWhichWindowItCameFrom() {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [row], connectivity: .connected, generation: 1))
        var requests: [(LeoAgentRow.ID, LeoWindowID?)] = []
        model.focusExistingRequested = { requests.append(($0.id, $1)) }
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [row.id: 1]))

        model.rowClicked(row, from: startWindow)

        #expect(requests.map(\.0) == [row.id])
        #expect(requests.first?.1 == startWindow)
    }

    @Test func focusingAnOpenTabFromALoneStartTabClosesIt() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: agent, from: LeoWindowID(), disposition: .reuseOrTab)
        host.loneStartTabs = [startWindow]

        #expect(coordinator.focusExisting(agent, from: startWindow))

        #expect(host.focused == [host.handles[0]])
        #expect(host.discardedPlaceholders == [startWindow])
    }

    @Test func focusingAnOpenTabFromAnyOtherWindowKeepsIt() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: agent, from: LeoWindowID(), disposition: .reuseOrTab)

        #expect(coordinator.focusExisting(agent, from: startWindow))
        #expect(coordinator.focusExisting(agent))

        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func nothingToFocusKeepsTheStartTab() {
        let (host, coordinator) = make(loneStartTabs: [startWindow])

        #expect(!coordinator.focusExisting(agent, from: startWindow))

        #expect(host.discardedPlaceholders.isEmpty)
    }

    // MARK: Palette

    @Test func paletteChoiceOnTheStartScreenFillsIt() async {
        let (host, coordinator) = make(loneStartTabs: [startWindow])
        let router = makeRouter(coordinator)
        let request = LeoSurfaceRequest(origin: startWindow, disposition: .placeholder)
        router.begin(request)

        await router.choose(.agent(agent), for: request)

        #expect(host.placeholderCalls.map(\.origin) == [startWindow])
        #expect(host.tabCalls.isEmpty)
    }

    @Test func paletteReturnOnATabRequestFromALoneStartTabFillsIt() async {
        let (host, coordinator) = make(loneStartTabs: [startWindow])
        let router = makeRouter(coordinator)
        let request = LeoSurfaceRequest(origin: startWindow, disposition: .tab)
        router.begin(request)

        await router.choose(.agent(agent), for: request)

        #expect(host.tabCalls.isEmpty)
        #expect(host.placeholderCalls.map(\.requestID) == [request.id], "same request, so its inherited config still applies")
    }

    @Test func paletteCommandReturnOnATabRequestFromALoneStartTabOpensANewTab() async {
        let (host, coordinator) = make(loneStartTabs: [startWindow])
        let router = makeRouter(coordinator)
        let request = LeoSurfaceRequest(origin: startWindow, disposition: .tab)
        router.begin(request)

        await router.choose(.agent(agent, reuse: .alwaysNew), for: request)

        #expect(host.tabCalls.map(\.origin) == [startWindow])
        #expect(host.placeholderCalls.isEmpty)
    }

    // MARK: Helpers

    private var row: LeoAgentRow {
        LeoAgentRow(host: agent.host, name: agent.name, template: nil, status: .running, activity: .idle, actionDetail: nil)
    }

    private func startTab(tabCount: Int = 1) -> LeoStartTabState {
        LeoStartTabState(isUnfilledPlaceholder: true, hasTerminal: false, isEditorOpen: false, isBrowserOpen: false, tabCount: tabCount)
    }

    private func make(loneStartTabs: Set<LeoWindowID> = []) -> (FakeAttachTabHost, LeoAttachCoordinator) {
        let host = FakeAttachTabHost()
        host.loneStartTabs = loneStartTabs
        let coordinator = LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            report: { _ in },
            lifecycleEventHandled: { host.acknowledge($0) }
        )
        return (host, coordinator)
    }

    private func makeRouter(_ coordinator: LeoAttachCoordinator) -> LeoNewSurfaceRouter {
        LeoNewSurfaceRouter(
            attach: { identity, request, reuse in
                await coordinator.attach(identity: identity, request: request, reuse: reuse).map { _ in () }
            },
            openPlainShell: { _ in .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
    }
}
