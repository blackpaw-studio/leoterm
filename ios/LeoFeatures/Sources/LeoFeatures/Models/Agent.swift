import Foundation
import LeoKit

/// Names one agent across every paired daemon.
public struct AgentRef: Hashable, Sendable {
    public let daemonID: String
    public let name: String

    public init(daemonID: String, name: String) {
        self.daemonID = daemonID
        self.name = name
    }
}

/// One agent as the app shows it, merged from `/state` and the event stream.
public struct Agent: Equatable, Identifiable, Sendable {
    public var name: String
    public var status: LeoAgentStatus?
    public var activity: LeoActivity?
    public var currentAction: LeoCurrentAction?
    public var attention: LeoAttentionSignal?
    public var template: String?
    public var harness: String?
    public var environments: LeoAgentEnvironments?
    public var startedAt: String?

    public var id: String { name }

    public init(
        name: String, status: LeoAgentStatus? = nil, activity: LeoActivity? = nil, currentAction: LeoCurrentAction? = nil,
        attention: LeoAttentionSignal? = nil, template: String? = nil, harness: String? = nil,
        environments: LeoAgentEnvironments? = nil, startedAt: String? = nil
    ) {
        self.name = name
        self.status = status
        self.activity = activity
        self.currentAction = currentAction
        self.attention = attention
        self.template = template
        self.harness = harness
        self.environments = environments
        self.startedAt = startedAt
    }

    public init(_ observed: LeoObservedAgent) {
        self.init(
            name: observed.name, status: observed.status, activity: observed.activity, currentAction: observed.currentAction,
            attention: observed.attention, template: observed.template, harness: observed.harness,
            environments: observed.environments, startedAt: observed.startedAt
        )
    }

    /// Only Claude agents hand their conversation to the Claude app.
    public var opensInClaude: Bool { harness?.lowercased() == "claude" }

    public var isStopped: Bool { status == .stopped }

    public var priority: AgentPriority {
        if isStopped { return .stopped }
        switch attention?.state {
        case .needsInput: return .needsInput
        case .errored: return .errored
        case .finished: return .finished
        case .working: return .working
        case .unknown, nil: return activity == .working ? .working : .idle
        }
    }

    /// Adopts `signal` unless it is a duplicate or reorder: revisions only
    /// move forward per agent.
    mutating func adopt(_ signal: LeoAttentionSignal?) {
        guard let signal else { return }
        if let current = attention, current.revision >= signal.revision { return }
        attention = signal
    }
}

/// Sort order of agents: whatever needs the user first, stopped last.
public enum AgentPriority: Int, Comparable, Sendable {
    case needsInput, errored, finished, working, idle, stopped

    public var needsAttention: Bool { self < .working }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
