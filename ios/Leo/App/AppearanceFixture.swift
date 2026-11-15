#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// One machine on leo 0.60 (`agent_appearance`) with the four looks an
/// Agents row can have (`-appearanceFixture`), for the Appearance
/// screenshots. `-appearanceSheet <agent>` opens that agent's sheet and
/// `-appearanceSheetLarge` opens it at the large detent and
/// `-appearanceSelect <agent>` selects its row. Writes stay in memory. No
/// daemon is needed.
enum AppearanceFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-appearanceFixture") }

    static var prefersLargeSheet: Bool { ProcessInfo.processInfo.arguments.contains("-appearanceSheetLarge") }
    static var sheetAgent: String? { argument(after: "-appearanceSheet") }
    static var selectedAgent: String? { argument(after: "-appearanceSelect") }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    private static let daemon = PairedDaemon(
        id: "fixture-Dionysus", name: "Dionysus", baseURL: URL(string: "https://dionysus.lan")!, urls: [],
        deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
    )

    private static let rules = [
        LeoAppearanceRule(field: "environments", op: "contains", value: "homelab", color: "teal"),
        LeoAppearanceRule(field: "name", op: "glob", value: "olymp*", emoji: "🎩"),
    ]

    /// Both, emoji only, color only, neither: one of each, in the list's
    /// attention order.
    private static let looks: [String: LeoAgentAppearance] = [
        "olympus": LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0)),
        "athena": LeoAgentAppearance(emoji: "🦉", color: nil, emojiSource: .manual),
        "hermes": LeoAgentAppearance(emoji: nil, color: .orange, colorSource: .manual),
    ]

    private static func agent(_ name: String, activity: LeoActivity, attention: LeoAttentionSignal? = nil) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: .running, activity: activity, currentAction: nil, lastActivityAt: nil, attention: attention,
            startedAt: nil, template: "coding", harness: "claude", appearance: looks[name]
        )
    }

    private static let state = LeoObservedState(agents: [
        agent("athena", activity: .idle, attention: LeoAttentionSignal(state: .needsInput, revision: 1)),
        agent("olympus", activity: .working),
        agent("hermes", activity: .idle),
        agent("apollo", activity: .idle),
    ])

    static func prepare(_ values: inout DependencyValues) {
        let written = LockIsolated<[String: LeoAgentAppearance?]>([:])
        values.pairedDaemons.load = { [daemon] in [daemon] }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.events = { _ in
            AsyncThrowingStream {
                $0.yield(.hello(seq: 1, at: nil, version: "0.60.0", serverTime: nil, bootID: "fixture", features: ["agent_appearance", "agent_environments"]))
            }
        }
        values.daemonClient.fetchState = { [state] _ in state }
        values.daemonClient.appearanceRules = { _ in rules }
        values.daemonClient.setAppearance = { _, agent, emoji, color in
            written.withValue { writes in
                let current = writes[agent] ?? looks[agent]
                writes[agent] = .some(LeoAppearanceText.optimistic(current, emoji: emoji, color: color))
                return writes[agent] ?? nil
            }
        }
        // No permission prompt over the screenshots.
        values.pushClient.authorization = { .denied }
        values.chatClient.threads = { _ in [] }
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
        values.chatClient.markRead = { _, _, _ in }
    }

    /// Once the fleet has the agents: selects a row and opens a sheet, as asked.
    @MainActor static func open(_ store: StoreOf<AppFeature>) {
        Task { @MainActor in
            let ref = { AgentRef(daemonID: daemon.id, name: $0) }
            while store.fleet.sessions[id: daemon.id]?.supportsAppearance != true { try? await Task.sleep(for: .milliseconds(50)) }
            if let name = selectedAgent { store.send(.agentTapped(ref(name))) }
            if let name = sheetAgent { store.send(.appearanceRequested(ref(name))) }
        }
    }
}
#endif
