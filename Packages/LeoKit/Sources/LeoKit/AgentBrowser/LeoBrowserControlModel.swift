import Foundation

/// The live holder of an agent browser's `LeoBrowserControl`: the one place
/// user input, the pill, the handoff banner and the executor all report to.
/// Observers (pane, badge, banner) get each change; `requestHandoff` suspends
/// the agent's `browser_handoff` call until the user answers.
@MainActor
public final class LeoBrowserControlModel {
    public private(set) var state: LeoBrowserControl = .initial
    private var observers: [UUID: (LeoBrowserControl) -> Void] = [:]
    private typealias HandoffWaiter = (id: UUID, continuation: CheckedContinuation<LeoBrowserControl.HandoffOutcome?, Never>)
    /// Every call waiting on a request id: a re-delivered `browser_handoff` (after a
    /// gap or reconnect) joins the first instead of replacing it.
    private var handoffWaiters: [String: [HandoffWaiter]] = [:]

    public init() {}

    /// Calls `handler` after every change of state; the returned closure removes it.
    public func observe(_ handler: @escaping (LeoBrowserControl) -> Void) -> () -> Void {
        let id = UUID()
        observers[id] = handler
        return { [weak self] in self?.observers[id] = nil }
    }

    public func send(_ event: LeoBrowserControl.Event) {
        let result = state.applying(event)
        let changed = result.state != state
        state = result.state
        if case .settle(let requestID, let outcome) = result.effect {
            resumeWaiters(of: requestID, with: outcome)
        }
        if case .cancelled(let requestID) = event {
            resumeWaiters(of: requestID, with: nil)
        }
        if changed { observers.values.forEach { $0(state) } }
    }

    /// Shows the handoff and waits for Done or Decline. Returns nil when the
    /// call is cancelled first. The banner is dismissed, and the user keeps
    /// control, once no call is left waiting on it. A second call for a request
    /// already waiting joins it and gets the same answer.
    public func requestHandoff(requestID: String, message: String) async -> LeoBrowserControl.HandoffOutcome? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let isFirst = handoffWaiters[requestID] == nil
                handoffWaiters[requestID, default: []].append((id, continuation))
                if isFirst { send(.handoff(requestID: requestID, message: message)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id, of: requestID) }
        }
    }

    private func resumeWaiters(of requestID: String, with outcome: LeoBrowserControl.HandoffOutcome?) {
        handoffWaiters.removeValue(forKey: requestID)?.forEach { $0.continuation.resume(returning: outcome) }
    }

    private func cancelWaiter(_ id: UUID, of requestID: String) {
        guard var waiters = handoffWaiters[requestID], let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        handoffWaiters[requestID] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(returning: nil)
        if waiters.isEmpty { send(.cancelled(requestID: requestID)) }
    }
}
