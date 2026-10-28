#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// One machine on a daemon with `agent_move` (`-moveFixture`), for the move,
/// copy and duplicate screenshots and UI test. The daemon is scripted in
/// memory: `busy-agent` is mid-turn, so its move is refused until forced;
/// a move to `work` is refused as unreachable; a move to `hestia` or `nas`
/// leaves a dormant record; a copy adds `<name>-copy`.
enum MoveFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-moveFixture") }

    private static let daemon = PairedDaemon(
        id: "fixture-Dionysus", name: "Dionysus", baseURL: URL(string: "https://dionysus.lan")!, urls: [],
        deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
    )

    private static func agent(_ name: String, activity: LeoActivity = .idle, status: LeoAgentStatus = .running, movedTo: String? = nil, movedAt: String? = nil) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: status, activity: activity, currentAction: nil, lastActivityAt: nil,
            startedAt: nil, template: "coding", harness: "claude", movedTo: movedTo, movedAt: movedAt
        )
    }

    private static func fiveMinutesAgo() -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
    }

    private static let initial = [
        agent("zeus"),
        agent("busy-agent", activity: .working),
        agent("old-agent", status: .stopped, movedTo: "nas", movedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))),
    ]

    static func prepare(_ values: inout DependencyValues) {
        let world = LockIsolated(initial)
        values.pairedDaemons.load = { [daemon] in [daemon] }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.events = { _ in
            AsyncThrowingStream {
                $0.yield(.hello(seq: 1, at: nil, version: "0.70.0", serverTime: nil, bootID: "fixture", features: ["agent_move"]))
            }
        }
        values.daemonClient.fetchState = { _ in LeoObservedState(agents: world.value) }
        values.daemonClient.moveHosts = { _ in .hosts(["hestia", "nas", "work"]) }
        values.daemonClient.move = { _, name, request in
            if request.to == "work" {
                return .refused(code: "host_unreachable", message: "work is unreachable over SSH.", offersForce: false)
            }
            return world.withValue { agents in
                guard let index = agents.firstIndex(where: { $0.name == name }) else {
                    return .unknown("The daemon has no agent named \(name).")
                }
                switch request.mode {
                case .move:
                    if agents[index].activity == .working, !request.force {
                        return .refused(code: "agent_busy", message: "This agent is in the middle of a turn.", offersForce: true)
                    }
                    agents[index] = agent(name, status: .stopped, movedTo: request.to, movedAt: fiveMinutesAgo())
                case .copy:
                    agents.append(agent(request.name ?? "\(name)-copy"))
                }
                return .done(LeoMoveResult(name: name, to: request.to))
            }
        }
        // No permission prompt over the screenshots.
        values.pushClient.authorization = { .denied }
        values.chatClient.threads = { _ in [] }
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
        values.chatClient.markRead = { _, _, _ in }
    }
}
#endif
