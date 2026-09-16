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
}

enum LeoHostState: Codable, Equatable, Sendable {
    case local, connecting, connected, disconnected, error
    case unknown(String)

    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "local": self = .local
        case "connecting": self = .connecting
        case "connected": self = .connected
        case "disconnected": self = .disconnected
        case "error": self = .error
        case let value: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        let value = switch self {
        case .local: "local"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .error: "error"
        case .unknown(let value): value
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct LeoHostRow: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let local: Bool
    let isDefault: Bool
    let ssh: String?
    let state: LeoHostState
    let error: String?
    let code: String?
    let connectedAt: String?

    var id: String { name }
    var hostID: LeoHostID { local || name == "localhost" ? .local : .remote(name) }

    enum CodingKeys: String, CodingKey {
        case name, local, ssh, state, error, code
        case isDefault = "default"
        case connectedAt = "connected_at"
    }

    init(name: String, local: Bool = false, isDefault: Bool = false, ssh: String? = nil,
         state: LeoHostState, error: String? = nil, code: String? = nil, connectedAt: String? = nil) {
        self.name = name
        self.local = local
        self.isDefault = isDefault
        self.ssh = ssh
        self.state = state
        self.error = error
        self.code = code
        self.connectedAt = connectedAt
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

    init(template: String? = nil, fromAgent: String? = nil, repo: String? = nil,
         name: String? = nil, branch: String? = nil, base: String? = nil,
         prompt: String? = nil, environment: [String: String]? = nil,
         idleSuspend: Bool? = nil) {
        self.template = template
        self.fromAgent = fromAgent
        self.repo = repo
        self.name = name
        self.branch = branch
        self.base = base
        self.prompt = prompt
        self.environment = environment
        self.idleSuspend = idleSuspend
    }

    enum CodingKeys: String, CodingKey {
        case template, repo, name, branch, base, prompt
        case fromAgent = "from_agent"
        case environment = "env"
        case idleSuspend = "idle_suspend"
    }
}
