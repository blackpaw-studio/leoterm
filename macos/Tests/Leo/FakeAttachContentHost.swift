import Foundation
import Testing

@testable import Ghostty

/// One recorded `AttachContentHost` open call; fields a given entry point
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

@MainActor final class FakeAttachContentHost: AttachContentHost {
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
    /// Each window's live pool (B-056), with the real policy: an agent
    /// shown (one named by `setAgentName`) is hidden when replaced, and
    /// the least recently viewed is let go beyond capacity.
    private(set) var pools: [LeoWindowID: LeoLivePool<AttachmentHandle>] = [:]
    /// What `reveal` showed again, and what the pool let go (evicted or
    /// released), in order.
    private(set) var revealed: [AttachmentHandle] = []
    private(set) var letGo: [AttachmentHandle] = []

    /// Each window's terminal rows' shells hidden for the row's life
    /// (B-057, D-111), beside the pool.
    private(set) var keptShells: [LeoWindowID: [AttachmentHandle]] = [:]
    /// Plain shells shown in a content area: terminal rows.
    private(set) var terminalRows: Set<AttachmentHandle> = []

    /// Replaces what `origin` showed: an agent is hidden in the window's
    /// pool, a terminal row's shell is kept hidden, anything else closes
    /// (as the real host reports once its surface is gone).
    func showInContent(command: String, workingDirectory: String?, origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle {
        contentCalls.append(FakeOpenCall(command: command, workingDirectory: workingDirectory, origin: origin, requestID: requestID))
        let handle = try opened(in: origin)
        if command.isEmpty { terminalRows.insert(handle) }
        show(handle, in: origin, clients: command.isEmpty ? 0 : 1)
        return handle
    }

    func isShown(_ handle: AttachmentHandle) -> Bool { openHandles.contains(handle) && !isHidden(handle) }

    /// Makes `reveal` answer `false`, as the real host does when it let
    /// the hidden surface go meanwhile.
    var refusesReveal = false
    func reveal(_ handle: AttachmentHandle) -> Bool {
        guard !refusesReveal else { return false }
        if keptShells[handle.windowID]?.contains(handle) == true {
            keptShells[handle.windowID]?.removeAll { $0 == handle }
            revealed.append(handle)
            show(handle, in: handle.windowID, clients: 0)
            return true
        }
        guard let pool = pools[handle.windowID], case let (remaining, taken?) = pool.taking(where: { $0 == handle }) else { return false }
        pools[handle.windowID] = remaining
        revealed.append(taken)
        show(taken, in: handle.windowID, clients: 1)
        return true
    }

    /// Handles that share a pooled split tree with a given hidden handle
    /// (set by a test): `release` lets go of the whole tree, as the real
    /// host does, `releasePooledSurface` of one surface only.
    var pooledSplitMates: [AttachmentHandle: [AttachmentHandle]] = [:]

    func release(_ handle: AttachmentHandle) {
        guard let pool = pools[handle.windowID] else { return }
        let (remaining, removed) = pool.removing { $0 == handle }
        pools[handle.windowID] = remaining
        removed.forEach(drop)
        guard !removed.isEmpty else { return }
        (pooledSplitMates[handle] ?? []).forEach(drop)
    }

    private(set) var releasedPooledSurfaces: [AttachmentHandle] = []
    func releasePooledSurface(_ handle: AttachmentHandle) {
        releasedPooledSurfaces.append(handle)
        guard let pool = pools[handle.windowID] else { return }
        let (remaining, removed) = pool.removing { $0 == handle }
        pools[handle.windowID] = remaining
        removed.forEach(drop)
    }

    /// Every `closeTerminal` call. As the real host does, a shown or
    /// hidden row's shell is let go (the window then shows nothing here,
    /// rather than a neighbour) and reported closed; a gone one is left be.
    var closedTerminals: [AttachmentHandle] = []
    /// As the real host does: a surface hidden in the live pool is the
    /// pool's, so `closeTerminal` leaves it (only `release` lets it go).
    var closeTerminalLeavesPooledSurfaces = false
    func closeTerminal(_ handle: AttachmentHandle) {
        closedTerminals.append(handle)
        if closeTerminalLeavesPooledSurfaces, pools[handle.windowID]?.entries.contains(handle) == true { return }
        keptShells[handle.windowID]?.removeAll { $0 == handle }
        if shownInContent[handle.windowID] == handle { shownInContent[handle.windowID] = nil }
        terminalRows.remove(handle)
        guard openHandles.remove(handle) != nil else { return }
        emit(.closed(handle))
    }

    /// Every window whose sidebar was told to select what it shows again.
    private(set) var reselectedWindows: [LeoWindowID] = []
    func selectShownTerminal(in window: LeoWindowID) {
        reselectedWindows.append(window)
    }

    /// The window's pool holds `handle` hidden.
    func isHidden(_ handle: AttachmentHandle) -> Bool {
        (pools[handle.windowID]?.entries.contains(handle) ?? false) || (keptShells[handle.windowID]?.contains(handle) ?? false)
    }

    private func show(_ handle: AttachmentHandle, in window: LeoWindowID, clients: Int) {
        var pool = pools[window] ?? LeoLivePool()
        if let displaced = shownInContent.updateValue(handle, forKey: window) {
            if isAgent(displaced) {
                pool = pool.hiding(displaced)
            } else if terminalRows.contains(displaced) {
                keptShells[window, default: []].append(displaced)
            } else {
                openHandles.remove(displaced)
            }
        }
        let (trimmed, evicted) = pool.trimmed(shownClients: clients) { [openHandles] in openHandles.contains($0) ? 1 : 0 }
        pools[window] = trimmed
        evicted.forEach(drop)
    }

    private func isAgent(_ handle: AttachmentHandle) -> Bool { agentNames.contains { $0.0 == handle } }

    /// Let go by the pool: the surface goes, and the host reports it closed.
    private func drop(_ handle: AttachmentHandle) {
        guard openHandles.remove(handle) != nil else { return }
        letGo.append(handle)
        emit(.closed(handle))
    }

    /// What `confirmReplacingContent` answers, and who asked.
    var confirmsReplacement = true
    var replacementConfirmations: [LeoWindowID] = []
    func confirmReplacingContent(origin: LeoWindowID) async -> Bool {
        replacementConfirmations.append(origin)
        guard heldConfirmations > 0 else { return confirmsReplacement }
        heldConfirmations -= 1
        return await withCheckedContinuation { pendingConfirmations.append($0) }
    }

    /// How many of the next confirmations suspend (as the real alert does)
    /// until `resumeConfirmation` answers them, oldest first.
    var heldConfirmations = 0
    private var pendingConfirmations: [CheckedContinuation<Bool, Never>] = []
    var pendingConfirmationCount: Int { pendingConfirmations.count }

    func resumeConfirmation(_ answer: Bool) {
        guard !pendingConfirmations.isEmpty else { return }
        pendingConfirmations.removeFirst().resume(returning: answer)
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
    var watching: [AttachmentHandle] = []
    func markWatchingDispatch(_ handle: AttachmentHandle) { watching.append(handle) }
    var exitReports: [AttachmentHandle: AttachExitReport] = [:]
    func exitReport(for handle: AttachmentHandle) -> AttachExitReport? { exitReports[handle] }
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
