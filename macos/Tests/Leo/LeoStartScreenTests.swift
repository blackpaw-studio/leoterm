import AppKit
import Foundation
import Testing

@testable import Ghostty

/// B-050 in a window with one content area (B-055): the first row shown in
/// a start-screen window fills it (the host fills an empty content area),
/// and when the agent is already on screen in another window, that window
/// comes forward and an untouched start screen left behind closes (D-093).
@MainActor struct LeoStartScreenTests {
    private let agent = LeoAgentIdentity(host: .local, name: "worker")
    private let startWindow = LeoWindowID()

    // MARK: Untouched start screen (pure)

    @Test func aFreshStartScreenIsUntouched() {
        #expect(startScreen().isUntouched)
    }

    @Test(arguments: [
        LeoStartScreenState(isUnfilledPlaceholder: false, hasTerminal: false, isEditorOpen: false, isBrowserOpen: false),
        LeoStartScreenState(isUnfilledPlaceholder: true, hasTerminal: true, isEditorOpen: false, isBrowserOpen: false),
        LeoStartScreenState(isUnfilledPlaceholder: true, hasTerminal: false, isEditorOpen: true, isBrowserOpen: false),
        LeoStartScreenState(isUnfilledPlaceholder: true, hasTerminal: false, isEditorOpen: false, isBrowserOpen: true),
    ])
    func aTouchedStartScreenIsNeverDiscarded(_ state: LeoStartScreenState) {
        #expect(!state.isUntouched)
    }

    // MARK: Filling

    @Test func aRowClickInAStartWindowGoesToItsContentArea() async {
        let (host, coordinator) = make()

        await coordinator.attach(identity: agent, from: startWindow, disposition: .content)

        #expect(host.contentCalls.map(\.origin) == [startWindow], "the host fills the empty content area")
        #expect(host.windowCalls.isEmpty)
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func paletteChoiceOnTheStartScreenFillsIt() async {
        let (host, coordinator) = make()
        let router = makeRouter(coordinator)
        let request = LeoSurfaceRequest(origin: startWindow, disposition: .placeholder)
        router.begin(request)

        await router.choose(.agent(agent), for: request)

        #expect(host.placeholderCalls.map(\.origin) == [startWindow])
        #expect(host.placeholderSurfaceIDs == [nil], "the start screen itself, not a pane")
        #expect(host.contentCalls.isEmpty)
    }

    @Test func aPaneLeftByAnExitedAttachIsFilledNotSkipped() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: agent, from: LeoWindowID(), disposition: .content)

        let leaf = LeoSurfaceRequest(origin: startWindow, disposition: .placeholder(surfaceID: UUID()))
        _ = await coordinator.attach(identity: agent, request: leaf)

        #expect(host.placeholderCalls.count == 1, "a pane is like a split: it always attaches")
        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func commandClickFromAStartWindowOpensANewWindow() async {
        let (host, coordinator) = make()

        await coordinator.attach(identity: agent, from: startWindow, disposition: .newWindow)

        #expect(host.windowCalls.count == 1)
        #expect(host.contentCalls.isEmpty)
        #expect(host.discardedPlaceholders.isEmpty, "the user asked for another window; this one stays")
    }

    // MARK: Jumping to the agent's window

    @Test func chooseAgentOnTheStartScreenFocusesItsWindowAndClosesTheStartScreen() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: agent, from: LeoWindowID(), disposition: .content)
        let router = makeRouter(coordinator)
        let request = LeoSurfaceRequest(origin: startWindow, disposition: .placeholder)
        router.begin(request)

        await router.choose(.agent(agent), for: request)

        #expect(host.focused == [host.handles[0]])
        #expect(host.placeholderCalls.isEmpty, "never a second surface for the agent")
        #expect(host.discardedPlaceholders == [startWindow])
    }

    @Test func singleClickOnARowShownElsewhereSaysWhichWindowItCameFrom() {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [row], connectivity: .connected, generation: 1))
        var requests: [(LeoAgentRow.ID, LeoWindowID?)] = []
        model.focusExistingRequested = { requests.append(($0.id, $1)) }
        model.receiveAttachLinks(LeoAttachLinkState(focused: nil, attachCounts: [row.id: 1]))

        model.rowClicked(row, from: startWindow)

        #expect(requests.map(\.0) == [row.id])
        #expect(requests.first?.1 == startWindow)
    }

    @Test func focusingTheAgentsWindowFromAStartWindowAsksToCloseIt() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: agent, from: LeoWindowID(), disposition: .content)

        #expect(coordinator.focusExisting(agent, from: startWindow))

        #expect(host.focused == [host.handles[0]])
        #expect(host.discardedPlaceholders == [startWindow])
    }

    @Test func focusingWithoutAnOriginOrFromItsOwnWindowClosesNothing() async {
        let (host, coordinator) = make()
        await coordinator.attach(identity: agent, from: startWindow, disposition: .content)

        #expect(coordinator.focusExisting(agent))
        #expect(coordinator.focusExisting(agent, from: startWindow))

        #expect(host.discardedPlaceholders.isEmpty)
    }

    @Test func nothingToFocusKeepsTheStartScreen() {
        let (host, coordinator) = make()

        #expect(!coordinator.focusExisting(agent, from: startWindow))

        #expect(host.discardedPlaceholders.isEmpty)
    }

    // MARK: Helpers

    private var row: LeoAgentRow {
        LeoAgentRow(host: agent.host, name: agent.name, template: nil, status: .running, activity: .idle, actionDetail: nil)
    }

    private func startScreen() -> LeoStartScreenState {
        LeoStartScreenState(isUnfilledPlaceholder: true, hasTerminal: false, isEditorOpen: false, isBrowserOpen: false)
    }

    private func make() -> (FakeAttachContentHost, LeoAttachCoordinator) {
        let host = FakeAttachContentHost()
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
            attach: { identity, request, placement in
                await coordinator.attach(identity: identity, request: request, placement: placement).map { _ in () }
            },
            openPlainShell: { _ in .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
    }
}
