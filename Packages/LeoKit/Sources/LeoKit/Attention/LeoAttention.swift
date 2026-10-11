import Foundation

/// The daemon's semantic attention state for one agent (the optional
/// `attention.state` field on `agent_activity` events, `/state` agents and
/// spawned-agent payloads). Unlike `LeoActivity` (terminal output seen /
/// quiet), these are reported by the agent harness itself -- the app never
/// derives one from output, idleness or `current_action` text.
public enum LeoAttentionState: String, Equatable, Sendable, Codable {
    case working
    case needsInput = "needs_input"
    case finished
    case errored
    case unknown

    /// An unrecognized value from a newer daemon clears rather than fails
    /// the whole payload: `unknown` is the one state that never shows a
    /// badge, so it cannot invent anything.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LeoAttentionState(rawValue: raw) ?? .unknown
    }

    /// "Needing attention" per the spec: the user has something to do.
    public var needsAttention: Bool {
        switch self {
        case .needsInput, .finished, .errored: true
        case .working, .unknown: false
        }
    }
}

/// Why an agent needs input (`attention.reason`, daemon contract v0.35.0):
/// a permission prompt, a question, or an MCP elicitation. Informational
/// only -- the app never answers the prompt. `tool` and `detail` are
/// agent-controlled text: sanitized and clamped on decode.
public struct LeoAttentionReason: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case permission, question, elicitation
    }

    /// The most characters kept of `tool` or `detail`.
    public static let textLimit = 120

    public let kind: Kind
    public let tool: String?
    public let detail: String?

    public init(kind: Kind, tool: String? = nil, detail: String? = nil) {
        self.kind = kind
        self.tool = Self.clean(tool)
        self.detail = Self.clean(detail)
    }

    private enum CodingKeys: String, CodingKey { case kind, tool, detail }

    /// An unknown kind or a wrong-typed field throws; `LeoAttentionSignal`
    /// turns that into "no reason" so the signal itself still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(Kind.self, forKey: .kind),
            tool: try container.decodeIfPresent(String.self, forKey: .tool),
            detail: try container.decodeIfPresent(String.self, forKey: .detail)
        )
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let sanitized = LeoSFTPServerText.sanitized(text)
        guard !sanitized.isEmpty else { return nil }
        guard sanitized.count > textLimit else { return sanitized }
        return String(sanitized.prefix(textLimit - 1)) + "…"
    }
}

/// `attention: {state, revision, reason?}`. `revision` increases per agent
/// name per daemon boot, across delete/recreate and rename; a signal at or
/// below one already seen for that name is a duplicate/reorder.
public struct LeoAttentionSignal: Equatable, Sendable, Codable {
    public let state: LeoAttentionState
    public let revision: Int
    public let reason: LeoAttentionReason?

    public init(state: LeoAttentionState, revision: Int, reason: LeoAttentionReason? = nil) {
        self.state = state
        self.revision = revision
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case state, revision, reason }

    /// A malformed or unknown-kind reason reads as absent: behaviour falls
    /// back to the reasonless one and nothing is invented.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try container.decode(LeoAttentionState.self, forKey: .state),
            revision: try container.decode(Int.self, forKey: .revision),
            reason: try? container.decodeIfPresent(LeoAttentionReason.self, forKey: .reason)
        )
    }
}

/// What an agent row shows. `unknown` has no badge, so it isn't a case.
public enum LeoAttentionBadge: Equatable, Sendable {
    case working, needsInput, finished, errored

    public init?(_ state: LeoAttentionState) {
        switch state {
        case .working: self = .working
        case .needsInput: self = .needsInput
        case .finished: self = .finished
        case .errored: self = .errored
        case .unknown: return nil
        }
    }

    public var needsAttention: Bool { self != .working }
}

/// A committed *live* change of an agent's attention state, emitted by
/// `LeoAttentionReducer.tick(now:)`. Baselines never produce one.
public struct LeoAttentionTransition: Equatable, Sendable {
    public let id: LeoAgentID
    public let from: LeoAttentionState?
    public let to: LeoAttentionState
    public let revision: Int
    /// True for a transition into needs_input/finished while no attachment
    /// of that agent is focused. Suppressed transitions are consumed, never
    /// deferred.
    public let shouldNotify: Bool
    public let bootID: String?
    /// Why the agent needs input, when the daemon said (`to == .needsInput`).
    public let reason: LeoAttentionReason?

    public init(
        id: LeoAgentID, from: LeoAttentionState?, to: LeoAttentionState, revision: Int, shouldNotify: Bool,
        bootID: String? = nil, reason: LeoAttentionReason? = nil
    ) {
        self.reason = reason
        self.id = id
        self.from = from
        self.to = to
        self.revision = revision
        self.shouldNotify = shouldNotify
        self.bootID = bootID
    }
}
