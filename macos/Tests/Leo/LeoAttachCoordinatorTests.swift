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
        host.emit(kind.event(first))
        await awaitCondition { await coordinator.reusableHandleCount == 0 }
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
        host.emit(.titleChanged(handle, "tmux title"))
        await awaitCondition { await host.titles.count == 2 }
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

    private func makeCoordinator(host: FakeAttachTabHost, report: @escaping (LeoAttachError) -> Void = { _ in }) -> LeoAttachCoordinator {
        LeoAttachCoordinator(host: host, executable: { "/leo" }, report: report)
    }
}

@MainActor private final class FakeAttachTabHost: AttachTabHost {
    var openError: Error?
    var tabCalls: [(String, String?, LeoWindowID)] = []
    var windowCalls: [(String, String?)] = []
    var focused: [AttachmentHandle] = []
    var titles: [(AttachmentHandle, String?)] = []
    var handles: [AttachmentHandle] = []
    var openHandles: Set<AttachmentHandle> = []
    private let continuation: AsyncStream<AttachLifecycleEvent>.Continuation
    let lifecycleEvents: AsyncStream<AttachLifecycleEvent>

    init() {
        (lifecycleEvents, continuation) = AsyncStream.makeStream()
    }

    func openTab(command: String, workingDirectory: String?, from origin: LeoWindowID) throws -> AttachmentHandle {
        tabCalls.append((command, workingDirectory, origin))
        return try opened()
    }

    func openWindow(command: String, workingDirectory: String?) throws -> AttachmentHandle {
        windowCalls.append((command, workingDirectory))
        return try opened()
    }

    func focus(_ handle: AttachmentHandle) { focused.append(handle) }
    func isOpen(_ handle: AttachmentHandle) -> Bool { openHandles.contains(handle) }
    func setTitleSeed(_ handle: AttachmentHandle, title: String?) { titles.append((handle, title)) }
    func emit(_ event: AttachLifecycleEvent) { continuation.yield(event) }

    private func opened() throws -> AttachmentHandle {
        if let openError { throw openError }
        let handle = AttachmentHandle(surfaceID: UUID(), windowID: LeoWindowID())
        handles.append(handle)
        openHandles.insert(handle)
        return handle
    }
}

private enum FakeError: Error { case failed }

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
