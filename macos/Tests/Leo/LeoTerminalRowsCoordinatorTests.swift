import Foundation
import Testing

@testable import Ghostty

/// B-057: showing and closing a terminal row through the coordinator,
/// against the fake host (the real one is `LeoTerminalRowsIntegrationTests`).
@MainActor struct LeoTerminalRowsCoordinatorTests {
    private let worker = LeoAgentIdentity(host: .local, name: "worker")
    private let window = LeoWindowID()

    private func make() -> (FakeAttachTabHost, LeoAttachCoordinator) {
        let host = FakeAttachTabHost()
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
