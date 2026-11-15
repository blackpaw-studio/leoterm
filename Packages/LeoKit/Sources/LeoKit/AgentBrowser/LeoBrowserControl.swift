import Foundation

/// Who is driving an agent's browser. Pure state: the UI reads it, the
/// executor gates page-changing actions on it, and every change goes through
/// `applying(_:)`, which also says what the caller must do (settle a handoff).
public enum LeoBrowserControl: Equatable, Sendable {
    /// The agent drives; the user only watches.
    case agent
    /// The user took over; page-changing agent actions fail with `user_has_control`.
    case user
    /// The agent asked the user to take over and is blocked on `browser_handoff`;
    /// the UI shows a banner with Done / Decline.
    case handoff(requestID: String, message: String)

    public static let initial = LeoBrowserControl.agent

    public enum Event: Equatable, Sendable {
        /// Mouse, scroll or key input from the user in a web view or the URL bar.
        case userInput
        /// The user clicked the control pill.
        case pill
        /// The user pressed Give back.
        case giveBack
        /// The agent called `browser_handoff`.
        case handoff(requestID: String, message: String)
        case done(requestID: String)
        case decline(requestID: String)
        /// The daemon cancelled the handoff request (timeout, cancel, agent gone).
        case cancelled(requestID: String)
    }

    public enum HandoffOutcome: Equatable, Sendable {
        case done
        case declined
    }

    /// What the caller must do about a transition.
    public enum Effect: Equatable, Sendable {
        /// Finish the parked `browser_handoff` call with `done` / `declined`.
        case settle(requestID: String, outcome: HandoffOutcome)
    }

    public func applying(_ event: Event) -> (state: LeoBrowserControl, effect: Effect?) {
        switch (self, event) {
        case (.agent, .userInput), (.agent, .pill), (.user, .userInput), (.user, .pill):
            return (.user, nil)
        case (.user, .giveBack), (.agent, .giveBack):
            return (.agent, nil)
        case (.handoff(let current, _), .handoff(let requestID, let message)):
            return (.handoff(requestID: requestID, message: message), .settle(requestID: current, outcome: .declined))
        case (_, .handoff(let requestID, let message)):
            return (.handoff(requestID: requestID, message: message), nil)
        case (.handoff(let current, _), .done(let requestID)) where current == requestID:
            return (.agent, .settle(requestID: requestID, outcome: .done))
        case (.handoff(let current, _), .decline(let requestID)) where current == requestID:
            return (.agent, .settle(requestID: requestID, outcome: .declined))
        case (.handoff(let current, _), .cancelled(let requestID)) where current == requestID:
            return (.user, nil)
        default:
            return (self, nil)
        }
    }

    public var isAgentDriving: Bool { self == .agent }

    /// Whether page-changing agent actions run. Reads always do.
    public var allowsAgentActions: Bool { isAgentDriving }

    public var pendingHandoff: (requestID: String, message: String)? {
        guard case .handoff(let requestID, let message) = self else { return nil }
        return (requestID, message)
    }
}
