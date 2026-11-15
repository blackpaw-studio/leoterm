import ComposableArchitecture
import Foundation
import LeoKit

/// A task finished (`agent_progress`): what the local notification says.
public struct ProgressNotification: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case succeeded, failed }

    public let ref: AgentRef
    public let agentName: String
    public let taskTitle: String
    public let outcome: Outcome

    public init(ref: AgentRef, agentName: String, taskTitle: String, outcome: Outcome) {
        self.ref = ref
        self.agentName = agentName
        self.taskTitle = taskTitle
        self.outcome = outcome
    }
}

/// Posts a local notification for a finished task. The app provides the live
/// value; tapping it opens the agent like a push does.
@DependencyClient
public struct ProgressNotifierClient: Sendable {
    public var post: @Sendable (_ notification: ProgressNotification) async -> Void
}

extension ProgressNotifierClient: TestDependencyKey {
    public static let testValue = ProgressNotifierClient()
}

extension DependencyValues {
    public var progressNotifier: ProgressNotifierClient {
        get { self[ProgressNotifierClient.self] }
        set { self[ProgressNotifierClient.self] = newValue }
    }
}

/// The time progress is judged at (ETA samples, elapsed). Tests that don't care
/// get the real clock instead of an unimplemented-dependency failure.
private enum ProgressNowKey: DependencyKey {
    static let liveValue: @Sendable () -> Date = { Date() }
    static let testValue: @Sendable () -> Date = { Date() }
}

extension DependencyValues {
    var progressNow: @Sendable () -> Date {
        get { self[ProgressNowKey.self] }
        set { self[ProgressNowKey.self] = newValue }
    }
}
