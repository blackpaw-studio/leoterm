#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// One machine on a daemon with `agent_brief` and three agents (`-briefFixture`),
/// for the Agent Brief screenshots: athena is blocked with a full brief,
/// olympus works with a stale one, hermes has none.
///
/// Launch args: `-briefDetail <agent>` opens that agent's detail,
/// `-briefChat <agent>` its thread (`-briefChatExpanded` opens the Brief header),
/// `-briefSettings` replaces the app with the Daemon settings screen, backed by
/// an in-memory config API (`-briefSettingsOn` starts with the switch on).
enum BriefFixture {
    static var isRequested: Bool { arguments.contains("-briefFixture") || isSettingsRequested }
    static var isSettingsRequested: Bool { arguments.contains("-briefSettings") }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static let daemon = PairedDaemon(
        id: "fixture-brief", name: "Dionysus", baseURL: URL(string: "https://dionysus.lan")!, urls: [],
        deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
    )

    private static func wire(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func fleet(now: Date) -> LeoObservedState {
        let athena = LeoAgentBrief(
            goal: "Move Leo's agent summaries onto the iOS inbox",
            status: "Waiting on your call: keep the compatibility shim or drop it?",
            decisions: ["Briefs come from the agent itself, no summarizer", "Hidden when the machine has them switched off"],
            open: ["Shim: keep or drop", "Device check on a real iPhone"],
            updatedAt: now.addingTimeInterval(-12 * 60)
        )
        let olympus = LeoAgentBrief(
            goal: "Rebuild the nightly report", status: "Rendering charts", decisions: ["Use the new palette"],
            updatedAt: now.addingTimeInterval(-3 * 86_400)
        )
        func agent(_ name: String, emoji: String, activity: LeoActivity, attention: LeoAttentionState?, brief: LeoAgentBrief?) -> LeoObservedAgent {
            LeoObservedAgent(
                name: name, status: .running, activity: activity, currentAction: nil, lastActivityAt: wire(now),
                attention: attention.map { LeoAttentionSignal(state: $0, revision: 1, at: now.addingTimeInterval(-300)) },
                startedAt: nil, template: "coding", harness: "claude",
                appearance: LeoAgentAppearance(emoji: emoji, color: nil, emojiSource: .manual), brief: brief
            )
        }
        return LeoObservedState(agents: [
            agent("athena", emoji: "🦉", activity: .idle, attention: .needsInput, brief: athena),
            agent("olympus", emoji: "🏛️", activity: .working, attention: nil, brief: olympus),
            agent("hermes", emoji: "📨", activity: .idle, attention: nil, brief: nil),
        ])
    }

    static func prepare(_ values: inout DependencyValues) {
        let now = Date()
        values.pairedDaemons.load = { [daemon] in [daemon] }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.events = { _ in
            AsyncThrowingStream {
                $0.yield(.hello(seq: 1, at: nil, version: "0.90.0", serverTime: nil, bootID: "fixture", features: ["agent_brief", "config_api"]))
            }
        }
        values.daemonClient.fetchState = { _ in fleet(now: now) }
        values.pushClient.authorization = { .denied }
        values.chatClient.threads = { _ in ["athena", "olympus", "hermes"].map { LeoChatThread(agent: $0) } }
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
        values.chatClient.markRead = { _, _, _ in }
    }

    static func open(_ store: StoreOf<AppFeature>) {
        guard !isSettingsRequested else { return }
        func argument(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if let name = argument(after: "-briefChat") {
            store.send(.chatOpened(AgentRef(daemonID: daemon.id, name: name)))
            if arguments.contains("-briefChatExpanded") {
                Task { @MainActor in
                    while store.chat == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    store.send(.chat(.briefToggled))
                }
            }
        }
        if let name = argument(after: "-briefDetail") { store.send(.notificationOpened(AgentRef(daemonID: daemon.id, name: name))) }
    }

    /// `-briefSettings`: the Daemon screen on its own, over an in-memory config API.
    @MainActor static func settingsRoot() -> UIViewController {
        let fake = LeoFakeConfigClient(
            schema: LeoConfigSchema(resources: []),
            singletons: [LeoAgentBriefWire.configResource: LeoConfigItem(
                name: "", values: [LeoAgentBriefWire.enabledField: .bool(arguments.contains("-briefSettingsOn"))]
            )]
        )
        let connection = DaemonConnection(daemon: daemon, secrets: DaemonSecrets(token: "fixture"))
        let store = withDependencies {
            $0.configClients = ConfigClients(client: { _ in fake })
        } operation: {
            Store(initialState: DaemonSettings.State(daemon: daemon, connection: connection, supportsBrief: true)) { DaemonSettings() }
        }
        let restart = Store(initialState: MachineRestart.State(machine: daemon.name, connection: connection)) { MachineRestart() }
        return UINavigationController(rootViewController: DaemonViewController(store: store, restart: restart))
    }
}
#endif
