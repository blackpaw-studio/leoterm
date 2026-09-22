import Foundation
import Testing

@testable import Ghostty

/// One recorded `AttachTabHost` open call; fields a given entry point
/// doesn't take stay `nil`.
struct FakeOpenCall {
    let command: String
    let workingDirectory: String?
    let origin: LeoWindowID?
    let sourceSurface: UUID?
    let direction: LeoSplitDirection?
    let requestID: UUID

    init(
        command: String,
        workingDirectory: String?,
        origin: LeoWindowID? = nil,
        sourceSurface: UUID? = nil,
        direction: LeoSplitDirection? = nil,
        requestID: UUID
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.origin = origin
        self.sourceSurface = sourceSurface
        self.direction = direction
        self.requestID = requestID
    }
}

@MainActor final class FakeAttachTabHost: AttachTabHost {
    var openError: Error?
    var tabCalls: [FakeOpenCall] = []
    var windowCalls: [FakeOpenCall] = []
    var splitCalls: [FakeOpenCall] = []
    var placeholderCalls: [FakeOpenCall] = []
    var placeholderSurfaceIDs: [UUID?] = []
    var focused: [AttachmentHandle] = []
    var titles: [(AttachmentHandle, String?)] = []
    var handles: [AttachmentHandle] = []
    var openHandles: Set<AttachmentHandle> = []
    var focusedHandle: AttachmentHandle?
    private let continuation: AsyncStream<AttachLifecycleEvent>.Continuation
    private var lifecycleAcknowledgement: CheckedContinuation<Void, Never>?
    let lifecycleEvents: AsyncStream<AttachLifecycleEvent>

    init() {
        (lifecycleEvents, continuation) = AsyncStream.makeStream()
    }

    func openTab(command: String, workingDirectory: String?, from origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle {
        tabCalls.append(FakeOpenCall(command: command, workingDirectory: workingDirectory, origin: origin, requestID: requestID))
        return try opened()
    }

    func openWindow(command: String, workingDirectory: String?, requestID: UUID) throws -> AttachmentHandle {
        windowCalls.append(FakeOpenCall(command: command, workingDirectory: workingDirectory, requestID: requestID))
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
        splitCalls.append(FakeOpenCall(
            command: command,
            workingDirectory: workingDirectory,
            origin: origin,
            sourceSurface: sourceSurface,
            direction: direction,
            requestID: requestID
        ))
        return try opened()
    }

    func fillPlaceholder(command: String, workingDirectory: String?, origin: LeoWindowID, surfaceID: UUID?, requestID: UUID) throws -> AttachmentHandle {
        placeholderCalls.append(FakeOpenCall(command: command, workingDirectory: workingDirectory, origin: origin, requestID: requestID))
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

extension AttachLifecycleEvent {
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
