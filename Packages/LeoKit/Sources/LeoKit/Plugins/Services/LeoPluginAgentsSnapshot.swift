import Foundation

public enum LeoPluginAgentsSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let reason): reason
        }
    }
}

/// One agent as a plugin sees it. Without `agents:usage` there is no path
/// field at all: not the worktree, the workspace nor the canonical path.
/// `workspace` and `model` are filled only for a plugin holding `usage`.
public struct LeoPluginAgentSnapshotEntry: Codable, Equatable, Sendable {
    public let name: String
    public let machine: String
    public let status: String
    public let repo: String?
    public let branch: String?
    public let hasWorktree: Bool
    /// Home-relative (`~/.leo/agents/x`), or absolute when outside home. Needs `agents:usage`.
    public let workspace: String?
    /// The observed model, else the configured one. Needs `agents:usage`.
    public let model: String?

    public init(
        name: String, machine: String, status: String, repo: String?, branch: String?, hasWorktree: Bool,
        workspace: String? = nil, model: String? = nil
    ) {
        self.name = name
        self.machine = machine
        self.status = status
        self.repo = repo
        self.branch = branch
        self.hasWorktree = hasWorktree
        self.workspace = workspace
        self.model = model
    }
}

/// `leo.agents.list()`: a snapshot built from the agent lists the sidebar
/// already holds for each machine. Requires `agents:read`; `workspace` and
/// `model` also require `agents:usage`.
public enum LeoPluginAgentsSnapshot {
    public static let maxWorkspaceBytes = 1024

    public static func list(
        agents: [(LeoHostID, LeoAgent)], engine: LeoPluginPermissionEngine,
        usage: (LeoPluginAgentRef) -> LeoPluginUsageReading? = { _ in nil }, homeDirectory: String? = nil
    ) throws -> [LeoPluginAgentSnapshotEntry] {
        if case .denied(let reason) = engine.check(agent: .read) { throw LeoPluginAgentsSnapshotError.permissionDenied(reason) }
        let includesUsageFields = engine.check(agent: .usage).isAllowed
        return agents.map { host, agent in
            let reading = includesUsageFields ? usage(LeoPluginAgentRef(machine: host.displayName, name: agent.name)) : nil
            return LeoPluginAgentSnapshotEntry(
                name: agent.name, machine: host.displayName, status: statusText(agent.status), repo: agent.repo,
                branch: agent.branch,
                // The daemon only gives worktree agents a branch.
                hasWorktree: !(agent.branch ?? "").isEmpty,
                workspace: includesUsageFields ? workspace(agent.workspace, host: host, home: homeDirectory) : nil,
                model: includesUsageFields
                    ? LeoPluginUsageSnapshot.model(observed: reading?.usage?.model, configured: reading?.configuredModel ?? agent.model) : nil)
        }
    }

    /// The reply value: the base fields always present (`null` for a missing
    /// repo or branch); `workspace` and `model` only when present.
    public static func value(
        agents: [(LeoHostID, LeoAgent)], engine: LeoPluginPermissionEngine,
        usage: (LeoPluginAgentRef) -> LeoPluginUsageReading? = { _ in nil }, homeDirectory: String? = nil
    ) throws -> LeoJSONValue {
        .array(
            try list(agents: agents, engine: engine, usage: usage, homeDirectory: homeDirectory).map { entry in
                var fields: [String: LeoJSONValue] = [
                    "name": .string(entry.name), "machine": .string(entry.machine), "status": .string(entry.status),
                    "repo": entry.repo.map(LeoJSONValue.string) ?? .null,
                    "branch": entry.branch.map(LeoJSONValue.string) ?? .null,
                    "hasWorktree": .bool(entry.hasWorktree),
                ]
                fields["workspace"] = entry.workspace.map(LeoJSONValue.string)
                fields["model"] = entry.model.map(LeoJSONValue.string)
                return .object(fields)
            })
    }

    /// A workspace path a plugin may see: absolute, printable, lexically
    /// normalised, and `~`-relative when it is inside this Mac's home. A remote
    /// agent's path is left absolute: its home isn't this Mac's.
    static func workspace(_ raw: String?, host: LeoHostID, home: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), raw.utf8.count <= maxWorkspaceBytes, raw.unicodeScalars.allSatisfy(isPlain) else { return nil }
        let path = URL(fileURLWithPath: raw).standardized.path
        guard host == .local, let home, home.hasPrefix("/") else { return path }
        let root = URL(fileURLWithPath: home).standardized.path
        if path == root { return "~" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// No control, format (bidi overrides), separator or unassigned scalars.
    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: false
        default: true
        }
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
