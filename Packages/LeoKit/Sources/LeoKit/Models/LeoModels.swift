import Foundation

public enum LeoAgentStatus: Codable, Equatable, Sendable {
    case starting
    case running
    case stopped
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "starting": self = .starting
        case "running": self = .running
        case "stopped": self = .stopped
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let value: String
        switch self {
        case .starting: value = "starting"
        case .running: value = "running"
        case .stopped: value = "stopped"
        case .unknown(let raw): value = raw
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct LeoAgent: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let template: String?
    public let repo: String?
    public let workspace: String?
    public let branch: String?
    public let canonicalPath: String?
    public let status: LeoAgentStatus?
    public let startedAt: String?
    public let restarts: Int?
    public let stoppedReason: String?
    public let wakeOnMessage: Bool?

    public var id: String { name }

    public init(
        name: String, template: String? = nil, repo: String? = nil, workspace: String? = nil, branch: String? = nil,
        canonicalPath: String? = nil, status: LeoAgentStatus? = nil, startedAt: String? = nil, restarts: Int? = nil,
        stoppedReason: String? = nil, wakeOnMessage: Bool? = nil
    ) {
        self.name = name
        self.template = template
        self.repo = repo
        self.workspace = workspace
        self.branch = branch
        self.canonicalPath = canonicalPath
        self.status = status
        self.startedAt = startedAt
        self.restarts = restarts
        self.stoppedReason = stoppedReason
        self.wakeOnMessage = wakeOnMessage
    }

    enum CodingKeys: String, CodingKey {
        case name, template, repo, workspace, branch, status, restarts
        case canonicalPath = "canonical_path"
        case startedAt = "started_at"
        case stoppedReason = "stopped_reason"
        case wakeOnMessage = "wake_on_message"
    }
}

public struct LeoTemplate: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let model: String?
    public let agent: String?
    public let workspace: String?
    public var id: String { name }

    public init(name: String, model: String? = nil, agent: String? = nil, workspace: String? = nil) {
        self.name = name
        self.model = model
        self.agent = agent
        self.workspace = workspace
    }
}

public struct LeoForwardInfo: Codable, Equatable, Sendable {
    public let socket: String
    public let host: String
    public let pid: Int
}

public struct LeoDeletePlan: Codable, Equatable, Sendable {
    public let name: String
    public let hasWorktree: Bool
    public let branch: String?
    public let worktreePath: String?

    enum CodingKeys: String, CodingKey {
        case name, branch
        case hasWorktree = "has_worktree"
        case worktreePath = "worktree_path"
    }
}

public struct LeoDaemonEnvelope<T: Decodable>: Decodable, Sendable where T: Sendable {
    public let ok: Bool
    public let data: T?
    public let error: String?
    public let code: String?
    public let matches: [String]?

    public static func decode(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw LeoDaemonError.decoding(String(describing: error))
        }
    }

    public func value() throws -> T {
        guard ok else {
            throw LeoDaemonError.daemon(
                code: code,
                message: error ?? "Unknown daemon error",
                matches: matches ?? []
            )
        }
        guard let data else { throw LeoDaemonError.decoding("Successful response has no data") }
        return data
    }

    public func expectOK() throws {
        guard ok else {
            throw LeoDaemonError.daemon(
                code: code,
                message: error ?? "Unknown daemon error",
                matches: matches ?? []
            )
        }
    }
}

public enum LeoDaemonError: Error, Equatable, Sendable {
    case daemon(code: String?, message: String, matches: [String])
    case transport(String)
    case timeout
    case decoding(String)
    case socketMissing(path: String)
    case hostUnavailable(String)
    case hostUnknown(String)
    /// The daemon redirected to another origin; refused so the device token
    /// and Access credentials never leave the paired origin.
    case crossOriginRedirect(String)
}

extension LeoDaemonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .daemon(_, let message, _): return message
        case .transport(let message): return "Connection to the Leo daemon failed: \(message)"
        case .timeout: return "The Leo daemon did not respond in time"
        case .decoding(let message): return "Could not understand the Leo daemon's response: \(message)"
        case .socketMissing(let path): return "The Leo daemon socket is missing at \(path)"
        case .hostUnavailable(let message): return "The remote host is unavailable: \(message)"
        case .hostUnknown(let message): return "The remote host is unknown: \(message)"
        case .crossOriginRedirect(let target): return "The Leo daemon redirected to \(target), a different origin. Leo doesn't follow it, so your credentials stay with the paired daemon."
        }
    }
}

public struct LeoSpawnRequest: Codable, Equatable, Sendable {
    public let template: String?
    public let fromAgent: String?
    public let repo: String?
    public let name: String?
    public let branch: String?
    public let base: String?
    public let prompt: String?
    public let environment: [String: String]?
    public let idleSuspend: Bool?
    /// B-283: the ordered named environments; nil sends none. Left out of
    /// `CodingKeys`: `LeoEnvironmentsWire.spawnBody` adds it (a `var` only
    /// so decoding can default it).
    public private(set) var environments: [String]?

    public init(template: String? = nil, fromAgent: String? = nil, repo: String? = nil,
                name: String? = nil, branch: String? = nil, base: String? = nil,
                prompt: String? = nil, environment: [String: String]? = nil,
                idleSuspend: Bool? = nil, environments: [String]? = nil) {
        self.template = template
        self.fromAgent = fromAgent
        self.repo = repo
        self.name = name
        self.branch = branch
        self.base = base
        self.prompt = prompt
        self.environment = environment
        self.idleSuspend = idleSuspend
        self.environments = environments
    }

    enum CodingKeys: String, CodingKey {
        case template, repo, name, branch, base, prompt
        case fromAgent = "from_agent"
        case environment = "env"
        case idleSuspend = "idle_suspend"
    }
}
