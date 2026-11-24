import ComposableArchitecture
import Foundation
import LeoKit

/// Keeps the non-secret agent directory the Control's picker reads, in the
/// app group's shared container. The app writes it as the fleet changes.
@DependencyClient
public struct AgentDirectoryClient: Sendable {
    public var write: @Sendable (_ targets: [LeoAgentTarget]) async -> Void
}

extension AgentDirectoryClient: DependencyKey {
    public static let appGroupIdentifier = "group.studio.blackpaw.leo.ios"

    /// Inert in tests: nothing to assert unless a test installs `write`.
    public static let testValue = AgentDirectoryClient(write: { _ in })

    public static var liveValue: AgentDirectoryClient {
        guard let store = LeoAgentDirectorySnapshotStore.appGroup(identifier: appGroupIdentifier) else { return AgentDirectoryClient(write: { _ in }) }
        return AgentDirectoryClient(write: { targets in
            do { try store.write(targets) } catch { LeoLog.logger(category: "agent-directory").error("snapshot write failed: \(error.localizedDescription)") }
        })
    }
}

extension DependencyValues {
    public var agentDirectory: AgentDirectoryClient {
        get { self[AgentDirectoryClient.self] }
        set { self[AgentDirectoryClient.self] = newValue }
    }
}
