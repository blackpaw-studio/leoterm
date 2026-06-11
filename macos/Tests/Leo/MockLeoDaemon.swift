import Foundation
@testable import Ghostty

/// In-memory `LeoDaemon` for tests. Records calls and returns scripted results.
actor MockLeoDaemon: LeoDaemon {
    var agents: [Agent]
    var templates: [Template]
    var nextError: LeoError?
    private(set) var stopped: [String] = []
    private(set) var spawned: [AgentSpawnRequest] = []
    private(set) var listCallCount = 0

    init(agents: [Agent] = [], templates: [Template] = []) {
        self.agents = agents
        self.templates = templates
    }

    func setAgents(_ agents: [Agent]) { self.agents = agents }
    func setNextError(_ error: LeoError?) { self.nextError = error }

    func listAgents() async throws(LeoError) -> [Agent] {
        listCallCount += 1
        if let nextError { self.nextError = nil; throw nextError }
        return agents
    }
    func listTemplates() async throws(LeoError) -> [Template] {
        if let nextError { self.nextError = nil; throw nextError }
        return templates
    }
    func spawn(_ request: AgentSpawnRequest) async throws(LeoError) -> Agent {
        if let nextError { self.nextError = nil; throw nextError }
        let agent = Agent(name: request.name ?? "\(request.template)-\(request.repo)",
                          template: request.template, repo: request.repo,
                          workspace: "/tmp/\(request.repo)", status: .running,
                          startedAt: "2026-06-10T00:00:00Z", env: [:])
        spawned.append(request); agents.append(agent)
        return agent
    }
    func stop(name: String) async throws(LeoError) {
        if let nextError { self.nextError = nil; throw nextError }
        stopped.append(name)
        agents = agents.map { $0.name == name ? Agent(name: $0.name, template: $0.template, repo: $0.repo, workspace: $0.workspace, status: .stopped, startedAt: $0.startedAt, env: $0.env) : $0 }
    }
    func prune(name: String) async throws(LeoError) {
        if let nextError { self.nextError = nil; throw nextError }
        agents.removeAll { $0.name == name }
    }
}
