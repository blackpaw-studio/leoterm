import Foundation

/// The live holder of an agent browser's `LeoBrowserControl`: the one place
/// user input, the pill, the handoff banner and the executor all report to.
/// Observers (pane, badge, banner) get each change; `requestHandoff` suspends
/// the agent's `browser_handoff` call until the user answers.
@MainActor
public final class LeoBrowserControlModel {
    public private(set) var state: LeoBrowserControl = .initial
    private var observers: [UUID: (LeoBrowserControl) -> Void] = [:]
    private var handoffWaiters: [String: CheckedContinuation<LeoBrowserControl.HandoffOutcome?, Never>] = [:]

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
            handoffWaiters.removeValue(forKey: requestID)?.resume(returning: outcome)
        }
        if case .cancelled(let requestID) = event {
            handoffWaiters.removeValue(forKey: requestID)?.resume(returning: nil)
        }
        if changed { observers.values.forEach { $0(state) } }
    }

    /// Shows the handoff and waits for Done or Decline. Returns nil when the
    /// call is cancelled first (the banner is dismissed and the user keeps control).
    public func requestHandoff(requestID: String, message: String) async -> LeoBrowserControl.HandoffOutcome? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                handoffWaiters[requestID] = continuation
                send(.handoff(requestID: requestID, message: message))
            }
        } onCancel: {
            Task { @MainActor in self.send(.cancelled(requestID: requestID)) }
        }
    }
}
