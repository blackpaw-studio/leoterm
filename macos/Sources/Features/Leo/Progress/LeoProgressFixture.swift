#if DEBUG
import Foundation
import OSLog
import LeoKit

/// DEBUG builds only: replays scripted agent-task state from a JSON file
/// named by `LEO_PROGRESS_FIXTURE`, so every progress surface can be
/// screenshotted without a daemon that emits tasks. Everything goes through
/// the app's real decode path (`LeoAgentTask`'s wire decoder, then the same
/// `/state` and `agent_task_changed` plumbing a daemon would feed).
///
/// ```json
/// {
///   "tasks": { "alpha": [ {"id": "build", "title": "Xcode build", "percent": 62,
///                          "status": "Compiling", "started_ago": 252, "eta_in": 180} ] },
///   "script": [ {"after": 2, "agent": "alpha", "id": "build",
///                "task": {"title": "Xcode build", "percent": 80, "started_ago": 254} },
///               {"after": 2, "agent": "alpha", "id": "build", "task": null} ]
/// }
/// ```
/// `tasks` seeds `/state` (only agents the daemon already lists); each
/// `script` step is yielded `after` seconds after the previous one (the
/// first, after each hello), and `"task": null` removes it. A task is the
/// wire object plus relative times in seconds: `started_ago` (back from the
/// fixture's load time, so a run keeps its identity across steps),
/// `updated_ago` and `ended_ago` (back from when the step fires; a finished
/// task defaults to 0) and `eta_in` (forward from then). A hello also
/// advertises `agent_progress`. Nothing is sent anywhere.
enum LeoProgressFixture {
    static let environmentKey = "LEO_PROGRESS_FIXTURE"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    struct Step: Equatable {
        let after: TimeInterval
        let agent: String
        let id: String
        /// The wire task with relative times still in it; nil removes it.
        let task: [String: Any]?

        static func == (lhs: Step, rhs: Step) -> Bool {
            lhs.after == rhs.after && lhs.agent == rhs.agent && lhs.id == rhs.id
                && (lhs.task as NSDictionary?) == (rhs.task as NSDictionary?)
        }
    }

    struct File: Equatable {
        let tasks: [String: [[String: Any]]]
        let script: [Step]

        static func == (lhs: File, rhs: File) -> Bool {
            (lhs.tasks as NSDictionary) == (rhs.tasks as NSDictionary) && lhs.script == rhs.script
        }

        init(json: Data) throws {
            guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw FixtureError.notAnObject }
            tasks = (root["tasks"] as? [String: [[String: Any]]]) ?? [:]
            script = ((root["script"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let agent = entry["agent"] as? String, let id = entry["id"] as? String else { return nil }
                return Step(after: (entry["after"] as? Double) ?? 1, agent: agent, id: id, task: entry["task"] as? [String: Any])
            }
        }
    }

    enum FixtureError: Error { case notAnObject }

    static func loadFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> File? {
        guard let path = environment[environmentKey] else { return nil }
        do {
            return try File(json: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            logger.error("progress fixture \(path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Decodes one fixture task with the app's wire decoder. `started_ago`
    /// counts back from `runBase` (the fixture's load time, so a run keeps
    /// its identity across steps); `updated_ago` (default 0), `ended_ago`
    /// (default 0 for a finished task) and `eta_in` count from `now`.
    /// `id` is filled in from the step.
    static func task(_ raw: [String: Any], id: String, runBase: Date, now: Date) -> LeoAgentTask? {
        var wire = raw
        wire["id"] = (raw["id"] as? String) ?? id
        func seconds(_ key: String) -> Double? { (wire.removeValue(forKey: key) as? NSNumber)?.doubleValue }
        let formatter = ISO8601DateFormatter()
        wire["started_at"] = formatter.string(from: runBase.addingTimeInterval(-(seconds("started_ago") ?? 0)))
        wire["updated_at"] = formatter.string(from: now.addingTimeInterval(-(seconds("updated_ago") ?? 0)))
        let terminal = ["succeeded", "failed", "cancelled"].contains(wire["state"] as? String ?? "")
        if let ended = seconds("ended_ago") ?? (terminal ? 0 : nil) { wire["ended_at"] = formatter.string(from: now.addingTimeInterval(-ended)) }
        if let eta = seconds("eta_in") { wire["eta_at"] = formatter.string(from: now.addingTimeInterval(eta)) }
        guard let data = try? JSONSerialization.data(withJSONObject: wire) else { return nil }
        return try? JSONDecoder().decode(LeoAgentTask.self, from: data)
    }

    /// The seed, decoded once: a refetch must hand back the same tasks.
    static func seed(_ file: File, now: Date = Date()) -> [String: [LeoAgentTask]] {
        file.tasks.mapValues { list in list.compactMap { task($0, id: ($0["id"] as? String) ?? "", runBase: now, now: now) } }
    }

    /// Far above any real daemon's seqs, like the dispatch-move replay.
    static func firstSeq() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    static func wrap(
        _ source: LeoSidebarActivitySource, file: File, now: Date = Date(), replayStartSeq: @escaping @Sendable () -> Int = firstSeq
    ) -> LeoSidebarActivitySource {
        let seeded = seed(file, now: now)
        let script = file.script
        return LeoSidebarActivitySource(events: {
            let events = await source.events()
            return AsyncStream { continuation in
                let task = Task {
                    var replays: [Task<Void, Never>] = []
                    for await event in events {
                        guard case .hello(let seq, let at, let version, let serverTime, let bootID, let features) = event else {
                            continuation.yield(event)
                            continue
                        }
                        let added = features.contains("agent_progress") ? [] : ["agent_progress"]
                        continuation.yield(.hello(seq: seq, at: at, version: version, serverTime: serverTime, bootID: bootID, features: features + added))
                        let start = replayStartSeq()
                        replays.append(Task {
                            for (index, step) in script.enumerated() where !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: UInt64(max(step.after, 0) * 1_000_000_000))
                                let value = step.task.flatMap { Self.task($0, id: step.id, runBase: now, now: Date()) }
                                continuation.yield(.agentTaskChanged(seq: start + index, at: nil, agent: step.agent, id: step.id, task: value))
                            }
                        })
                    }
                    continuation.finish()
                    replays.forEach { $0.cancel() }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }, observedState: {
            let state = try await source.fetchState()
            let agents = state.agents.map { agent in
                guard let tasks = seeded[agent.name] else { return agent }
                return LeoObservedAgent(
                    name: agent.name, host: agent.host, status: agent.status, activity: agent.activity,
                    currentAction: agent.currentAction, lastActivityAt: agent.lastActivityAt, attention: agent.attention,
                    startedAt: agent.startedAt, usage: agent.usage, environments: agent.environments, template: agent.template,
                    harness: agent.harness, appearance: agent.appearance, movedTo: agent.movedTo, movedAt: agent.movedAt,
                    displayName: agent.daemonDisplayName, tasks: tasks
                )
            }
            return LeoObservedState(agents: agents, dispatches: state.dispatches, seq: state.seq)
        })
    }
}
#endif
