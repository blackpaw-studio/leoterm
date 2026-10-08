import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoAttachCoordinatorTests {
    private let identity = LeoAgentIdentity(host: .local, name: "worker")
    private let origin = LeoWindowID()

    @Test func reuseOpensThenFocusesExisting() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(host.contentCalls.count == 1)
        #expect(host.focused == [host.handles[0]])
    }

    /// B-055: one agent on screen in at most one window, so a second
    /// new-window request brings the first window forward.
    @Test func newWindowOpensOnceThenFocuses() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .newWindow)
        await coordinator.attach(identity: identity, from: origin, disposition: .newWindow)
        #expect(host.windowCalls.count == 1)
        #expect(host.focused == [host.handles[0]])
    }

    @Test func concurrentReuseCoalescesOpen() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await coordinator.attach(identity: self.identity, from: self.origin, disposition: .content) }
            group.addTask { await coordinator.attach(identity: self.identity, from: self.origin, disposition: .content) }
        }
        #expect(host.contentCalls.count == 1)
    }

    @Test(arguments: [AttachLifecycleEvent.Kind.closed, .processExited])
    fileprivate func lifecycleMakesNextAttachOpenFresh(_ kind: AttachLifecycleEvent.Kind) async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        let first = host.handles[0]
        await host.emitAndWait(kind.event(first))
        #expect(await coordinator.reusableHandleCount == 0)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(host.contentCalls.count + host.placeholderCalls.count == 2)
        // B-056: an exited pane still on screen is refilled in place.
        #expect(host.placeholderSurfaceIDs == (kind == .processExited ? [first.surfaceID] : []))
        #expect(host.focused.isEmpty)
    }

    /// ⌘-click routing (B-004): only a live attach surface has an agent.
    @Test func aSurfaceMapsToItsLiveAgent() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        let handle = host.handles[0]

        #expect(coordinator.identity(forSurface: handle.surfaceID) == identity)
        #expect(coordinator.identity(forSurface: UUID()) == nil)

        await host.emitAndWait(.processExited(handle))
        #expect(coordinator.identity(forSurface: handle.surfaceID) == nil)
    }

    @Test func openFailureReportsAndRegistersNothing() async {
        let host = FakeAttachContentHost()
        host.openError = FakeError.failed
        var errors: [LeoAttachError] = []
        let coordinator = makeCoordinator(host: host) { errors.append($0) }
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        host.openError = nil
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(errors.count == 1)
        #expect(errors.first?.identity == identity)
        #expect(host.contentCalls.count == 2)
    }

    // MARK: Tab title (B-052)

    @Test func attachNamesItsSurfaceAfterTheAgent() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(host.agentNames.count == 1)
        #expect(host.agentNames.first?.0 == host.handles[0])
        #expect(host.agentNames.first?.1 == "worker")
    }

    @Test(arguments: [LeoSurfaceDisposition.split(.right), .window, .placeholder(surfaceID: UUID())])
    func everyAttachDestinationIsNamed(_ disposition: LeoSurfaceDisposition) async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: disposition, splitSourceSurface: UUID())
        _ = await coordinator.attach(identity: identity, request: request)
        #expect(host.agentNames.map(\.1) == ["worker"])
        #expect(host.agentNames.map(\.0) == host.handles)
    }

    @Test func reusingOpenContentDoesNotRenameIt() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(host.agentNames.count == 1)
    }

    @Test func reattachAfterExitNamesTheNewSurface() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        let first = host.handles[0]
        await host.emitAndWait(.processExited(first))

        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder(surfaceID: first.surfaceID))
        _ = await coordinator.attach(identity: identity, request: request)

        #expect(host.handles.count == 2)
        #expect(host.agentNames.map(\.0) == host.handles)
        #expect(host.agentNames.map(\.1) == ["worker", "worker"])
    }

    @Test func plainShellIsNotNamed() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        _ = await coordinator.openPlainShell(request: LeoSurfaceRequest(origin: origin, disposition: .content))
        #expect(host.agentNames.isEmpty)
    }

    @Test func closedAccordingToHostIsDiscarded() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        host.openHandles.remove(host.handles[0])
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        #expect(host.contentCalls.count == 2)
    }

    @Test func delayedFailureIsReportedForAttachedIdentityNotCurrentSelection() async {
        let first = LeoAgentIdentity(host: .local, name: "first")
        let second = LeoAgentIdentity(host: .local, name: "second")
        let model = LeoSidebarModel()
        let host = FakeAttachContentHost()
        host.openError = FakeError.failed
        let gate = AttachGate()
        let coordinator = makeCoordinator(host: host) { error in
            model.setRowError(.init(host: error.identity.host, name: error.identity.name), message: error.message)
        }

        model.selection = .init(host: first.host, name: first.name)
        let task = Task {
            await gate.wait()
            await coordinator.attach(identity: first, from: self.origin, disposition: .content)
        }
        model.selection = .init(host: second.host, name: second.name)
        await gate.open()
        await task.value

        #expect(model.rowErrors[.init(host: first.host, name: first.name)] != nil)
        #expect(model.rowErrors[.init(host: second.host, name: second.name)] == nil)
    }

    @Test func localAttachReadsAdvertisedFeaturesWhenTheCommandIsBuilt() async throws {
        let host = FakeAttachContentHost()
        var features = LeoDaemonFeatures.none
        let coordinator = makeCoordinator(host: host, daemonFeatures: { _ in features })

        await coordinator.attach(identity: LeoAgentIdentity(host: .local, name: "worker"), from: origin, disposition: .content)
        features = LeoDaemonFeatures(["attach_dispatch_placement"])
        await coordinator.attach(identity: LeoAgentIdentity(host: .local, name: "other"), from: origin, disposition: .content)

        #expect(host.contentCalls.first?.command == "env -u TMUX -u TMUX_PANE '/leo' agent attach -- 'worker'")
        #expect(host.contentCalls.last?.command == "env -u TMUX -u TMUX_PANE '/leo' agent attach --dispatch-placement background -- 'other'")
    }

    @Test func remoteIdentityUsesTheRemoteCommandBuilderNotTheLocalExecutable() async throws {
        let host = FakeAttachContentHost()
        let remoteIdentity = LeoAgentIdentity(host: .remote("work"), name: "worker")
        var builtFor: LeoAgentIdentity?
        let coordinator = makeCoordinator(host: host, remoteCommandBuilder: { identity in
            builtFor = identity
            return "env -u TMUX -u TMUX_PANE ssh -t 'work' 'leo agent attach -- worker'"
        })

        await coordinator.attach(identity: remoteIdentity, from: origin, disposition: .content)

        #expect(builtFor == remoteIdentity)
        #expect(host.contentCalls.first?.command == "env -u TMUX -u TMUX_PANE ssh -t 'work' 'leo agent attach -- worker'")
    }

    @Test func remoteCommandBuilderFailureReportsExecutableError() async {
        let host = FakeAttachContentHost()
        let remoteIdentity = LeoAgentIdentity(host: .remote("work"), name: "worker")
        var reported: LeoAttachError?
        let coordinator = makeCoordinator(
            host: host,
            report: { reported = $0 },
            remoteCommandBuilder: { _ in throw LeoDaemonError.hostUnavailable("Remote host work is not configured") }
        )

        await coordinator.attach(identity: remoteIdentity, from: origin, disposition: .content)

        #expect(reported?.identity == remoteIdentity)
        #expect(host.contentCalls.isEmpty)
    }

    @Test func splitAlwaysOpensEvenWithLiveAttach() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let source = UUID()
        let tabRequest = LeoSurfaceRequest(origin: origin, disposition: .content)
        let splitRequest = LeoSurfaceRequest(origin: origin, disposition: .split(.right), splitSourceSurface: source)

        _ = await coordinator.attach(identity: identity, request: tabRequest)
        _ = await coordinator.attach(identity: identity, request: splitRequest)
        _ = await coordinator.attach(identity: identity, request: splitRequest)

        #expect(host.contentCalls.count == 1)
        #expect(host.splitCalls.count == 2)
        #expect(host.splitCalls.allSatisfy { $0.sourceSurface == source && $0.direction == .right })
    }

    @Test func splitWithoutSourceSurfaceReportsAndOpensNothing() async {
        let host = FakeAttachContentHost()
        var errors: [LeoAttachError] = []
        let coordinator = makeCoordinator(host: host) { errors.append($0) }
        let request = LeoSurfaceRequest(origin: origin, disposition: .split(.left))

        let result = await coordinator.attach(identity: identity, request: request)

        #expect(host.splitCalls.isEmpty)
        #expect(errors.count == 1)
        if case .failure = result {} else { Issue.record("expected failure") }
    }

    @Test func placeholderFillsExactlyOncePerRequest() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder)

        let result = await coordinator.attach(identity: identity, request: request)

        #expect(host.placeholderCalls.count == 1)
        if case .success = result {} else { Issue.record("expected success") }
    }

    @Test func windowRequestOpensOnceThenFocusesViaSurfaceRequestAPI() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .window)

        _ = await coordinator.attach(identity: identity, request: request)
        _ = await coordinator.attach(identity: identity, request: request)

        #expect(host.windowCalls.count == 1)
        #expect(host.focused == [host.handles[0]])
    }

    @Test func contentRequestReusesLiveHandle() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .content)

        let first = await coordinator.attach(identity: identity, request: request)
        let second = await coordinator.attach(identity: identity, request: request)

        #expect(host.contentCalls.count == 1)
        #expect(host.focused.count == 1)
        if case .success(let a) = first, case .success(let b) = second { #expect(a == b) } else { Issue.record("expected success") }
    }

    @Test func openPlainShellUsesRequestDispositionWithNoIdentityBookkeeping() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .content)

        let result = await coordinator.openPlainShell(request: request)

        #expect(host.contentCalls.count == 1)
        #expect(host.contentCalls.first?.command == "")
        if case .success = result {} else { Issue.record("expected success") }
        // A second plain shell for the same origin/tab disposition must not
        // reuse -- plain shells carry no identity to key reuse on.
        _ = await coordinator.openPlainShell(request: request)
        #expect(host.contentCalls.count == 2)
    }

    @Test func openPlainShellFailureReportsWithSentinelIdentity() async {
        let host = FakeAttachContentHost()
        host.openError = FakeError.failed
        var errors: [LeoAttachError] = []
        let coordinator = makeCoordinator(host: host) { errors.append($0) }
        let request = LeoSurfaceRequest(origin: origin, disposition: .window)

        let result = await coordinator.openPlainShell(request: request)

        #expect(errors.count == 1)
        if case .failure = result {} else { Issue.record("expected failure") }
    }

    @Test func plainShellProcessExitedThenClosedLeavesNoState() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .content)

        let result = await coordinator.openPlainShell(request: request)
        guard case .success(let handle) = result else {
            Issue.record("expected success")
            return
        }

        await host.emitAndWait(.processExited(handle))
        await host.emitAndWait(.closed(handle))

        #expect(coordinator.reusableHandleCount == 0)
        #expect(coordinator.inactiveHandleCount == 0)
    }

    @Test func agentProcessExitReplacesOnlyThatAgentSurface() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .content)
        guard case .success(let handle) = await coordinator.attach(identity: identity, request: request) else {
            Issue.record("expected success")
            return
        }

        await host.emitAndWait(.processExited(handle))

        #expect(host.reborn == [handle])
        #expect(coordinator.inactiveHandleCount == 1)
    }

    @Test func plainShellExitDoesNotRebirth() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        guard case .success(let handle) = await coordinator.openPlainShell(request: .init(origin: origin, disposition: .content)) else {
            Issue.record("expected success")
            return
        }

        await host.emitAndWait(.processExited(handle))

        #expect(host.reborn.isEmpty)
    }

    @Test func placeholderChoiceReplacesTargetSurface() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let surfaceID = UUID()
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder(surfaceID: surfaceID))

        _ = await coordinator.attach(identity: identity, request: request)

        #expect(host.placeholderSurfaceIDs == [surfaceID])
    }

    // MARK: Focused identity

    @Test func focusedHandleMapsToItsIdentity() async {
        let host = FakeAttachContentHost()
        var changes: [LeoAgentIdentity?] = []
        let coordinator = makeCoordinator(host: host, focusedIdentityChanged: { changes.append($0) })
        await coordinator.attach(identity: identity, from: origin, disposition: .content)

        await host.emitAndWait(.focusChanged(host.handles[0]))

        #expect(coordinator.focusedIdentity == identity)
        #expect(changes == [identity])
    }

    @Test func focusingAnUntrackedSurfaceClearsTheIdentity() async {
        let host = FakeAttachContentHost()
        var changes: [LeoAgentIdentity?] = []
        let coordinator = makeCoordinator(host: host, focusedIdentityChanged: { changes.append($0) })
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        await host.emitAndWait(.focusChanged(host.handles[0]))

        await host.emitAndWait(.focusChanged(AttachmentHandle(surfaceID: UUID(), windowID: origin)))
        await host.emitAndWait(.focusChanged(nil))

        #expect(coordinator.focusedIdentity == nil)
        #expect(changes == [identity, nil], "repeated nil is not a change")
    }

    /// The approved attention decision: the focused split of the key
    /// window counts as viewed even while the sidebar has keyboard focus.
    @Test func keyboardFocusMovingToTheSidebarKeepsTheViewedAgentFocused() async {
        let host = FakeAttachContentHost()
        var changes: [LeoAgentIdentity?] = []
        let coordinator = makeCoordinator(host: host, focusedIdentityChanged: { changes.append($0) })
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        await host.emitAndWait(.focusChanged(host.handles[0]))

        await host.emitAndWait(.focusChanged(nil))

        #expect(coordinator.focusedIdentity == identity)
        #expect(changes == [identity])
    }

    @Test func viewingReportsMoveTheFocusedIdentity() async {
        let host = FakeAttachContentHost()
        var changes: [LeoAgentIdentity?] = []
        let coordinator = makeCoordinator(host: host, focusedIdentityChanged: { changes.append($0) })
        await coordinator.attach(identity: identity, from: origin, disposition: .content)

        await host.emitAndWait(.viewingChanged(host.handles[0]))
        await host.emitAndWait(.focusChanged(nil))
        #expect(coordinator.focusedIdentity == identity, "the sidebar has keyboard focus; the tab is still in view")
        await host.emitAndWait(.viewingChanged(nil))

        #expect(coordinator.focusedIdentity == nil)
        #expect(changes == [identity, nil])
    }

    @Test(arguments: [AttachLifecycleEvent.Kind.closed, .processExited])
    fileprivate func focusedAttachmentEndingClearsTheIdentity(_ kind: AttachLifecycleEvent.Kind) async {
        let host = FakeAttachContentHost()
        var changes: [LeoAgentIdentity?] = []
        let coordinator = makeCoordinator(host: host, focusedIdentityChanged: { changes.append($0) })
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        await host.emitAndWait(.focusChanged(host.handles[0]))

        await host.emitAndWait(kind.event(host.handles[0]))

        #expect(coordinator.focusedIdentity == nil)
        #expect(changes == [identity, nil])
    }

    @Test func splitOfTheSameAgentKeepsItFocused() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let splitSource = UUID()
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        _ = await coordinator.attach(
            identity: identity,
            request: LeoSurfaceRequest(origin: origin, disposition: .split(.right), splitSourceSurface: splitSource)
        )

        await host.emitAndWait(.focusChanged(host.handles[1]))

        #expect(coordinator.focusedIdentity == identity)
    }

    // MARK: A closed window's content version (B-062)

    @Test func closingAWindowForgetsItsContentVersion() async {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        let other = LeoWindowID()
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        await coordinator.attach(identity: LeoAgentIdentity(host: .local, name: "other"), from: other, disposition: .content)
        #expect(coordinator.contentVersionWindows == [origin, other])

        coordinator.windowClosed(origin)
        coordinator.windowClosed(origin)

        #expect(coordinator.contentVersionWindows == [other], "only the closed window's entry goes, idempotently")
    }

    /// A request asking to replace a window's content when that window
    /// closes, with nothing having replaced its content meanwhile, resolves
    /// as before pruning: it goes on to the host rather than being dropped
    /// as superseded.
    @Test func aRequestAwaitingConfirmOnAWindowThatClosesUnreplacedGoesOn() async throws {
        let host = FakeAttachContentHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .content)
        host.heldConfirmations = 1
        let next = LeoAgentIdentity(host: .local, name: "next")
        let pending = Task { await coordinator.attach(identity: next, request: LeoSurfaceRequest(origin: origin, disposition: .content)) }
        await waitUntil { host.pendingConfirmationCount == 1 }
        try #require(host.pendingConfirmationCount == 1)

        coordinator.windowClosed(origin)
        host.resumeConfirmation(true)
        let result = await pending.value

        #expect((try? result.get()) == host.handles.last)
        #expect(host.contentCalls.count == 2, "not dropped as superseded")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    private func makeCoordinator(
        host: FakeAttachContentHost,
        report: @escaping (LeoAttachError) -> Void = { _ in },
        remoteCommandBuilder: @escaping (LeoAgentIdentity) throws -> String = { _ in
            throw LeoDaemonError.hostUnavailable("Remote attach is not configured")
        },
        focusedIdentityChanged: @escaping (LeoAgentIdentity?) -> Void = { _ in },
        daemonFeatures: @escaping (LeoHostID) -> LeoDaemonFeatures = { _ in .none }
    ) -> LeoAttachCoordinator {
        LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            remoteCommandBuilder: remoteCommandBuilder,
            daemonFeatures: daemonFeatures,
            report: report,
            lifecycleEventHandled: { host.acknowledge($0) },
            focusedIdentityChanged: focusedIdentityChanged
        )
    }
}

private enum FakeError: Error { case failed }

private actor AttachGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in self.continuation = continuation }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
