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
    var contentCalls: [FakeOpenCall] = []
    var windowCalls: [FakeOpenCall] = []
    var splitCalls: [FakeOpenCall] = []
    var placeholderCalls: [FakeOpenCall] = []
    var placeholderSurfaceIDs: [UUID?] = []
    var focused: [AttachmentHandle] = []
    var agentNames: [(AttachmentHandle, String)] = []
    var handles: [AttachmentHandle] = []
    var openHandles: Set<AttachmentHandle> = []
    var focusedHandle: AttachmentHandle?
    /// Follows `focusedHandle` (an attachment with keyboard focus is
    /// viewed) until set.
    var viewedHandle: AttachmentHandle? {
        get { viewedHandleOverride ?? focusedHandle }
        set { viewedHandleOverride = .some(newValue) }
    }
    private var viewedHandleOverride: AttachmentHandle??
    private(set) var focusReportCount = 0
    private let continuation: AsyncStream<AttachLifecycleEvent>.Continuation
    private var lifecycleAcknowledgement: CheckedContinuation<Void, Never>?
    private var awaitedEvent: AttachLifecycleEvent?
    let lifecycleEvents: AsyncStream<AttachLifecycleEvent>

    init() {
        (lifecycleEvents, continuation) = AsyncStream.makeStream()
    }

    /// Handles open in each window's content area, by window (B-055).
    private(set) var shownInContent: [LeoWindowID: AttachmentHandle] = [:]

    /// Replaces what `origin` showed: its previous handle closes, as the
    /// real host's tree observer reports once the surface is gone.
    func showInContent(command: String, workingDirectory: String?, origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle {
        contentCalls.append(FakeOpenCall(command: command, workingDirectory: workingDirectory, origin: origin, requestID: requestID))
        let handle = try opened(in: origin)
        if let displaced = shownInContent.updateValue(handle, forKey: origin) { openHandles.remove(displaced) }
        return handle
    }

    /// What `confirmReplacingContent` answers, and who asked.
    var confirmsReplacement = true
    var replacementConfirmations: [LeoWindowID] = []
    func confirmReplacingContent(origin: LeoWindowID) async -> Bool {
        replacementConfirmations.append(origin)
        return confirmsReplacement
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
        return try opened(in: origin)
    }

    func fillPlaceholder(command: String, workingDirectory: String?, origin: LeoWindowID, surfaceID: UUID?, requestID: UUID) throws -> AttachmentHandle {
        placeholderCalls.append(FakeOpenCall(command: command, workingDirectory: workingDirectory, origin: origin, requestID: requestID))
        placeholderSurfaceIDs.append(surfaceID)
        return try opened(in: origin)
    }

    var reborn: [AttachmentHandle] = []
    func rebirthPlaceholder(for handle: AttachmentHandle) { reborn.append(handle) }

    var discardedPlaceholders: [LeoWindowID] = []
    func discardEmptyPlaceholder(origin: LeoWindowID) { discardedPlaceholders.append(origin) }

    func focus(_ handle: AttachmentHandle) { focused.append(handle) }
    func isOpen(_ handle: AttachmentHandle) -> Bool { openHandles.contains(handle) }
    func setAgentName(_ handle: AttachmentHandle, name: String) { agentNames.append((handle, name)) }
    /// Yields `event` without waiting for the coordinator to receive it --
    /// an event still in flight.
    func emit(_ event: AttachLifecycleEvent) {
        switch event {
        case .focusChanged, .viewingChanged, .focusSuspended: focusReportCount += 1
        default: break
        }
        continuation.yield(event)
    }

    func emitAndWait(_ event: AttachLifecycleEvent) async {
        await withCheckedContinuation { acknowledgement in
            lifecycleAcknowledgement = acknowledgement
            awaitedEvent = event
            emit(event)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let acknowledgement = self.lifecycleAcknowledgement else { return }
                self.lifecycleAcknowledgement = nil
                Issue.record("Lifecycle event was not delivered within 1.0 seconds")
                acknowledgement.resume()
            }
        }
    }

    /// Resumes `emitAndWait` once its own event is handled; an earlier
    /// in-flight event (see `emit`) being handled first doesn't count.
    func acknowledge(_ event: AttachLifecycleEvent) {
        guard lifecycleAcknowledgement != nil, event == awaitedEvent else { return }
        lifecycleAcknowledgement?.resume()
        lifecycleAcknowledgement = nil
    }

    private func opened(in window: LeoWindowID = LeoWindowID()) throws -> AttachmentHandle {
        if let openError { throw openError }
        let handle = AttachmentHandle(surfaceID: UUID(), windowID: window)
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
