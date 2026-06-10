import Foundation

/// Body for `POST /agents/spawn`. `template` and `repo` are required by the daemon.
struct AgentSpawnRequest: Codable, Sendable, Equatable {
    let template: String
    let repo: String
    var name: String?
    var branch: String?
    var base: String?
}

/// The Leo daemon, abstracted for dependency injection. The production
/// implementation (`LeoSocketClient`) talks to `~/.leo/state/leo.sock`; tests
/// inject `MockLeoDaemon`.
protocol LeoDaemon: Sendable {
    func listAgents() async throws(LeoError) -> [Agent]
    func listTemplates() async throws(LeoError) -> [Template]
    func spawn(_ request: AgentSpawnRequest) async throws(LeoError) -> Agent
    func stop(name: String) async throws(LeoError)
    func prune(name: String) async throws(LeoError)
}
