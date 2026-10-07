import Foundation

/// The four operator control verbs on `POST /agents/{name}/<verb>` (B-262).
enum LeoControlVerb: String, CaseIterable, Sendable {
    case message, interrupt, compact, clear
}

/// How the daemon took a message: handed to the agent now, or queued for
/// when it can (a 202).
enum LeoMessageDelivery: Equatable, Sendable {
    case delivered(transport: String?)
    case queued
}

/// What the control bar and Agents-menu items may do for one selected row
/// (B-262). Pure: the daemon must advertise `agent_control` (never invent a
/// capability), the host must not have refused the token, and the agent
/// must be running; a stopped agent that wakes on message may still be sent
/// to. One action at a time (`canCompose` ignores that: the field stays
/// editable while a send is out).
struct LeoAgentControlAvailability: Equatable, Sendable {
    /// Whether the bar shows at all: an agent row on a daemon with control.
    let isOffered: Bool
    /// Whether the prompt field accepts typing.
    let canCompose: Bool
    let canSend: Bool
    let canInterrupt: Bool
    let canCompact: Bool
    let canClear: Bool
    /// Why the controls are off, when there's something to say.
    let reason: String?

    /// Short, for the field's placeholder.
    static let deniedReason = "Operator access required"
    /// Full, for the banner.
    static let deniedMessage = "This host's token can't control agents (operator access required)."

    init(row: LeoAgentRow?, features: LeoDaemonFeatures, deniedHosts: Set<LeoHostID>, inFlight: LeoControlVerb?) {
        guard let row, features.contains(.agentControl) else {
            self = .off(isOffered: false, reason: nil)
            return
        }
        if deniedHosts.contains(row.host) {
            self = .off(isOffered: true, reason: Self.deniedReason)
            return
        }
        let idle = inFlight == nil
        switch row.status {
        case .running:
            self.init(isOffered: true, canCompose: true, canSend: idle, canInterrupt: idle, canCompact: idle, canClear: idle, reason: nil)
        case .stopped where row.wakeOnMessage == true:
            self.init(isOffered: true, canCompose: true, canSend: idle, canInterrupt: false, canCompact: false, canClear: false, reason: nil)
        case .starting:
            self = .off(isOffered: true, reason: "\(row.name) is starting.")
        case .stopped, .unknown:
            self = .off(isOffered: true, reason: "\(row.name) isn't running.")
        }
    }

    private init(isOffered: Bool, canCompose: Bool, canSend: Bool, canInterrupt: Bool, canCompact: Bool, canClear: Bool, reason: String?) {
        self.isOffered = isOffered
        self.canCompose = canCompose
        self.canSend = canSend
        self.canInterrupt = canInterrupt
        self.canCompact = canCompact
        self.canClear = canClear
        self.reason = reason
    }

    private static func off(isOffered: Bool, reason: String?) -> Self {
        Self(isOffered: isOffered, canCompose: false, canSend: false, canInterrupt: false, canCompact: false, canClear: false, reason: reason)
    }
}
