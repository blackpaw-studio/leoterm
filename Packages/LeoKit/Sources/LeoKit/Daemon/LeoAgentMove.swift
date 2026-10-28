import Foundation

/// Wire types for the daemon's agent move/copy job (`agent_move`). A job is
/// started with a `LeoMoveRequest` and described by a `LeoMoveJob`; the same
/// `LeoMoveJob` comes back whichever transport (socket or web) carried it.

public enum LeoMoveMode: String, Codable, Equatable, Sendable {
    case move, copy
}

public struct LeoMoveRequest: Codable, Equatable, Sendable {
    public let mode: LeoMoveMode
    /// A key in the source daemon's `client.hosts`; nil means the agent's own host.
    public let to: String?
    public let force: Bool
    public let name: String?

    public init(mode: LeoMoveMode, to: String? = nil, force: Bool = false, name: String? = nil) {
        self.mode = mode
        self.to = to.flatMap(Self.nonBlank)
        self.force = force
        self.name = name.flatMap(Self.nonBlank)
    }

    public static func move(to host: String, force: Bool = false) -> Self {
        Self(mode: .move, to: host, force: force)
    }

    public static func copy(to host: String, name: String? = nil) -> Self {
        Self(mode: .copy, to: host, name: name)
    }

    /// A copy on the agent's own host.
    public static func duplicate(name: String? = nil) -> Self {
        Self(mode: .copy, name: name)
    }

    /// The same request with the mid-turn check skipped.
    public var forced: Self { Self(mode: mode, to: to, force: true, name: name) }

    enum CodingKeys: String, CodingKey { case mode, to, force, name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decode(LeoMoveMode.self, forKey: .mode),
            to: try container.decodeIfPresent(String.self, forKey: .to),
            force: try container.decodeIfPresent(Bool.self, forKey: .force) ?? false,
            name: try container.decodeIfPresent(String.self, forKey: .name)
        )
    }

    /// Leaves out `to`, `name` and `force` when empty: the daemon reads a
    /// missing `to` as the source host.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(to, forKey: .to)
        if force { try container.encode(true, forKey: .force) }
        try container.encodeIfPresent(name, forKey: .name)
    }

    private static func nonBlank(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}

public enum LeoMoveState: Decodable, Equatable, Sendable {
    case running, done, failed
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "running": self = .running
        case "done": self = .done
        case "failed": self = .failed
        default: self = .unknown(raw)
        }
    }
}

/// One refusal: a stable `code` and the daemon's own text.
public struct LeoMoveProblem: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct LeoMoveResult: Decodable, Equatable, Sendable {
    public let name: String
    public let host: String?
    public let to: String?
    public let workspace: String?
    public let branch: String?
}

public struct LeoMoveJob: Decodable, Equatable, Sendable {
    public static let busyCode = "agent_busy"

    public let id: String
    public let request: LeoMoveRequest
    public let state: LeoMoveState
    public let error: LeoMoveProblem?
    public let problems: [LeoMoveProblem]
    public let result: LeoMoveResult?
    public let startedAt: String?
    public let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, request, state, error, problems, result
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        request = try container.decode(LeoMoveRequest.self, forKey: .request)
        state = try container.decode(LeoMoveState.self, forKey: .state)
        error = try container.decodeIfPresent(LeoMoveProblem.self, forKey: .error)
        problems = try container.decodeIfPresent([LeoMoveProblem].self, forKey: .problems) ?? []
        result = try container.decodeIfPresent(LeoMoveResult.self, forKey: .result)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(String.self, forKey: .finishedAt)
    }

    /// Force skips the mid-turn check of a move. A copy's `agent_busy`
    /// (Codex/opencode, or a failed probe) is not helped by it.
    public var offersForce: Bool {
        state == .failed && error?.code == Self.busyCode && request.mode == .move
    }
}
