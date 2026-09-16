import Foundation

struct LeoAgentIdentity: Hashable, Sendable {
    let host: LeoHostID
    let name: String
    let workspace: String?
    let repo: String?

    init(host: LeoHostID, name: String, workspace: String? = nil, repo: String? = nil) {
        self.host = host
        self.name = name
        self.workspace = workspace
        self.repo = repo
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.host == rhs.host && lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(host); hasher.combine(name) }
}

enum LeoAttachCommandError: Error, Equatable, Sendable {
    case invalidAgentName
}

enum LeoAttachCommand {
    static func build(executable: String, identity: LeoAgentIdentity) throws -> String {
        guard !identity.name.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw LeoAttachCommandError.invalidAgentName
        }
        var parts = ["env", "-u", "TMUX", "-u", "TMUX_PANE", try leoShellQuote(executable)]
        if case .remote(let host) = identity.host {
            parts += ["--host", try leoShellQuote(host)]
        }
        parts += ["agent", "attach", try leoShellQuote(identity.name)]
        return parts.joined(separator: " ")
    }

    static func workingDirectory(
        identity: LeoAgentIdentity,
        isDirectory: (String) -> Bool = Self.isDirectory
    ) -> String? {
        guard identity.host == .local else { return nil }
        if let workspace = identity.workspace, isDirectory(workspace) { return workspace }
        if let repo = identity.repo, isDirectory(repo) { return repo }
        return nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
