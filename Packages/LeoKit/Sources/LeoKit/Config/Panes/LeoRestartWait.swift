import Foundation

/// How a service pane waits out a restart, as a state machine over the
/// status polls. The shell sleeps, asks `expiry(at:)`, polls, and feeds the
/// result to `record`; this decides what each poll means.
///
/// The restart is graceful: the old daemon keeps answering, as the same
/// process, while busy agents drain, so those polls cost nothing but the
/// wall-clock deadline. Only polls that find the daemon unreachable count
/// toward `maxUnreachablePolls`. Without a status from before the restart,
/// "new" means the daemon was seen down and then up.
public struct LeoRestartWait: Sendable {
    public enum Step: Equatable, Sendable {
        /// Still going. `onAgents`: the old process answered, so it is
        /// waiting for busy agents to pause.
        case waiting(onAgents: Bool)
        case restarted(LeoServiceStatus)
        /// Out of time or polls. `afterDown`: the daemon was unreachable at some point.
        case gaveUp(afterDown: Bool)
    }

    private let previous: LeoServiceStatus?
    private let deadline: Date
    private let maxUnreachablePolls: Int
    private var sawDown = false
    private var unreachablePolls = 0

    public init(
        previous: LeoServiceStatus?, startedAt: Date, deadline: TimeInterval = LeoServicePane.defaultRestartDeadline,
        maxUnreachablePolls: Int = LeoServicePane.defaultMaxRestartPolls
    ) {
        self.previous = previous
        self.deadline = startedAt.addingTimeInterval(deadline)
        self.maxUnreachablePolls = maxUnreachablePolls
    }

    /// Checked before each poll: past the deadline there is nothing to ask.
    public func expiry(at now: Date) -> Step? {
        now >= deadline ? .gaveUp(afterDown: sawDown) : nil
    }

    public mutating func record(_ poll: Result<LeoServiceStatus, Error>) -> Step {
        switch poll {
        case .success(let current):
            guard previous.map(current.isRestarted(since:)) ?? sawDown else { return .waiting(onAgents: true) }
            return .restarted(current)
        case .failure:
            sawDown = true
            unreachablePolls += 1
            return unreachablePolls >= maxUnreachablePolls ? .gaveUp(afterDown: true) : .waiting(onAgents: false)
        }
    }
}
