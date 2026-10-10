import Foundation

/// The agent a surfaced path belongs to: its host, and its workspace for
/// relative paths. `name` is nil when no agent is in play (Open File in
/// Editor… with nothing focused or selected): then only absolute and `~`
/// paths resolve, on the selected host.
struct LeoEditorAgentContext: Equatable, Sendable {
    let host: LeoHostID
    let name: String?
    let workspace: String?
}

extension LeoEditorTabs {
    /// Resolves a surfaced link (a ⌘-clicked path or `file://` URL, or a
    /// typed path) for `agent` and opens it on the agent's host, at its
    /// `:line:column` if it has one, in its own tab.
    @discardableResult
    func open(link text: String, for agent: LeoEditorAgentContext) async throws -> LeoEditorOpenOutcome {
        let link = try LeoEditorLink.parse(text)
        let home = link.needsHome ? try await homeDirectory(on: agent.host) : nil
        let location = try link.resolve(workspace: agent.workspace, home: home)
        return try await open(LeoEditorFileID(host: agent.host, path: location.path), line: location.line, column: location.column)
    }
}
