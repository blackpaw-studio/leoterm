#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// One machine with three agents and a scripted chat client
/// (`-navFixture`), for driving the Agents → detail → chat navigation stack
/// in UI tests. No daemon is needed.
enum NavFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-navFixture") }

    static let agentNames = ["agent-0", "agent-1", "agent-2"]

    private static let daemon = PairedDaemon(
        id: "fixture-Dionysus", name: "Dionysus", baseURL: URL(string: "https://dionysus.lan")!, urls: [],
        deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
    )

    private static let state = LeoObservedState(agents: agentNames.map {
        LeoObservedAgent(name: $0, status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, attention: nil, startedAt: nil, template: "coding", harness: "claude")
    })

    /// Replaces the paired daemons, keychain, daemon transport and chat client.
    static func prepare(_ values: inout DependencyValues) {
        values.pairedDaemons.load = { [daemon] in [daemon] }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.events = { _ in
            AsyncThrowingStream { $0.yield(.hello(seq: 1, at: nil, version: "0.57.0", serverTime: nil)) }
        }
        values.daemonClient.fetchState = { [state] _ in state }
        values.chatClient.threads = { _ in agentNames.map { LeoChatThread(agent: $0) } }
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
        values.chatClient.markRead = { _, _, _ in }
    }
}
#endif
