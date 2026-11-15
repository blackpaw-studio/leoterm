import Foundation

/// What a fake daemon knows about its own process: the pid and start time a
/// restart changes, the processes it supervises, its log, and what a
/// Restart All Agents answers.
public struct LeoFakeServiceState: Sendable {
    public var version: String
    public var pid: Int
    public var startedAt: Date
    public var processes: [LeoServiceProcess]
    public var log: String
    public var agentsRestart: LeoAgentsRestartResult

    public init(
        version: String = "v0.0.0-fake", pid: Int = 1, startedAt: Date = Date(timeIntervalSince1970: 1_792_738_800),
        processes: [LeoServiceProcess] = [], log: String = "", agentsRestart: LeoAgentsRestartResult = LeoAgentsRestartResult()
    ) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.processes = processes
        self.log = log
        self.agentsRestart = agentsRestart
    }
}

extension LeoFakeConfigClient {
    public func serviceStatus() async throws -> LeoServiceStatus {
        calls.append(.serviceStatus)
        try await beforeRead()
        return LeoServiceStatus(
            version: serviceState.version, pid: serviceState.pid, startedAt: serviceState.startedAt, configPath: "/home/leo/leo.yaml",
            logPath: "/home/leo/.leo/state/leo.log", restartRequired: restartRequired, processes: serviceState.processes
        )
    }

    /// 202 and clears the service flag; until `finishServiceRestart` another
    /// request is the daemon's 409 `restart_in_progress`.
    public func restartService() async throws -> LeoServiceRestart {
        calls.append(.restartService)
        if isHoldingWrites { await withCheckedContinuation { heldWrites.append($0) } }
        if let failure = takeWriteFailure() { throw failure }
        guard !isRestartingService else {
            throw LeoDaemonError.daemon(code: LeoServiceError.restartInProgressCode, message: "a service restart is already in progress", matches: [])
        }
        isRestartingService = true
        restartRequired = LeoConfigRestartRequired(service: false, agents: restartRequired.agents)
        return LeoServiceRestart()
    }

    /// Clears the agents flag only when nothing failed.
    public func restartAgents() async throws -> LeoAgentsRestartResult {
        calls.append(.restartAgents)
        if isHoldingWrites { await withCheckedContinuation { heldWrites.append($0) } }
        if let failure = takeWriteFailure() { throw failure }
        let result = serviceState.agentsRestart
        if !result.hasFailures { restartRequired = LeoConfigRestartRequired(service: restartRequired.service, agents: false) }
        return result
    }

    public func serviceLog(lines: Int) async throws -> LeoServiceLog {
        calls.append(.serviceLog(lines: lines))
        try await beforeRead()
        return LeoServiceLog(text: serviceState.log)
    }

    public func reloadConfig() async throws -> LeoConfigReload {
        calls.append(.reloadConfig)
        if isHoldingWrites { await withCheckedContinuation { heldWrites.append($0) } }
        if let failure = takeWriteFailure() { throw failure }
        return LeoConfigReload(revision: revision)
    }

    // MARK: scripting

    public func setService(_ state: LeoFakeServiceState) {
        serviceState = state
    }

    /// The restarted daemon is up: a new pid and start time.
    public func finishServiceRestart() {
        serviceState.pid += 1
        serviceState.startedAt = serviceState.startedAt.addingTimeInterval(60)
        isRestartingService = false
    }

    /// Flags a pending restart without a write, as a config change would.
    public func raiseRestartRequired(_ flags: LeoConfigRestartRequired) {
        restartRequired = LeoConfigRestartRequired(
            service: restartRequired.service || flags.service, agents: restartRequired.agents || flags.agents
        )
    }
}
