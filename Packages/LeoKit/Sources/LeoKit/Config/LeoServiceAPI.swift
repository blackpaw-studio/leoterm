import Foundation

/// The service routes of the config API: status, restarts, the log tail and a
/// config reload. Served beside the config routes on the same transport.
public protocol LeoServiceAPI: Sendable {
    /// `GET /service/status`.
    func serviceStatus() async throws -> LeoServiceStatus
    /// `POST /service/restart`: 202 once the restart is launched. While one
    /// runs, another request is a 409 `restart_in_progress`.
    func restartService() async throws -> LeoServiceRestart
    /// `POST /service/restart-agents`.
    func restartAgents() async throws -> LeoAgentsRestartResult
    /// `GET /service/log?lines=` (the daemon caps it at 1000).
    func serviceLog(lines: Int) async throws -> LeoServiceLog
    /// `POST /config/reload`.
    func reloadConfig() async throws -> LeoConfigReload
}
