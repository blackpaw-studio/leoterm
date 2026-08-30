import Foundation
import Combine
import os

/// Observable view-model over the Leo daemon. The sidebar binds to it.
/// Polling is driven externally (a later task starts/stops a timer based on
/// sidebar visibility); this type exposes `refresh()` plus the lifecycle actions.
@MainActor
final class LeoAgentStore: ObservableObject {
    enum Connection: Equatable { case unknown, online, offline }

    @Published private(set) var agents: [Agent] = []
    @Published private(set) var templates: [Template] = []
    @Published private(set) var connection: Connection = .unknown
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    private let daemon: any LeoDaemon
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-store")

    init(daemon: any LeoDaemon = LeoSocketClient()) {
        self.daemon = daemon
    }

    /// Re-fetch the agent roster. Never throws — failures flip `connection` to
    /// `.offline` so the UI degrades cleanly instead of erroring.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await daemon.listAgents()
            // Sort by name so the sidebar order is stable across polls — the
            // daemon returns the roster in an unstable (map-iteration) order,
            // which otherwise makes the list visibly reshuffle every refresh.
            agents = fetched.sorted { $0.name < $1.name }
            connection = .online
            lastError = nil
        } catch let error {
            connection = .offline
            lastError = error.errorDescription
            Self.logger.warning("agent refresh failed: \(error.errorDescription ?? "?", privacy: .public)")
        }
    }

    /// Fetch templates for the spawn sheet. Failures (e.g. a missing `leo`
    /// binary) are recorded in `lastError` rather than swallowed, so they're
    /// visible in the sidebar instead of silently leaving `templates` stale.
    func refreshTemplates() async {
        do {
            templates = try await daemon.listTemplates()
        } catch let error {
            lastError = error.errorDescription
            Self.logger.warning("template refresh failed: \(error.errorDescription ?? "?", privacy: .public)")
        }
    }

    /// Spawn an agent then refresh. Returns the new agent on success.
    @discardableResult
    func spawn(_ request: AgentSpawnRequest) async -> Agent? {
        do {
            let agent = try await daemon.spawn(request)
            await refresh()
            return agent
        } catch let error {
            lastError = error.errorDescription
            return nil
        }
    }

    /// Stop an agent then refresh. A stop failure survives the follow-up
    /// refresh — `refresh()` only clears `lastError` on its own success, but
    /// the action's error is re-applied afterward so a daemon error (e.g.
    /// `agent_still_running`) still reaches the UI even though `refresh()`
    /// itself succeeds.
    func stop(name: String) async {
        var actionError: String?
        do { try await daemon.stop(name: name) } catch let error { actionError = error.errorDescription }
        await refresh()
        if let actionError { lastError = actionError }
    }

    /// Delete (prune) an agent then refresh. See `stop` — the action's error,
    /// if any, is preserved across the follow-up refresh.
    func prune(name: String) async {
        var actionError: String?
        do { try await daemon.prune(name: name) } catch let error { actionError = error.errorDescription }
        await refresh()
        if let actionError { lastError = actionError }
    }

    /// Clears a previously recorded error — used when the user dismisses the
    /// error banner without triggering a new refresh.
    func clearLastError() { lastError = nil }

    /// True if a running agent with this name exists in the current roster.
    func isRunning(_ name: String) -> Bool {
        agents.contains { $0.name == name && $0.status == .running }
    }
}
