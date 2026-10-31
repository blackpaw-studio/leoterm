#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// One machine with three agents and a scripted chat client
/// (`-navFixture`), for driving the Agents → detail → chat navigation stack
/// in UI tests. No daemon is needed.
enum NavFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-navFixture") || isRichInbox }

    /// `-inboxFixture`: agents in every status, with chat history, for inbox screenshots.
    static var isRichInbox: Bool { ProcessInfo.processInfo.arguments.contains("-inboxFixture") }

    static let agentNames = ["agent-0", "agent-1", "agent-2"]

    private static let daemon = PairedDaemon(
        id: "fixture-Dionysus", name: "Dionysus", baseURL: URL(string: "https://dionysus.lan")!, urls: [],
        deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
    )

    private static let state = LeoObservedState(agents: isRichInbox ? richAgents : agentNames.map {
        LeoObservedAgent(name: $0, status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, attention: nil, startedAt: nil, template: "coding", harness: "claude")
    })

    private static func rich(
        _ name: String, _ state: LeoAttentionState?, emoji: String? = nil, color: LeoAppearanceColor? = nil
    ) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: .running, activity: state == .working ? .working : .idle, currentAction: nil, lastActivityAt: nil,
            attention: state.map { LeoAttentionSignal(state: $0, revision: 1) }, startedAt: nil, template: "coding", harness: "claude",
            appearance: emoji == nil && color == nil ? nil : LeoAgentAppearance(emoji: emoji, color: color, emojiSource: .manual, colorSource: .manual)
        )
    }

    private static let richAgents = [
        rich("assistant", nil), rich("zeus", .needsInput, emoji: "⚡️", color: .yellow), rich("hera", .errored, emoji: "👑", color: .purple),
        rich("apollo", .working, emoji: "☀️", color: .orange), rich("athena", .finished, emoji: "🦉", color: .teal), rich("ares", nil, emoji: "🛡️", color: .red),
    ]

    private static func message(_ id: String, _ agent: String, _ text: String, minutesAgo: Int, kind: LeoChatMessage.Kind = .text) -> LeoChatMessage {
        LeoChatMessage(
            id: id, agent: agent, direction: .outbound, kind: kind, text: text, ts: Date().addingTimeInterval(-Double(minutesAgo) * 60)
        )
    }

    private static let richThreads = [
        LeoChatThread(agent: "assistant", lastMessage: message("a", "assistant", "Morning. Nothing is blocked; two PRs are waiting on review.", minutesAgo: 190), isPinned: true),
        LeoChatThread(agent: "zeus", lastMessage: message("b", "zeus", "Deploy to prod, or hold for Evan's sign-off?", minutesAgo: 4, kind: .ask), unread: 1),
        LeoChatThread(agent: "hera", lastMessage: message("c", "hera", "Migration failed on step 3: relation \"users\" already exists.", minutesAgo: 22), unread: 2),
        LeoChatThread(agent: "apollo", lastMessage: message("d", "apollo", "Running the full suite now, about 40% through.", minutesAgo: 9)),
        LeoChatThread(agent: "athena", lastMessage: message("e", "athena", "Report is ready: 14 findings, 3 high.", minutesAgo: 75)),
        LeoChatThread(agent: "ares", lastMessage: message("f", "ares", "Standing by.", minutesAgo: 1_700)),
    ]

    /// Replaces the paired daemons, keychain, daemon transport and chat client.
    static func prepare(_ values: inout DependencyValues) {
        values.pairedDaemons.load = { [daemon] in [daemon] }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.events = { _ in
            AsyncThrowingStream { $0.yield(.hello(seq: 1, at: nil, version: "0.57.0", serverTime: nil)) }
        }
        values.daemonClient.fetchState = { [state] _ in state }
        values.chatClient.threads = { _ in isRichInbox ? richThreads : agentNames.map { LeoChatThread(agent: $0) } }
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
        values.chatClient.markRead = { _, _, _ in }
    }
}
#endif
