import Foundation

public enum LeoPluginAgentsSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let reason): reason
        }
    }
}

/// One agent as a plugin sees it. There is deliberately no path field: not the
/// worktree, the workspace nor the canonical path.
public struct LeoPluginAgentSnapshotEntry: Codable, Equatable, Sendable {
    public let name: String
    public let machine: String
    public let status: String
    public let repo: String?
    public let branch: String?
    public let hasWorktree: Bool
}

/// `leo.agents.list()`: a snapshot built from the agent lists the sidebar
/// already holds for each machine. Requires `agents:read`.
public enum LeoPluginAgentsSnapshot {
    public static func list(
        agents: [(LeoHostID, LeoAgent)], engine: LeoPluginPermissionEngine
    ) throws -> [LeoPluginAgentSnapshotEntry] {
        if case .denied(let reason) = engine.check(agent: .read) { throw LeoPluginAgentsSnapshotError.permissionDenied(reason) }
        return agents.map { host, agent in
            LeoPluginAgentSnapshotEntry(
                name: agent.name, machine: host.displayName, status: statusText(agent.status), repo: agent.repo,
                branch: agent.branch,
                // The daemon only gives worktree agents a branch.
                hasWorktree: !(agent.branch ?? "").isEmpty)
        }
    }

    /// The reply value: every field present, `null` for a missing repo or branch.
    public static func value(agents: [(LeoHostID, LeoAgent)], engine: LeoPluginPermissionEngine) throws -> LeoJSONValue {
        .array(
            try list(agents: agents, engine: engine).map { entry in
                .object([
                    "name": .string(entry.name), "machine": .string(entry.machine), "status": .string(entry.status),
                    "repo": entry.repo.map(LeoJSONValue.string) ?? .null,
                    "branch": entry.branch.map(LeoJSONValue.string) ?? .null,
                    "hasWorktree": .bool(entry.hasWorktree),
                ])
            })
    }

    private static func statusText(_ status: LeoAgentStatus?) -> String {
        switch status {
        case .starting: "starting"
        case .running: "running"
        case .stopped: "stopped"
        case .restoring: "restoring"
        case .unknown(let raw): raw
        case nil: "unknown"
        }
    }
}
