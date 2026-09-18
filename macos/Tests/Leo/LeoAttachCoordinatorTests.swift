import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoAttachCoordinatorTests {
    private let identity = LeoAgentIdentity(host: .local, name: "worker")
    private let origin = LeoWindowID()

    @Test func reuseOpensThenFocusesExisting() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        #expect(host.tabCalls.count == 1)
        #expect(host.focused == [host.handles[0]])
    }

    @Test func newWindowAlwaysOpens() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .newWindow)
        await coordinator.attach(identity: identity, from: origin, disposition: .newWindow)
        #expect(host.windowCalls.count == 2)
        #expect(host.focused.isEmpty)
    }

    @Test func concurrentReuseCoalescesOpen() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await coordinator.attach(identity: self.identity, from: self.origin, disposition: .reuseOrTab) }
            group.addTask { await coordinator.attach(identity: self.identity, from: self.origin, disposition: .reuseOrTab) }
        }
        #expect(host.tabCalls.count == 1)
    }

    @Test(arguments: [AttachLifecycleEvent.Kind.closed, .processExited])
    fileprivate func lifecycleMakesNextAttachOpenFresh(_ kind: AttachLifecycleEvent.Kind) async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        let first = host.handles[0]
        await host.emitAndWait(kind.event(first))
        #expect(await coordinator.reusableHandleCount == 0)
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        #expect(host.tabCalls.count == 2)
        #expect(host.focused.isEmpty)
    }

    @Test func openFailureReportsAndRegistersNothing() async {
        let host = FakeAttachTabHost()
        host.openError = FakeError.failed
        var errors: [LeoAttachError] = []
        let coordinator = makeCoordinator(host: host) { errors.append($0) }
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        host.openError = nil
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        #expect(errors.count == 1)
        #expect(errors.first?.identity == identity)
        #expect(host.tabCalls.count == 2)
    }

    @Test func seedsTitleAndClearsOnLaterNonemptyTitle() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        let handle = host.handles[0]
        #expect(host.titles.count == 1)
        #expect(host.titles.first?.0 == handle)
        #expect(host.titles.first?.1 == "worker · localhost")
        await host.emitAndWait(.titleChanged(handle, "tmux title"))
        #expect(host.titles.last?.1 == nil)
    }

    @Test func titleSeedRemainsWithoutChange() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        #expect(host.titles.count == 1)
    }

    @Test func closedAccordingToHostIsDiscarded() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        host.openHandles.remove(host.handles[0])
        await coordinator.attach(identity: identity, from: origin, disposition: .reuseOrTab)
        #expect(host.tabCalls.count == 2)
    }

    @Test func delayedFailureIsReportedForAttachedIdentityNotCurrentSelection() async {
        let first = LeoAgentIdentity(host: .local, name: "first")
        let second = LeoAgentIdentity(host: .local, name: "second")
        let model = LeoSidebarModel()
        let host = FakeAttachTabHost()
        host.openError = FakeError.failed
        let gate = AttachGate()
        let coordinator = makeCoordinator(host: host) { error in
            model.setRowError(.init(host: error.identity.host, name: error.identity.name), message: error.message)
        }

        model.selection = .init(host: first.host, name: first.name)
        let task = Task {
            await gate.wait()
            await coordinator.attach(identity: first, from: self.origin, disposition: .reuseOrTab)
        }
        model.selection = .init(host: second.host, name: second.name)
        await gate.open()
        await task.value

        #expect(model.rowErrors[.init(host: first.host, name: first.name)] != nil)
        #expect(model.rowErrors[.init(host: second.host, name: second.name)] == nil)
    }

    @Test func remoteIdentityUsesTheRemoteCommandBuilderNotTheLocalExecutable() async throws {
        let host = FakeAttachTabHost()
        let remoteIdentity = LeoAgentIdentity(host: .remote("work"), name: "worker")
        var builtFor: LeoAgentIdentity?
        let coordinator = makeCoordinator(host: host, remoteCommandBuilder: { identity in
            builtFor = identity
            return "env -u TMUX -u TMUX_PANE ssh -t 'work' 'leo agent attach -- worker'"
        })

        await coordinator.attach(identity: remoteIdentity, from: origin, disposition: .reuseOrTab)

        #expect(builtFor == remoteIdentity)
        #expect(host.tabCalls.first?.0 == "env -u TMUX -u TMUX_PANE ssh -t 'work' 'leo agent attach -- worker'")
    }

    @Test func remoteCommandBuilderFailureReportsExecutableError() async {
        let host = FakeAttachTabHost()
        let remoteIdentity = LeoAgentIdentity(host: .remote("work"), name: "worker")
        var reported: LeoAttachError?
        let coordinator = makeCoordinator(
            host: host,
            report: { reported = $0 },
            remoteCommandBuilder: { _ in throw LeoDaemonError.hostUnavailable("Remote host work is not configured") }
        )

        await coordinator.attach(identity: remoteIdentity, from: origin, disposition: .reuseOrTab)

        #expect(reported?.identity == remoteIdentity)
        #expect(host.tabCalls.isEmpty)
    }

    @Test func splitAlwaysOpensEvenWithLiveTab() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        let source = UUID()
        let tabRequest = LeoSurfaceRequest(origin: origin, disposition: .tab)
        let splitRequest = LeoSurfaceRequest(origin: origin, disposition: .split(.right), splitSourceSurface: source)

        _ = await coordinator.attach(identity: identity, request: tabRequest)
        _ = await coordinator.attach(identity: identity, request: splitRequest)
        _ = await coordinator.attach(identity: identity, request: splitRequest)

        #expect(host.tabCalls.count == 1)
        #expect(host.splitCalls.count == 2)
        #expect(host.splitCalls.allSatisfy { $0.3 == source && $0.4 == .right })
    }

    @Test func splitWithoutSourceSurfaceReportsAndOpensNothing() async {
        let host = FakeAttachTabHost()
        var errors: [LeoAttachError] = []
        let coordinator = makeCoordinator(host: host) { errors.append($0) }
        let request = LeoSurfaceRequest(origin: origin, disposition: .split(.left))

        let result = await coordinator.attach(identity: identity, request: request)

        #expect(host.splitCalls.isEmpty)
        #expect(errors.count == 1)
        if case .failure = result {} else { Issue.record("expected failure") }
    }

    @Test func placeholderFillsExactlyOncePerRequest() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder)

        let result = await coordinator.attach(identity: identity, request: request)

        #expect(host.placeholderCalls.count == 1)
        if case .success = result {} else { Issue.record("expected success") }
    }

    @Test func windowRequestAlwaysOpensViaSurfaceRequestAPI() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .window)

        _ = await coordinator.attach(identity: identity, request: request)
        _ = await coordinator.attach(identity: identity, request: request)

        #expect(host.windowCalls.count == 2)
    }

    @Test func tabRequestReusesLiveHandle() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)

        let first = await coordinator.attach(identity: identity, request: request)
        let second = await coordinator.attach(identity: identity, request: request)

        #expect(host.tabCalls.count == 1)
        #expect(host.focused.count == 1)
        if case .success(let a) = first, case .success(let b) = second { #expect(a == b) } else { Issue.record("expected success") }
    }

    @Test func openPlainShellUsesRequestDispositionWithNoIdentityBookkeeping() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)

        let result = await coordinator.openPlainShell(request: request)

        #expect(host.tabCalls.count == 1)
        #expect(host.tabCalls.first?.0 == "")
        if case .success = result {} else { Issue.record("expected success") }
        // A second plain shell for the same origin/tab disposition must not
        // reuse -- plain shells carry no identity to key reuse on.
        _ = await coordinator.openPlainShell(request: request)
        #expect(host.tabCalls.count == 2)
    }

    @Test func openPlainShellFailureReportsWithSentinelIdentity() async {
        let host = FakeAttachTabHost()
        host.openError = FakeError.failed
        var errors: [LeoAttachError] = []
        let coordinator = makeCoordinator(host: host) { errors.append($0) }
        let request = LeoSurfaceRequest(origin: origin, disposition: .window)

        let result = await coordinator.openPlainShell(request: request)

        #expect(errors.count == 1)
        if case .failure = result {} else { Issue.record("expected failure") }
    }

    @Test func plainShellProcessExitedThenClosedLeavesNoState() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)

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
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        guard case .success(let handle) = await coordinator.attach(identity: identity, request: request) else {
            Issue.record("expected success")
            return
        }

        await host.emitAndWait(.processExited(handle))

        #expect(host.reborn == [handle])
        #expect(coordinator.inactiveHandleCount == 1)
    }

    @Test func plainShellExitDoesNotRebirth() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        guard case .success(let handle) = await coordinator.openPlainShell(request: .init(origin: origin, disposition: .tab)) else {
            Issue.record("expected success")
            return
        }

        await host.emitAndWait(.processExited(handle))

        #expect(host.reborn.isEmpty)
    }

    @Test func placeholderChoiceReplacesTargetSurface() async {
        let host = FakeAttachTabHost()
        let coordinator = makeCoordinator(host: host)
        let surfaceID = UUID()
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder(surfaceID: surfaceID))

        _ = await coordinator.attach(identity: identity, request: request)

        #expect(host.placeholderSurfaceIDs == [surfaceID])
    }

    private func makeCoordinator(
        host: FakeAttachTabHost,
        report: @escaping (LeoAttachError) -> Void = { _ in },
        remoteCommandBuilder: @escaping (LeoAgentIdentity) throws -> String = { _ in
            throw LeoDaemonError.hostUnavailable("Remote attach is not configured")
        }
    ) -> LeoAttachCoordinator {
        LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            remoteCommandBuilder: remoteCommandBuilder,
            report: report,
            lifecycleEventHandled: { host.acknowledge($0) }
        )
    }
}

