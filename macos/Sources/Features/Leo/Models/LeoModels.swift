import Foundation

enum LeoAgentStatus: Codable, Equatable, Sendable {
    case starting
    case running
    case stopped
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "starting": self = .starting
        case "running": self = .running
        case "stopped": self = .stopped
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
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

struct LeoAgent: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let template: String?
    let repo: String?
    let workspace: String?
    let branch: String?
    let canonicalPath: String?
    let status: LeoAgentStatus?
    let startedAt: String?
    let restarts: Int?
    let stoppedReason: String?
    let wakeOnMessage: Bool?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, template, repo, workspace, branch, status, restarts
        case canonicalPath = "canonical_path"
        case startedAt = "started_at"
        case stoppedReason = "stopped_reason"
        case wakeOnMessage = "wake_on_message"
    }
}

struct LeoTemplate: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let model: String?
    let agent: String?
    let workspace: String?
    var id: String { name }

    init(name: String, model: String? = nil, agent: String? = nil, workspace: String? = nil) {
        self.name = name
        self.model = model
        self.agent = agent
        self.workspace = workspace
    }
}

struct LeoForwardInfo: Codable, Equatable, Sendable {
    let socket: String
    let host: String
    let pid: Int
}

struct LeoDeletePlan: Codable, Equatable, Sendable {
    let name: String
    let hasWorktree: Bool
    let branch: String?
    let worktreePath: String?

    enum CodingKeys: String, CodingKey {
        case name, branch
        case hasWorktree = "has_worktree"
        case worktreePath = "worktree_path"
    }
}

struct LeoDaemonEnvelope<T: Decodable>: Decodable, Sendable where T: Sendable {
    let ok: Bool
    let data: T?
    let error: String?
    let code: String?
    let matches: [String]?

    static func decode(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw LeoDaemonError.decoding(String(describing: error))
        }
    }

    func value() throws -> T {
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

    func expectOK() throws {
        guard ok else {
            throw LeoDaemonError.daemon(
                code: code,
                message: error ?? "Unknown daemon error",
                matches: matches ?? []
            )
        }
    }
}

enum LeoDaemonError: Error, Equatable, Sendable {
    case daemon(code: String?, message: String, matches: [String])
    case transport(String)
    case timeout
    case decoding(String)
    case socketMissing(path: String)
    case hostUnavailable(String)
    case hostUnknown(String)
}

extension LeoDaemonError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .daemon(_, let message, _): return message
        case .transport(let message): return "Connection to the Leo daemon failed: \(message)"
        case .timeout: return "The Leo daemon did not respond in time"
        case .decoding(let message): return "Could not understand the Leo daemon's response: \(message)"
        case .socketMissing(let path): return "The Leo daemon socket is missing at \(path)"
        case .hostUnavailable(let message): return "The remote host is unavailable: \(message)"
        case .hostUnknown(let message): return "The remote host is unknown: \(message)"
        }
    }
}

struct LeoSpawnRequest: Codable, Equatable, Sendable {
    let template: String?
    let fromAgent: String?
    let repo: String?
    let name: String?
    let branch: String?
    let base: String?
    let prompt: String?
    let environment: [String: String]?
    let idleSuspend: Bool?
    /// B-283: the ordered named environments; nil sends none. Left out of
    /// `CodingKeys`: `LeoEnvironmentsWire.spawnBody` adds it (a `var` only
    /// so decoding can default it).
    private(set) var environments: [String]?

    init(template: String? = nil, fromAgent: String? = nil, repo: String? = nil,
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
