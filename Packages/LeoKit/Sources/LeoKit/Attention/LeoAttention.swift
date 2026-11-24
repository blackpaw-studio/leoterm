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

    /// The most characters kept of `input`.
    public static let inputLimit = 500

    public let kind: Kind
    public let tool: String?
    public let detail: String?
    /// The full command of a permission prompt (a single line, clamped to
    /// `inputLimit`); permission reasons only, and absent from older
    /// daemons. Prefer it over `detail` when showing the prompt.
    public let input: String?

    public init(kind: Kind, tool: String? = nil, detail: String? = nil, input: String? = nil) {
        self.kind = kind
        self.tool = Self.clean(tool)
        self.detail = Self.clean(detail)
        self.input = kind == .permission ? Self.cleanCommand(input) : nil
    }

    private enum CodingKeys: String, CodingKey { case kind, tool, detail, input }

    /// An unknown kind or a wrong-typed field throws; `LeoAttentionSignal`
    /// turns that into "no reason" so the signal itself still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(Kind.self, forKey: .kind),
            tool: try container.decodeIfPresent(String.self, forKey: .tool),
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
            input: (try? container.decodeIfPresent(String.self, forKey: .input)) ?? nil
        )
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let sanitized = LeoSFTPServerText.sanitized(text)
        guard !sanitized.isEmpty else { return nil }
        guard sanitized.count > textLimit else { return sanitized }
        return String(sanitized.prefix(textLimit - 1)) + "…"
    }

    /// One line, nothing invisible, clamped to `inputLimit`; unlike `clean`
    /// it keeps quotes as sent, since it shows a shell command verbatim.
    private static func cleanCommand(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = LeoSFTPServerText.appText(text).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        guard line.count > inputLimit else { return line }
        return String(line.prefix(inputLimit - 1)) + "…"
    }
}

/// `attention: {state, revision, reason?, preview?, at?}`. `revision` increases
/// per agent name per daemon boot, across delete/recreate and rename; a signal
/// at or below one already seen for that name is a duplicate/reorder.
public struct LeoAttentionSignal: Equatable, Sendable, Codable {
    /// The most characters kept of `preview`.
    public static let previewLimit = 200

    public let state: LeoAttentionState
    public let revision: Int
    public let reason: LeoAttentionReason?
    /// The one-line result of a finished turn, or an error summary for an
    /// errored one. Agent-controlled: sanitized and clamped.
    public let preview: String?
    /// When the daemon recorded this signal (its clock); nil from a daemon
    /// that doesn't send it or when the value doesn't parse.
    public let at: Date?

    public init(
        state: LeoAttentionState, revision: Int, reason: LeoAttentionReason? = nil, preview: String? = nil, at: Date? = nil
    ) {
        self.state = state
        self.revision = revision
        self.reason = reason
        self.preview = Self.cleanPreview(preview)
        self.at = at
    }

    private enum CodingKeys: String, CodingKey { case state, revision, reason, preview, at }

    /// A malformed or unknown-kind reason, a wrong-typed preview and an
    /// unreadable `at` read as absent: behaviour falls back to the plainer
    /// signal and nothing is invented.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try container.decode(LeoAttentionState.self, forKey: .state),
            revision: try container.decode(Int.self, forKey: .revision),
            reason: try? container.decodeIfPresent(LeoAttentionReason.self, forKey: .reason),
            preview: (try? container.decodeIfPresent(String.self, forKey: .preview)) ?? nil,
            at: ((try? container.decodeIfPresent(String.self, forKey: .at)) ?? nil).flatMap(LeoChatTimestamp.parse)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(at.map { $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)) }, forKey: .at)
    }

    private static func cleanPreview(_ text: String?) -> String? {
        guard let text else { return nil }
        let sanitized = LeoSFTPServerText.sanitized(text)
        guard !sanitized.isEmpty else { return nil }
        guard sanitized.count > previewLimit else { return sanitized }
        return String(sanitized.prefix(previewLimit - 1)) + "…"
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
