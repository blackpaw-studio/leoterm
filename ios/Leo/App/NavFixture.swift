#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// One machine with three agents and a scripted chat client
/// (`-navFixture`), for driving the Agents → detail → chat navigation stack
/// in UI tests. No daemon is needed.
enum NavFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-navFixture") || isRichInbox || ChatScrollFixture.isRequested || ChatImagesFixture.isRequested || ChatMarkdownFixture.isRequested }

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
        _ name: String, _ state: LeoAttentionState?, emoji: String? = nil, color: LeoAppearanceColor? = nil,
        reason: LeoAttentionReason? = nil, preview: String? = nil, minutesAgo: Int = 5
    ) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: .running, activity: state == .working ? .working : .idle, currentAction: nil, lastActivityAt: nil,
            attention: state.map { LeoAttentionSignal(state: $0, revision: 1, reason: reason, preview: preview, at: Date().addingTimeInterval(-Double(minutesAgo) * 60)) },
            startedAt: nil, template: "coding", harness: "claude",
            appearance: emoji == nil && color == nil ? nil : LeoAgentAppearance(emoji: emoji, color: color, emojiSource: .manual, colorSource: .manual)
        )
    }

    /// `-inboxScenario empty|dot`: no blocked items; `dot` leaves finished ones unread (grey badge dot).
    private static var scenario: String? {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.firstIndex(of: "-inboxScenario").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    private static let blockedAgents: Set<String> = ["zeus", "olympus", "brooklyn-cam"]

    private static var richAgents: [LeoObservedAgent] {
        guard let scenario else { return allRichAgents }
        let quiet = allRichAgents.filter { !blockedAgents.contains($0.name) }
        return scenario == "dot" ? quiet : quiet.filter { $0.name != "athena" && $0.name != "hera" && $0.name != "assistant" }
    }

    private static let allRichAgents = [
        rich("assistant", .finished, emoji: "🎩", color: .green, preview: "Booked Thursday 2:00 PM with Dr. Patel; it's on your calendar.", minutesAgo: 41),
        rich("zeus", .needsInput, emoji: "⚡️", color: .yellow, minutesAgo: 4),
        rich("olympus", .working, emoji: "🏛️", color: .yellow, minutesAgo: 12),
        rich(
            "brooklyn-cam", .needsInput, emoji: "📹", color: .red,
            reason: LeoAttentionReason(kind: .permission, tool: "Bash", detail: "nomad job run jobs/brooklyn-cam.nomad"), minutesAgo: 27
        ),
        rich("hera", .errored, emoji: "👑", color: .purple, preview: "release.yml failed: notarytool rejected leo-helper (invalid signature).", minutesAgo: 120),
        rich("apollo", .working, emoji: "☀️", color: .orange),
        rich("athena", .finished, emoji: "🦉", color: .teal, preview: "Report is ready: 14 findings, 3 high.", minutesAgo: 75),
        rich("ares", .finished, emoji: "🛡️", color: .red, preview: "Merged usage plugin to main (8a1fc50b9).", minutesAgo: 1_700),
    ]

    /// Every open ask the rich inbox shows: a choice ask with a reply escape, and a text ask.
    private static let richAsks: [LeoChatMessage] = [
        LeoChatMessage(
            id: "b", agent: "zeus", direction: .outbound, kind: .ask, text: "Ship Voice-to-Agent in leo-v0.31 tonight, or hold for device checks?",
            state: "open", ts: Date().addingTimeInterval(-240),
            input: try? LeoChatInput(kind: .buttons, options: [
                LeoChatOption(value: "ship", label: "Ship tonight"), LeoChatOption(value: "hold", label: "Hold for device checks"),
                LeoChatOption(value: "half", label: "Ship the Mac half only"),
            ], allowsText: true)
        ),
        LeoChatMessage(
            id: "o", agent: "olympus", direction: .outbound, kind: .ask, text: "Prometheus has 412 GB free. What cap should I set for the Plex transcode cache?",
            state: "open", ts: Date().addingTimeInterval(-720), input: try? LeoChatInput(kind: .text)
        ),
    ]

    private static func message(_ id: String, _ agent: String, _ text: String, minutesAgo: Int, kind: LeoChatMessage.Kind = .text) -> LeoChatMessage {
        LeoChatMessage(
            id: id, agent: agent, direction: .outbound, kind: kind, text: text, ts: Date().addingTimeInterval(-Double(minutesAgo) * 60)
        )
    }

    private static var richThreads: [LeoChatThread] {
        scenario == nil ? allRichThreads : allRichThreads.filter { !blockedAgents.contains($0.agent) }
    }

    private static let allRichThreads = [
        LeoChatThread(agent: "assistant", lastMessage: message("a", "assistant", "Morning. Nothing is blocked; two PRs are waiting on review.", minutesAgo: 190), isPinned: true),
        LeoChatThread(agent: "zeus", lastMessage: richAsks[0], unread: 1),
        LeoChatThread(agent: "olympus", lastMessage: richAsks[1]),
        LeoChatThread(agent: "hera", lastMessage: message("c", "hera", "Migration failed on step 3: relation \"users\" already exists.", minutesAgo: 22), unread: 2),
        LeoChatThread(agent: "apollo", lastMessage: message("d", "apollo", "Running the full suite now, about 40% through.", minutesAgo: 9)),
        LeoChatThread(agent: "athena", lastMessage: message("e", "athena", "Report is ready: 14 findings, 3 high.", minutesAgo: 75)),
        LeoChatThread(agent: "ares", lastMessage: message("f", "ares", "Standing by.", minutesAgo: 1_700)),
    ]

    /// Zeus's thread in the rich inbox: a button ask waiting on an answer.
    private static let zeusMessages: [LeoChatMessage] = [
        message("z0", "zeus", "Tests are green and the release branch is cut.", minutesAgo: 6),
        LeoChatMessage(
            id: "b", agent: "zeus", direction: .outbound, kind: .ask, text: "Deploy to prod, or hold for Evan's sign-off?", state: "open",
            ts: Date().addingTimeInterval(-240),
            input: try? LeoChatInput(kind: .buttons, options: [
                LeoChatOption(value: "deploy", label: "Deploy to prod"),
                LeoChatOption(value: "hold", label: "Hold for sign-off"),
                LeoChatOption(value: "rollback", label: "Roll back the last release"),
            ])
        ),
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
        values.chatClient.messages = { _, agent, _ in
            LeoChatPage(messages: isRichInbox && agent == "zeus" ? zeusMessages : [], hasMore: false)
        }
        values.chatClient.markRead = { _, _, _ in }
        values.chatClient.openAsks = { _ in isRichInbox ? (scenario == nil ? richAsks : []) : nil }
        values.chatClient.seen = { _ in isRichInbox ? ["ares": Date()] : nil }
        values.chatClient.markSeen = { _, agents in Dictionary(uniqueKeysWithValues: agents.map { ($0, Date()) }) }
        values.chatClient.answer = { _, agent, id, _ in
            LeoChatMessage(id: id, agent: agent, direction: .outbound, kind: .ask, text: "", state: "answered", ts: Date())
        }
        values.inboxSeenStore.load = { LeoInboxSeenState() }
        values.inboxSeenStore.save = { _ in }
        if ChatScrollFixture.isRequested { ChatScrollFixture.prepare(&values) }
        if ChatImagesFixture.isRequested { ChatImagesFixture.prepare(&values) }
        if ChatMarkdownFixture.isRequested { ChatMarkdownFixture.prepare(&values) }
    }
}
#endif
