import Foundation

/// The daemon's semantic attention state for one agent (the optional
/// `attention.state` field on `agent_activity` events, `/state` agents and
/// spawned-agent payloads). Unlike `LeoActivity` (terminal output seen /
/// quiet), these are reported by the agent harness itself -- the app never
/// derives one from output, idleness or `current_action` text.
enum LeoAttentionState: String, Equatable, Sendable, Codable {
    case working
    case needsInput = "needs_input"
    case finished
    case errored
    case unknown

    /// An unrecognized value from a newer daemon clears rather than fails
    /// the whole payload: `unknown` is the one state that never shows a
    /// badge, so it cannot invent anything.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LeoAttentionState(rawValue: raw) ?? .unknown
    }

    /// "Needing attention" per the spec: the user has something to do.
    var needsAttention: Bool {
        switch self {
        case .needsInput, .finished, .errored: true
        case .working, .unknown: false
        }
    }
}

/// `attention: {state, revision}`. `revision` increases per agent name per
/// daemon boot, across delete/recreate and rename; a signal at or below one
/// already seen for that name is a duplicate/reorder.
struct LeoAttentionSignal: Equatable, Sendable, Codable {
    let state: LeoAttentionState
    let revision: Int
}

/// What an agent row shows. `unknown` has no badge, so it isn't a case.
enum LeoAttentionBadge: Equatable, Sendable {
    case working, needsInput, finished, errored

    init?(_ state: LeoAttentionState) {
        switch state {
        case .working: self = .working
        case .needsInput: self = .needsInput
        case .finished: self = .finished
        case .errored: self = .errored
        case .unknown: return nil
        }
    }

    var needsAttention: Bool { self != .working }
}

/// A committed *live* change of an agent's attention state, emitted by
/// `LeoAttentionReducer.tick(now:)`. Baselines never produce one.
struct LeoAttentionTransition: Equatable, Sendable {
    let id: LeoAgentRow.ID
    let from: LeoAttentionState?
    let to: LeoAttentionState
    let revision: Int
    /// True for a transition into needs_input/finished while no attachment
    /// of that agent is focused. Suppressed transitions are consumed, never
    /// deferred.
    let shouldNotify: Bool
    let bootID: String?

    init(
        id: LeoAgentRow.ID, from: LeoAttentionState?, to: LeoAttentionState, revision: Int, shouldNotify: Bool,
        bootID: String? = nil
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.revision = revision
        self.shouldNotify = shouldNotify
        self.bootID = bootID
    }
}