@MainActor private final class FakeAttachTabHost: AttachTabHost {
    var openError: Error?
    var tabCalls: [(String, String?, LeoWindowID, UUID)] = []
    var windowCalls: [(String, String?, UUID)] = []
    var splitCalls: [(String, String?, LeoWindowID, UUID, LeoSplitDirection, UUID)] = []
    var placeholderCalls: [(String, String?, LeoWindowID, UUID)] = []
    var placeholderSurfaceIDs: [UUID?] = []
    var focused: [AttachmentHandle] = []
    var titles: [(AttachmentHandle, String?)] = []
    var handles: [AttachmentHandle] = []
    var openHandles: Set<AttachmentHandle> = []
    private let continuation: AsyncStream<AttachLifecycleEvent>.Continuation
    private var lifecycleAcknowledgement: CheckedContinuation<Void, Never>?
    let lifecycleEvents: AsyncStream<AttachLifecycleEvent>

    init() {
        (lifecycleEvents, continuation) = AsyncStream.makeStream()
    }

    func openTab(command: String, workingDirectory: String?, from origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle {
        tabCalls.append((command, workingDirectory, origin, requestID))
        return try opened()
    }

    func openWindow(command: String, workingDirectory: String?, requestID: UUID) throws -> AttachmentHandle {
        windowCalls.append((command, workingDirectory, requestID))
        return try opened()
    }

    func openSplit(
        command: String,
        workingDirectory: String?,
        origin: LeoWindowID,
        sourceSurface: UUID,
        direction: LeoSplitDirection,
        requestID: UUID
    ) throws -> AttachmentHandle {
        splitCalls.append((command, workingDirectory, origin, sourceSurface, direction, requestID))
        return try opened()
    }

    func fillPlaceholder(command: String, workingDirectory: String?, origin: LeoWindowID, surfaceID: UUID?, requestID: UUID) throws -> AttachmentHandle {
        placeholderCalls.append((command, workingDirectory, origin, requestID))
        placeholderSurfaceIDs.append(surfaceID)
        return try opened()
    }

    var reborn: [AttachmentHandle] = []
    func rebirthPlaceholder(for handle: AttachmentHandle) { reborn.append(handle) }

    func focus(_ handle: AttachmentHandle) { focused.append(handle) }
    func isOpen(_ handle: AttachmentHandle) -> Bool { openHandles.contains(handle) }
    func setTitleSeed(_ handle: AttachmentHandle, title: String?) { titles.append((handle, title)) }
    func emitAndWait(_ event: AttachLifecycleEvent) async {
        await withCheckedContinuation { acknowledgement in
            lifecycleAcknowledgement = acknowledgement
            continuation.yield(event)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let acknowledgement = self.lifecycleAcknowledgement else { return }
                self.lifecycleAcknowledgement = nil
                Issue.record("Lifecycle event was not delivered within 1.0 seconds")
                acknowledgement.resume()
            }
        }
    }

    func acknowledge(_ event: AttachLifecycleEvent) {
        guard lifecycleAcknowledgement != nil else { return }
        lifecycleAcknowledgement?.resume()
        lifecycleAcknowledgement = nil
    }

    private func opened() throws -> AttachmentHandle {
        if let openError { throw openError }
        let handle = AttachmentHandle(surfaceID: UUID(), windowID: LeoWindowID())
        handles.append(handle)
        openHandles.insert(handle)
        return handle
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

private extension AttachLifecycleEvent {
    enum Kind: CaseIterable {
        case closed, processExited

        func event(_ handle: AttachmentHandle) -> AttachLifecycleEvent {
            switch self {
            case .closed: .closed(handle)
            case .processExited: .processExited(handle)
            }
        }
    }
}
