import Foundation
import Testing

@testable import Ghostty

/// B-056: switching rows keeps the most recently viewed agents attached but
/// hidden (D-108: four tmux clients per window, shown one included), shows
/// them again without a new attach, and lets the least recently viewed go
/// beyond that. Against the fake host (which applies the real
/// `LeoLivePool` policy); the real surfaces are
/// `LeoLivePoolIntegrationTests`.
@MainActor struct LeoLivePoolSwitchTests {
    private let window = LeoWindowID()
    private let otherWindow = LeoWindowID()
    private let agents = (1...6).map { LeoAgentIdentity(host: .local, name: "agent-\($0)") }

    // MARK: Switching back is instant

    @Test func switchingBackToARecentAgentShowsItsHiddenSurface() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(2), coordinator)

        let result = await coordinator.attach(identity: agents[0], request: content())

        #expect(host.contentCalls.count == 2, "no new attach, so no new tmux client")
        #expect(host.revealed == [host.handles[0]])
        #expect((try? result.get()) == host.handles[0])
        #expect(host.shownInContent[window] == host.handles[0])
        #expect(host.isHidden(host.handles[1]), "the one it replaced is hidden in turn")
        #expect(host.letGo.isEmpty)
    }

    @Test func theFourMostRecentSwitchWithoutAttaching() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(4), coordinator)

        await showEach(agents.prefix(4).reversed(), coordinator)
        await showEach(agents.prefix(4), coordinator)

        #expect(host.contentCalls.count == 4)
        #expect(host.letGo.isEmpty)
    }

    @Test func aFifthAgentEvictsTheLeastRecentlyViewed() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(5), coordinator)

        #expect(host.letGo == [host.handles[0]], "its surface goes, so its tmux client detaches")
        #expect(!host.isOpen(host.handles[0]))

        _ = await coordinator.attach(identity: agents[0], request: content())

        #expect(host.contentCalls.count == 6, "evicted, so it attaches anew")
        #expect(host.letGo == [host.handles[0], host.handles[1]])
    }

    @Test func viewingMakesAnAgentTheMostRecent() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(4), coordinator)
        _ = await coordinator.attach(identity: agents[0], request: content())

        _ = await coordinator.attach(identity: agents[4], request: content())

        #expect(host.letGo == [host.handles[1]], "agent-2 is now the least recently viewed")
        #expect(host.isOpen(host.handles[0]))
    }

    @Test func neverMoreThanFourClientsPerWindow() async {
        let (host, coordinator) = make()
        let order = [0, 1, 2, 3, 4, 5, 0, 2, 5, 1, 3, 4, 0]

        for index in order {
            _ = await coordinator.attach(identity: agents[index], request: content())
            let open = host.handles.filter { host.isOpen($0) && $0.windowID == window }
            #expect(open.count <= LeoLivePoolCapacity.perWindow)
        }
    }

    @Test func aRemoteAgentPoolsTheSame() async {
        let (host, coordinator) = make()
        let remote = LeoAgentIdentity(host: .remote("box"), name: "agent-1")
        _ = await coordinator.attach(identity: remote, request: content())
        _ = await coordinator.attach(identity: agents[0], request: content())

        _ = await coordinator.attach(identity: remote, request: content())

        #expect(host.contentCalls.count == 2, "the pool doesn't care how an agent is reached")
        #expect(host.revealed == [host.handles[0]])
    }

    // MARK: The registry

    @Test func aHiddenAgentIsAttachedButNotOnScreen() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(2), coordinator)

        #expect(coordinator.reusableHandleCount == 2, "hidden stays open until evicted")
        #expect(coordinator.linkState.tabCount(for: rowID(agents[0])) == 0, "a click shows it rather than focusing nothing")
        #expect(coordinator.linkState.tabCount(for: rowID(agents[1])) == 1)
        #expect(!coordinator.focusExisting(agents[0], from: window))
        #expect(host.focused.isEmpty)
    }

    @Test func showingAgainCountsItOnScreen() async {
        let (_, coordinator) = make()
        await showEach(agents.prefix(2), coordinator)

        _ = await coordinator.attach(identity: agents[0], request: content())

        #expect(coordinator.linkState.tabCount(for: rowID(agents[0])) == 1)
        #expect(coordinator.linkState.tabCount(for: rowID(agents[1])) == 0)
    }

    @Test func anEvictedAgentLeavesTheRegistry() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(5), coordinator)
        await waitUntil { coordinator.reusableHandleCount == 4 }

        #expect(coordinator.reusableHandleCount == 4)
        #expect(host.letGo == [host.handles[0]])
    }

    @Test func aHiddenSurfaceTheHostLostAttachesAnewAskingOnce() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(2), coordinator)
        host.refusesReveal = true
        let asked = host.replacementConfirmations.count

        _ = await coordinator.attach(identity: agents[0], request: content())

        #expect(host.contentCalls.count == 3)
        #expect(host.replacementConfirmations.count == asked + 1)
    }

    // MARK: A running shell still asks

    @Test func keepingARunningShellKeepsTheAgentHidden() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(2), coordinator)
        host.confirmsReplacement = false

        let result = await coordinator.attach(identity: agents[0], request: content())

        if case .failure(let error) = result { #expect(error.isCancellation) } else { Issue.record("expected a cancellation") }
        #expect(host.revealed.isEmpty)
        #expect(host.isHidden(host.handles[0]))
    }

    // MARK: Requests racing on one window

    /// A's confirmation is about what the window showed when A asked; B
    /// replaced that meanwhile, so A is dropped (a quiet cancel) rather
    /// than replacing content nobody confirmed. The newer request wins.
    @Test func aContentRequestSupersededWhileAskingIsDropped() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(3), coordinator)
        host.heldConfirmations = 1
        let pending = Task { await coordinator.attach(identity: agents[3], request: content()) }
        await waitUntil { host.pendingConfirmationCount == 1 }
        #expect(host.pendingConfirmationCount == 1)

        _ = await coordinator.attach(identity: agents[4], request: content())
        host.resumeConfirmation(true)
        let result = await pending.value

        if case .failure(let error) = result { #expect(error.isCancellation) } else { Issue.record("expected A dropped") }
        #expect(host.shownInContent[window] == host.handles.last, "B, the newer request, is shown")
        #expect(host.contentCalls.count == 4, "A never attached")
        let open = host.handles.filter(host.isOpen)
        #expect(open.count <= LeoLivePoolCapacity.perWindow)
        #expect(open.allSatisfy { host.isShown($0) || host.isHidden($0) }, "no orphaned hidden surface")
        #expect(coordinator.reusableHandleCount == open.count, "one handle per agent, all tracked")
    }

    @Test func aSupersededRevealIsDroppedToo() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(2), coordinator)
        host.heldConfirmations = 1
        let pending = Task { await coordinator.attach(identity: agents[0], request: content()) }
        await waitUntil { host.pendingConfirmationCount == 1 }

        _ = await coordinator.attach(identity: agents[2], request: content())
        host.resumeConfirmation(true)
        _ = await pending.value

        #expect(host.revealed.isEmpty)
        #expect(host.shownInContent[window] == host.handles[2])
        #expect(host.isHidden(host.handles[0]) && host.isHidden(host.handles[1]))
    }

    @Test func aCancelledCompetingRequestDoesNotDropTheWaitingOne() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(1), coordinator)
        host.heldConfirmations = 1
        let pending = Task { await coordinator.attach(identity: agents[1], request: content()) }
        await waitUntil { host.pendingConfirmationCount == 1 }
        host.confirmsReplacement = false

        _ = await coordinator.attach(identity: agents[2], request: content())
        host.resumeConfirmation(true)
        let result = await pending.value

        #expect((try? result.get()) == host.handles.last)
        #expect(host.shownInContent[window] == host.handles.last)
    }

    // MARK: One tmux client per agent across windows

    @Test func anAgentHiddenInAnotherWindowIsLetGoThenShownHere() async {
        let (host, coordinator) = make()
        _ = await coordinator.attach(identity: agents[0], request: content(in: otherWindow))
        _ = await coordinator.attach(identity: agents[1], request: content(in: otherWindow))

        _ = await coordinator.attach(identity: agents[0], request: content())

        #expect(host.letGo == [host.handles[0]], "never two tmux clients for it")
        #expect(host.focused.isEmpty, "hidden isn't on screen, so there is no window to bring forward")
        #expect(host.contentCalls.last?.origin == window)
        #expect(host.discardedPlaceholders.isEmpty)
        #expect(!host.isOpen(host.handles[0]))
        #expect(host.isOpen(host.handles[2]))
    }

    @Test func aNewWindowForAHiddenAgentLetsTheHiddenOneGo() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(2), coordinator)

        _ = await coordinator.attach(identity: agents[0], request: LeoSurfaceRequest(origin: window, disposition: .window))

        #expect(host.windowCalls.count == 1)
        #expect(host.letGo == [host.handles[0]])
    }

    @Test func aSplitOfAHiddenAgentLetsTheHiddenOneGo() async {
        let (host, coordinator) = make()
        await showEach(agents.prefix(2), coordinator)

        let split = LeoSurfaceRequest(origin: window, disposition: .split(.right), splitSourceSurface: host.handles[1].surfaceID)
        _ = await coordinator.attach(identity: agents[0], request: split)

        #expect(host.splitCalls.count == 1)
        #expect(host.letGo == [host.handles[0]])
    }

    // MARK: After an agent restart (B-053)

    @Test func anExitedPaneOnScreenIsRefilledInPlace() async {
        let (host, coordinator) = make()
        _ = await coordinator.attach(identity: agents[0], request: content())
        let exited = host.handles[0]
        await host.emitAndWait(.processExited(exited))

        _ = await coordinator.attach(identity: agents[0], request: content())

        #expect(host.placeholderSurfaceIDs == [exited.surfaceID], "the pane it left, not the whole content area")
        #expect(host.contentCalls.count == 1)
        #expect(host.replacementConfirmations.count == 1, "only the first show asked; refilling replaces nothing")
    }

    @Test func anExitedPaneInAnotherWindowIsNotRefilledFromHere() async {
        let (host, coordinator) = make()
        _ = await coordinator.attach(identity: agents[0], request: content(in: otherWindow))
        await host.emitAndWait(.processExited(host.handles[0]))

        _ = await coordinator.attach(identity: agents[0], request: content())

        #expect(host.placeholderSurfaceIDs.isEmpty)
        #expect(host.contentCalls.map(\.origin) == [otherWindow, window])
    }

    // MARK: Helpers

    private func content(in origin: LeoWindowID? = nil) -> LeoSurfaceRequest {
        LeoSurfaceRequest(origin: origin ?? window, disposition: .content)
    }

    private func showEach(_ identities: some Sequence<LeoAgentIdentity>, _ coordinator: LeoAttachCoordinator) async {
        for identity in identities { _ = await coordinator.attach(identity: identity, request: content()) }
    }

    private func rowID(_ identity: LeoAgentIdentity) -> LeoAgentRow.ID { LeoAgentRow.ID(host: identity.host, name: identity.name) }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    private func make() -> (FakeAttachTabHost, LeoAttachCoordinator) {
        let host = FakeAttachTabHost()
        let coordinator = LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            remoteCommandBuilder: { "ssh box leo attach \($0.name)" },
            report: { _ in },
            lifecycleEventHandled: { host.acknowledge($0) }
        )
        return (host, coordinator)
    }
}
