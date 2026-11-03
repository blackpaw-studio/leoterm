import Foundation

/// A task that just finished live (succeeded or failed). Each app turns it
/// into a notification.
public struct LeoTaskFinish: Equatable, Sendable {
    public let agent: String
    public let task: LeoAgentTask

    public init(agent: String, task: LeoAgentTask) {
        self.agent = agent
        self.task = task
    }
}

/// Folds `/state` baselines and `agent_task_changed` events into the
/// per-agent task map and reports live finishes. Pure: no clock, no I/O.
///
/// - A baseline replaces everything and never reports a finish, so a
///   reconnect replay is silent.
/// - An event applies only if it is newer than what is held, by
///   (`started_at`, `revision`); a duplicate or older one is ignored.
/// - A finish needs a transition to succeeded or failed whose `ended_at` is
///   newer than the last one seen for that (agent, id).
public struct LeoTaskReducer: Equatable, Sendable {
    private struct Key: Hashable, Sendable {
        let agent: String
        let id: String
    }

    private var held: [String: [String: LeoAgentTask]] = [:]
    private var lastEnded: [Key: Date] = [:]

    public init() {}

    /// Every agent's tasks, each list ordered by start time then id.
    public var allTasks: [String: [LeoAgentTask]] { held.mapValues(Self.ordered) }

    public func tasks(for agent: String) -> [LeoAgentTask] {
        held[agent].map(Self.ordered) ?? []
    }

    /// Replaces the whole map with the agents' reported tasks. Silent.
    @discardableResult
    public mutating func apply(snapshot agents: [LeoObservedAgent]) -> [LeoTaskFinish] {
        held = [:]
        lastEnded = [:]
        for agent in agents where !agent.tasks.isEmpty {
            held[agent.name] = Dictionary(agent.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
            for task in agent.tasks {
                if let ended = task.endedAt { lastEnded[Key(agent: agent.name, id: task.id)] = ended }
            }
        }
        return []
    }

    public mutating func apply(event: LeoObserveEvent) -> [LeoTaskFinish] {
        switch event {
        case .agentTaskChanged(_, _, let agent, let id, let task):
            return apply(agent: agent, id: id, task: task)
        case .agentStopped(_, _, let agent, _):
            held[agent] = nil
            return []
        default:
            return []
        }
    }

    private mutating func apply(agent: String, id: String, task: LeoAgentTask?) -> [LeoTaskFinish] {
        guard let task else {
            held[agent]?[id] = nil
            if held[agent]?.isEmpty == true { held[agent] = nil }
            return []
        }
        if let current = held[agent]?[id], !Self.supersedes(task, current) { return [] }
        held[agent, default: [:]][id] = task
        guard task.state == .succeeded || task.state == .failed, let ended = task.endedAt else { return [] }
        let key = Key(agent: agent, id: id)
        if let seen = lastEnded[key], ended <= seen { return [] }
        lastEnded[key] = ended
        return [LeoTaskFinish(agent: agent, task: task)]
    }

    /// Newer run, or the same run at a higher revision.
    private static func supersedes(_ new: LeoAgentTask, _ current: LeoAgentTask) -> Bool {
        if new.startedAt != current.startedAt { return new.startedAt > current.startedAt }
        return new.revision > current.revision
    }

    private static func ordered(_ tasks: [String: LeoAgentTask]) -> [LeoAgentTask] {
        tasks.values.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }
}
