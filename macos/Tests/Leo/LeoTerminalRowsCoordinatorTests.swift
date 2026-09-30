import Foundation
import Testing

@testable import Ghostty

/// B-057: showing and closing a terminal row through the coordinator,
/// against the fake host (the real one is `LeoTerminalRowsIntegrationTests`).
@MainActor struct LeoTerminalRowsCoordinatorTests {
    private let worker = LeoAgentIdentity(host: .local, name: "worker")
    private let window = LeoWindowID()

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

    private func newShell(_ coordinator: LeoAttachCoordinator) async throws -> AttachmentHandle {
        try await coordinator.openPlainShell(request: LeoSurfaceRequest(origin: window, disposition: .content)).get()
    }

    @Test func showingAHiddenTerminalRevealsTheSameShell() async throws {
        let (host, coordinator) = make()
        let shell = try await newShell(coordinator)
        await coordinator.attach(identity: worker, from: window, disposition: .content)
        try #require(host.isHidden(shell))

        await coordinator.showTerminal(shell)

        #expect(host.revealed == [shell])
        #expect(host.isShown(shell))
        #expect(host.contentCalls.count == 2, "no new shell")
    }

    @Test func showingTheShownTerminalFocusesIt() async throws {
        let (host, coordinator) = make()
        let shell = try await newShell(coordinator)

        await coordinator.showTerminal(shell)

        #expect(host.focused == [shell])
        #expect(host.revealed.isEmpty)
    }

    /// Switching to a terminal replaces the content area like any row, so
    /// what it would close (a shell beside an agent) is asked about first.
    @Test func showingATerminalAsksLikeAnyContentRequest() async throws {
        let (host, coordinator) = make()
        let shell = try await newShell(coordinator)
        await coordinator.attach(identity: worker, from: window, disposition: .content)
        host.confirmsReplacement = false

        await coordinator.showTerminal(shell)

        #expect(host.revealed.isEmpty)
        #expect(host.replacementConfirmations.last == window)
    }

    /// The row was selected when clicked. Showing it didn't happen -- its
    /// confirm was cancelled, the host let its shell go meanwhile, or it
    /// closed -- so the sidebar selects what the window does show again,
    /// and nothing on screen changes.
    @Test(arguments: ["cancelled", "not revealed", "closed"])
    func aTerminalNotShownGivesTheSelectionBack(_ outcome: String) async throws {
        let (host, coordinator) = make()
        let shell = try await newShell(coordinator)
        await coordinator.attach(identity: worker, from: window, disposition: .content)
        let agent = try #require(host.shownInContent[window])
        switch outcome {
        case "cancelled": host.confirmsReplacement = false
        case "not revealed": host.refusesReveal = true
        default: coordinator.closeTerminal(shell)
        }

        await coordinator.showTerminal(shell)

        #expect(host.reselectedWindows == [window])
        #expect(host.revealed.isEmpty)
        #expect(host.shownInContent[window] == agent)
    }

    @Test func aShownTerminalKeepsItsSelection() async throws {
        let (host, coordinator) = make()
        let shell = try await newShell(coordinator)
        await coordinator.attach(identity: worker, from: window, disposition: .content)

        await coordinator.showTerminal(shell)
        await coordinator.showTerminal(shell)

        #expect(host.revealed == [shell])
        #expect(host.reselectedWindows.isEmpty, "the host selects what it reveals")
    }

    @Test func aGoneTerminalShowsNothingAndAsksNothing() async throws {
        let (host, coordinator) = make()
        _ = try await newShell(coordinator)
        let asked = host.replacementConfirmations.count

        await coordinator.showTerminal(AttachmentHandle(surfaceID: UUID(), windowID: window))

        #expect(host.revealed.isEmpty)
        #expect(host.focused.isEmpty)
        #expect(host.replacementConfirmations.count == asked)
    }

    @Test func closingTheShownTerminalIsTheHosts() async throws {
        let (host, coordinator) = make()
        let shell = try await newShell(coordinator)

        coordinator.closeTerminal(shell)

        #expect(host.closedTerminals == [shell])
    }

    /// A shell a switch hid can still be closing (`exit` racing the switch,
    /// or ⌘W's confirm answered after it): the host lets it go. Nothing on
    /// screen changed, so a request asking meanwhile still goes ahead, and
    /// focus isn't read again.
    @Test func closingAHiddenTerminalIsStillTheHosts() async throws {
        let (host, coordinator) = make()
        let shell = try await newShell(coordinator)
        await coordinator.attach(identity: worker, from: window, disposition: .content)
        let agent = try #require(host.handles.last)
        try #require(host.isHidden(shell))
        host.heldConfirmations = 1
        let waiting = Task { await coordinator.attach(identity: LeoAgentIdentity(host: .local, name: "other"), request: .init(origin: window, disposition: .content)) }
        while host.pendingConfirmationCount == 0 { await Task.yield() }
        host.focusedHandle = agent

        coordinator.closeTerminal(shell)

        #expect(host.closedTerminals == [shell])
        #expect(coordinator.linkState.focused == nil, "focus wasn't read again")
        host.resumeConfirmation(true)
        let result = await waiting.value
        #expect((try? result.get()) != nil, "the content area wasn't replaced, so the waiting request isn't superseded")
    }

    @Test func closingAGoneTerminalDoesNothing() async throws {
        let (host, coordinator) = make()
        _ = try await newShell(coordinator)

        coordinator.closeTerminal(AttachmentHandle(surfaceID: UUID(), windowID: window))

        #expect(host.closedTerminals.isEmpty)
    }

    /// D-110: a request still asking when a terminal switch replaced the
    /// content is dropped -- the switch was the newer intent.
    @Test func aRequestAskingWhenATerminalIsShownIsDropped() async throws {
        let (host, coordinator) = make()
        let shell = try await newShell(coordinator)
        await coordinator.attach(identity: worker, from: window, disposition: .content)
        host.heldConfirmations = 1
        let waiting = Task { await coordinator.attach(identity: LeoAgentIdentity(host: .local, name: "other"), request: .init(origin: window, disposition: .content)) }
        while host.pendingConfirmationCount == 0 { await Task.yield() }

        await coordinator.showTerminal(shell)
        host.resumeConfirmation(true)
        let result = await waiting.value

        #expect(host.isShown(shell))
        #expect(host.contentCalls.count == 2, "the older request didn't replace the terminal")
        if case .failure(let error) = result { #expect(error.isCancellation) } else { Issue.record("expected a quiet cancel") }
    }
}
