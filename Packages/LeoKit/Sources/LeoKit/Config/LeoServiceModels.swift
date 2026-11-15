import Foundation

/// One supervised process in `GET /service/status` (an agent).
public struct LeoServiceProcess: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    /// `running`, `restarting` or `stopped`; a value this app doesn't know is kept as sent.
    public let status: String
    public let startedAt: Date?
    public let restarts: Int
    public let isEphemeral: Bool

    public var id: String { name }
    public var isRunning: Bool { status == "running" }

    public init(name: String, status: String, startedAt: Date? = nil, restarts: Int = 0, isEphemeral: Bool = false) {
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.restarts = restarts
        self.isEphemeral = isEphemeral
    }

    enum CodingKeys: String, CodingKey {
        case name, status, restarts, ephemeral
        case startedAt = "started_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            status: try container.decodeIfPresent(String.self, forKey: .status) ?? "",
            startedAt: try container.decodeIfPresent(String.self, forKey: .startedAt).flatMap(LeoTaskRun.date),
            restarts: try container.decodeIfPresent(Int.self, forKey: .restarts) ?? 0,
            isEphemeral: try container.decodeIfPresent(Bool.self, forKey: .ephemeral) ?? false
        )
    }
}

/// `GET /service/status`: the daemon process and what it supervises.
public struct LeoServiceStatus: Decodable, Equatable, Sendable {
    public let version: String
    public let pid: Int
    public let startedAt: Date?
    public let configPath: String
    public let logPath: String
    public let restartRequired: LeoConfigRestartRequired
    public let processes: [LeoServiceProcess]

    public init(
        version: String, pid: Int, startedAt: Date? = nil, configPath: String = "", logPath: String = "",
        restartRequired: LeoConfigRestartRequired = LeoConfigRestartRequired(), processes: [LeoServiceProcess] = []
    ) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.configPath = configPath
        self.logPath = logPath
        self.restartRequired = restartRequired
        self.processes = processes
    }

    /// The agents Restart All would restart: those running now.
    public var runningAgentCount: Int { processes.filter(\.isRunning).count }

    /// Whether this is a different daemon process from `previous`: a new pid
    /// or a new start time.
    public func isRestarted(since previous: LeoServiceStatus) -> Bool {
        pid != previous.pid || startedAt != previous.startedAt
    }

    enum CodingKeys: String, CodingKey {
        case version, pid, processes
        case startedAt = "started_at"
        case configPath = "config_path"
        case logPath = "log_path"
        case restartRequired = "restart_required"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decodeIfPresent(String.self, forKey: .version) ?? "",
            pid: try container.decodeIfPresent(Int.self, forKey: .pid) ?? 0,
            startedAt: try container.decodeIfPresent(String.self, forKey: .startedAt).flatMap(LeoTaskRun.date),
            configPath: try container.decodeIfPresent(String.self, forKey: .configPath) ?? "",
            logPath: try container.decodeIfPresent(String.self, forKey: .logPath) ?? "",
            restartRequired: try container.decodeIfPresent(LeoConfigRestartRequired.self, forKey: .restartRequired) ?? LeoConfigRestartRequired(),
            processes: try container.decodeIfPresent([LeoServiceProcess].self, forKey: .processes) ?? []
        )
    }
}

/// `POST /service/restart`: 202, the restart runs detached.
public struct LeoServiceRestart: Decodable, Equatable, Sendable {
    public let status: String

    public init(status: String = "restarting") {
        self.status = status
    }
}

/// `POST /service/restart-agents`. The daemon clears its agents flag only
/// when `failed` is empty.
public struct LeoAgentsRestartResult: Decodable, Equatable, Sendable {
    public let restarted: [String]
    public let skipped: [String]
    public let failed: [String: String]

    public var hasFailures: Bool { !failed.isEmpty }

    public init(restarted: [String] = [], skipped: [String] = [], failed: [String: String] = [:]) {
        self.restarted = restarted
        self.skipped = skipped
        self.failed = failed
    }

    enum CodingKeys: String, CodingKey { case restarted, skipped, failed }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            restarted: try container.decodeIfPresent([String].self, forKey: .restarted) ?? [],
            skipped: try container.decodeIfPresent([String].self, forKey: .skipped) ?? [],
            failed: try container.decodeIfPresent([String: String].self, forKey: .failed) ?? [:]
        )
    }
}

/// `GET /service/log?lines=`: the tail of the daemon's log, at most 1000 lines.
public struct LeoServiceLog: Decodable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// `POST /config/reload`: leo.yaml read into the running daemon again.
public struct LeoConfigReload: Decodable, Equatable, Sendable {
    public let revision: String
    /// Saved, but the daemon's reload failed; the daemon sends none today.
    public let warning: String?

    public init(revision: String, warning: String? = nil) {
        self.revision = revision
        self.warning = warning
    }

    enum CodingKeys: String, CodingKey { case revision, warning }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(String.self, forKey: .revision),
            warning: try container.decodeIfPresent(String.self, forKey: .warning)
        )
    }
}

public enum LeoServiceError {
    public static let restartInProgressCode = "restart_in_progress"

    /// The daemon refused a second restart because one is running (409
    /// `restart_in_progress`): not a failure, the restart is on its way.
    public static func isRestartInProgress(_ error: Error) -> Bool {
        guard case LeoDaemonError.daemon(let code, _, _) = error else { return false }
        return code == restartInProgressCode
    }
}
