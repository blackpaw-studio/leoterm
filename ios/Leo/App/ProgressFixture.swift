#if DEBUG
import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import OSLog

/// DEBUG builds only: a fake fleet whose agents carry scripted tasks, from the
/// JSON file named by `LEO_PROGRESS_FIXTURE` (same shape as the Mac fixture,
/// `macos/Tests/Leo/Fixtures/progress_fixture.json`), so every progress
/// surface can be screenshotted with no daemon or relay. Tasks go through the
/// app's real wire decoder, then the same `/state` and `agent_task_changed`
/// plumbing the Fleet reducer reads from a daemon. Task times are relative:
/// `started_ago` counts back from fixture load, `updated_ago` / `ended_ago`
/// from when the step fires, `eta_in` forward from then.
///
/// Launch args: `-startTab agents|chats`, `-progressDetail <agent>` opens that
/// agent's detail. A collapsed panel comes from the stored default
/// (`simctl spawn <udid> defaults write <bundle> progressPanelCollapsed -bool YES`).
enum ProgressFixture {
    static let environmentKey = "LEO_PROGRESS_FIXTURE"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.ios", category: "progress-fixture")

    static var isRequested: Bool { ProcessInfo.processInfo.environment[environmentKey] != nil }

    private static let daemon = PairedDaemon(
        id: "fixture-progress", name: "Dionysus", baseURL: URL(string: "https://dionysus.lan")!, urls: [],
        deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
    )

    // Immutable JSON from the fixture file, read only; safe to share.
    private struct Step: @unchecked Sendable {
        let after: TimeInterval
        let agent: String
        let id: String
        let task: [String: Any]?
    }

    private struct File {
        let tasks: [String: [[String: Any]]]
        let script: [Step]

        init?(path: String) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                logger.error("progress fixture \(path, privacy: .public) unreadable")
                return nil
            }
            tasks = (root["tasks"] as? [String: [[String: Any]]]) ?? [:]
            script = ((root["script"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let agent = entry["agent"] as? String, let id = entry["id"] as? String else { return nil }
                return Step(after: (entry["after"] as? Double) ?? 1, agent: agent, id: id, task: entry["task"] as? [String: Any])
            }
        }
    }

    /// Decodes one fixture task with the wire decoder (`LeoAgentTask`).
    private static func task(_ raw: [String: Any], id: String, runBase: Date, now: Date) -> LeoAgentTask? {
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

    private static func agent(
        _ name: String, emoji: String, attention: LeoAttentionState? = nil, tasks: [LeoAgentTask]
    ) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: .running, activity: attention == nil ? .working : .idle, currentAction: nil, lastActivityAt: nil,
            attention: attention.map { LeoAttentionSignal(state: $0, revision: 1) }, startedAt: nil, template: "coding", harness: "claude",
            appearance: LeoAgentAppearance(emoji: emoji, color: nil, emojiSource: .manual, colorSource: .manual), tasks: tasks
        )
    }

    /// Alpha has three tasks (+2), beta's is stale, gamma's failed, delta is
    /// waiting on the user (attention wins over its running task), epsilon has none.
    private static func fleet(_ seeded: [String: [LeoAgentTask]]) -> LeoObservedState {
        LeoObservedState(agents: [
            agent("alpha", emoji: "🛠️", tasks: seeded["alpha"] ?? []),
            agent("beta", emoji: "📦", tasks: seeded["beta"] ?? []),
            agent("gamma", emoji: "🚢", tasks: seeded["gamma"] ?? []),
            agent("delta", emoji: "🧪", attention: .needsInput, tasks: seeded["delta"] ?? []),
            agent("epsilon", emoji: "🌙", tasks: seeded["epsilon"] ?? []),
        ])
    }

    /// Replaces the paired daemons, keychain, daemon transport and chat client.
    static func prepare(_ values: inout DependencyValues) {
        let loadedAt = Date()
        let file = ProcessInfo.processInfo.environment[environmentKey].flatMap(File.init(path:))
        // Decoded once: a refetch must hand back the same tasks.
        let seeded = (file?.tasks ?? [:]).mapValues { list in
            list.compactMap { task($0, id: ($0["id"] as? String) ?? "", runBase: loadedAt, now: loadedAt) }
        }
        let script = file?.script ?? []
        values.pairedDaemons.load = { [daemon] in [daemon] }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.fetchState = { _ in fleet(seeded) }
        values.daemonClient.events = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.hello(seq: 1, at: nil, version: "0.57.0", serverTime: nil, features: ["agent_progress"]))
                let replay = Task {
                    for (index, step) in script.enumerated() where !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(max(step.after, 0)))
                        let value = step.task.flatMap { task($0, id: step.id, runBase: loadedAt, now: Date()) }
                        continuation.yield(.agentTaskChanged(seq: 2 + index, at: nil, agent: step.agent, id: step.id, task: value))
                    }
                }
                continuation.onTermination = { _ in replay.cancel() }
            }
        }
        values.chatClient.threads = { _ in ["alpha", "beta", "gamma", "delta", "epsilon"].map { LeoChatThread(agent: $0) } }
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
        values.chatClient.markRead = { _, _, _ in }
    }

    /// `-progressDetail <agent>`: opens that agent's detail once the fleet has it.
    static func open(_ store: StoreOf<AppFeature>) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-progressDetail"), arguments.indices.contains(flag + 1) else { return }
        store.send(.notificationOpened(AgentRef(daemonID: daemon.id, name: arguments[flag + 1])))
    }
}
#endif
