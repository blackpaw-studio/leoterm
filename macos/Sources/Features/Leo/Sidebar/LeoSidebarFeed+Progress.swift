import Foundation
import LeoKit

/// Agent task progress in the feed: every applied `/state` replaces the
/// task map (silently), `agent_task_changed` events fold in live and report
/// finishes, and `agent_stopped` clears the agent's tasks. Rows show them
/// only while the host advertises `agent_progress`.
extension LeoSidebarFeed {
    func receiveTask(_ event: LeoObserveEvent) {
        let before = tasks
        let finishes = taskReducer.apply(event: event)
        observeTaskETAs()
        deliver(finishes)
        if tasks != before { emit() }
    }

    /// A `/state` baseline: replaces the map and reports nothing.
    func applyTasks(state agents: [LeoObservedAgent]) {
        taskReducer.apply(snapshot: agents)
        observeTaskETAs()
    }

    /// Host switch or stop: nothing carries over.
    func resetTasks() {
        taskReducer = LeoTaskReducer()
        taskETA = LeoTaskETA()
    }

    var tasks: [String: [LeoAgentTask]] { taskReducer.allTasks }

    private func deliver(_ finishes: [LeoTaskFinish]) {
        guard !finishes.isEmpty, daemonFeatures.contains(.agentProgress) else { return }
        let host = selectedHost
        let callback = onTaskFinishes
        Task { @MainActor in callback(host, finishes) }
    }

    private func observeTaskETAs() {
        let now = wallClock()
        for (agent, list) in taskReducer.allTasks {
            for task in list { taskETA.observe(agent: agent, task: task, now: now) }
        }
    }

    func rowTasks(for agent: String) -> LeoRowTasks {
        let list = taskReducer.tasks(for: agent)
        guard !list.isEmpty else { return .none }
        let now = wallClock()
        let etas = list.reduce(into: [String: Date]()) { map, task in
            if let eta = taskETA.etaAt(agent: agent, task: task, now: now) { map[task.id] = eta }
        }
        return LeoRowTasks(tasks: list, etaAt: etas)
    }
}

extension LeoSidebarSnapshot {
    /// Rows with their tasks, only when the daemon advertised
    /// `agent_progress`. None while disconnected: the rows are stale.
    func overlayingTasks(_ tasksFor: (String) -> LeoRowTasks, features: LeoDaemonFeatures) -> LeoSidebarSnapshot {
        let shows = !connectivity.isDisconnected && features.contains(.agentProgress)
        return LeoSidebarSnapshot(
            rows: rows.map { $0.withTasks(shows ? tasksFor($0.name) : .none) }, connectivity: connectivity, generation: generation,
            listRefreshSucceeded: listRefreshSucceeded, attentionCount: attentionCount, dispatchChildren: dispatchChildren
        )
    }
}
