import Foundation

/// The dismiss route's own failures. Anything else is a `LeoDaemonError`.
public enum LeoAgentTaskError: Error, Equatable, Sendable {
    /// 404: no such agent or task (it may already have expired).
    case notFound
    /// 409: only a failed task can be dismissed.
    case notDismissable(reason: String)
}

extension LeoAgentTaskError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound: "That task is already gone."
        case .notDismissable(let reason): reason
        }
    }
}

/// Dismissing a failed agent task on a daemon advertising `agent_progress`,
/// over the socket (bare route) or `/api/v1`. Agents cannot call it.
public protocol LeoAgentTaskAPI: Sendable {
    /// `DELETE /agents/{name}/tasks/{id}` (204).
    func dismissAgentTask(agent: String, id: String) async throws
}
