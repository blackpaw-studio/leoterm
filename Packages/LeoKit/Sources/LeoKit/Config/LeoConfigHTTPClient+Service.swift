import Foundation

extension LeoConfigHTTPClient: LeoServiceAPI {
    public func serviceStatus() async throws -> LeoServiceStatus {
        try await read("\(prefix)/service/status")
    }

    public func restartService() async throws -> LeoServiceRestart {
        try await exchange("POST", "\(prefix)/service/restart")
    }

    public func restartAgents() async throws -> LeoAgentsRestartResult {
        try await exchange("POST", "\(prefix)/service/restart-agents")
    }

    public func serviceLog(lines: Int) async throws -> LeoServiceLog {
        try await read("\(prefix)/service/log?lines=\(max(1, lines))")
    }

    public func reloadConfig() async throws -> LeoConfigReload {
        try await exchange("POST", "\(prefix)/config/reload")
    }
}
