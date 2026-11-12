import Foundation

/// What the approval sheet shows before anything runs: who the plugin is, where
/// it came from, and what it asks for. On an update, `diff` is only what is new.
public struct LeoPluginApprovalRequest: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    /// The pinned commit; nil for a dev folder.
    public let sha: String?
    /// The git URL or the dev folder's path.
    public let sourceDescription: String
    public let permissions: LeoPluginPermissions
    /// Non-nil for an update: the increases that need approving.
    public let diff: LeoPluginPermissionDiff?
    public let isDev: Bool

    public init(
        id: String, name: String, version: String, sha: String?, sourceDescription: String,
        permissions: LeoPluginPermissions, diff: LeoPluginPermissionDiff?, isDev: Bool
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.sha = sha
        self.sourceDescription = sourceDescription
        self.permissions = permissions
        self.diff = diff
        self.isDev = isDev
    }

    /// The sheet for a plugin that already runs but now asks for more than the
    /// user approved (an app update, a dev edit). Nil unless `info` is waiting
    /// on approval and its manifest is loaded.
    public init?(reviewing info: LeoPluginInfo) {
        guard case .needsApproval(let diff) = info.state, let manifest = info.manifest else { return nil }
        var sha: String?
        var source = ""
        var isDev = false
        switch info.source {
        case .bundled: source = "Built in to Leo"
        case .git(let url, _, let pinned):
            sha = pinned
            source = url
        case .dev(let path):
            source = path
            isDev = true
        }
        self.init(
            id: info.id, name: manifest.name, version: manifest.version, sha: sha, sourceDescription: source,
            permissions: manifest.permissions, diff: diff, isDev: isDev)
    }

    public var isUpdate: Bool { diff != nil }

    public var shortSHA: String? { sha.map { String($0.prefix(7)) } }

    /// One line per capability, in the order the sheet lists them. An update
    /// lists only the increases.
    public var permissionLines: [String] {
        if let diff { return Self.lines(hosts: diff.addedHosts, secrets: diff.secretsEnabled, verbs: diff.addedAgentVerbs) }
        return Self.lines(hosts: permissions.network, secrets: permissions.secrets, verbs: permissions.agents)
    }

    private static func lines(hosts: [String], secrets: Bool, verbs: [LeoPluginAgentVerb]) -> [String] {
        var lines: [String] = []
        if !hosts.isEmpty { lines.append("Network: \(hosts.joined(separator: ", "))") }
        if secrets { lines.append("Keychain: stores secrets such as access tokens") }
        for verb in verbs {
            switch verb {
            case .read: lines.append("Agents: read the list of agents")
            case .send: lines.append("Agents: offer to send messages to agents (you confirm each one)")
            case .spawn: lines.append("Agents: offer to start new agents (you confirm each one)")
            case .usage: lines.append("Agents: read each agent's model, working folder and usage (context, cost, rate limits)")
            }
        }
        return lines
    }
}

/// Folder bookkeeping under the plugins root: `<root>/<id>/<sha>/`.
enum LeoPluginFolders {
    /// Removes one installed copy, and its id folder if that leaves it empty.
    /// `id` and `sha` are validated first so neither can add path components.
    static func remove(root: URL, id: String, sha: String) {
        guard LeoPluginManifestValidator.isReverseDNS(id), let sha = LeoPluginGitSource.normalizedSHA(sha) else { return }
        let idFolder = root.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: idFolder.appendingPathComponent(sha))
        if (try? FileManager.default.contentsOfDirectory(atPath: idFolder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: idFolder)
        }
    }

    static func isPinned(_ registry: LeoPluginRegistry, id: String, sha: String) -> Bool {
        if case .git(_, _, let pinned)? = registry.record(for: id)?.source { return pinned == sha }
        return false
    }
}
