import Foundation

struct LeoAgentIdentity: Hashable, Sendable {
    let host: LeoHostID
    let name: String
    let workspace: String?
    let repo: String?
    /// Set for a dispatch subagent (B-266): part of its identity, so no
    /// agent equals it however it is named. `name` is then `dispatch.<id>`
    /// (for display paths that only know names), and `title` is what its
    /// tab shows.
    let dispatchID: String?
    let title: String?

    init(
        host: LeoHostID, name: String, workspace: String? = nil, repo: String? = nil,
        dispatchID: String? = nil, title: String? = nil
    ) {
        self.host = host
        self.name = name
        self.workspace = workspace
        self.repo = repo
        self.dispatchID = dispatchID
        self.title = title
    }

    /// A dispatch subagent on `host`, shown under `title`.
    static func dispatch(host: LeoHostID, id: String, title: String?) -> LeoAgentIdentity {
        LeoAgentIdentity(host: host, name: "dispatch.\(id)", dispatchID: id, title: title)
    }

    /// A dispatch is never an agent, whatever either is named.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host == rhs.host && lhs.name == rhs.name && lhs.dispatchID == rhs.dispatchID
    }
    func hash(into hasher: inout Hasher) { hasher.combine(host); hasher.combine(name); hasher.combine(dispatchID) }
}

enum LeoAttachCommandError: Error, Equatable, Sendable {
    case invalidAgentName
    case invalidDispatchID
}

enum LeoAttachCommand {
    static func build(
        executable: String, identity: LeoAgentIdentity, features: LeoDaemonFeatures = .none
    ) throws -> String {
        if let dispatchID = identity.dispatchID {
            return try buildDispatch(executable: executable, host: identity.host, dispatchID: dispatchID)
        }
        guard !identity.name.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw LeoAttachCommandError.invalidAgentName
        }
        var parts = ["env", "-u", "TMUX", "-u", "TMUX_PANE", try leoShellQuote(executable)]
        parts += ["agent", "attach"]
        if case .remote(let host) = identity.host {
            parts += ["--host", try leoShellQuote(host)]
        }
        parts += features.attachPlacementArguments
        parts += ["--", try leoShellQuote(identity.name)]
        return parts.joined(separator: " ")
    }

    /// `leo [--host H] dispatch attach <id>`: attaches the TTY to the
    /// dispatch's pane and exits when the dispatch closes (B-266). An id
    /// that could read as a flag, or break the line, is refused.
    static func buildDispatch(executable: String, host: LeoHostID, dispatchID: String) throws -> String {
        guard !dispatchID.isEmpty, !dispatchID.hasPrefix("-"),
              !dispatchID.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw LeoAttachCommandError.invalidDispatchID
        }
        var parts = ["env", "-u", "TMUX", "-u", "TMUX_PANE", try leoShellQuote(executable)]
        if case .remote(let name) = host {
            parts += ["--host", try leoShellQuote(name)]
        }
        parts += ["dispatch", "attach", try leoShellQuote(dispatchID)]
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
