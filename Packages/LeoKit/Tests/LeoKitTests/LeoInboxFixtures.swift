import Foundation

@testable import LeoKit

/// Shared builders for the inbox tests.
enum LeoInboxFixtures {
    static let host = LeoHostID.remote("mars")
    static let epoch = Date(timeIntervalSince1970: 1_795_539_600)

    static func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    static func id(_ name: String, host: LeoHostID = host) -> LeoAgentID { LeoAgentID(host: host, name: name) }

    static func agent(
        _ name: String, host: LeoHostID = host, project: String? = nil, signal: LeoAttentionSignal? = nil,
        bootID: String? = "boot", isStale: Bool = false, brief: LeoAgentBrief? = nil
    ) -> LeoInboxAgent {
        LeoInboxAgent(
            id: id(name, host: host), name: name, machine: host.displayName, project: project, signal: signal, bootID: bootID,
            isStale: isStale, brief: brief
        )
    }

    static func signal(
        _ state: LeoAttentionState, _ revision: Int = 1, reason: LeoAttentionReason? = nil, preview: String? = nil, at: TimeInterval? = nil
    ) -> LeoAttentionSignal {
        LeoAttentionSignal(state: state, revision: revision, reason: reason, preview: preview, at: at.map(Self.at))
    }

    static func ask(
        _ messageID: String, agent: String, kind: LeoChatMessage.Kind = .ask, state: String = "open", at: TimeInterval = 0,
        direction: LeoChatMessage.Direction = .outbound, text: String = "Which one?"
    ) -> LeoChatMessage {
        LeoChatMessage(
            id: messageID, agent: agent, direction: direction, kind: kind, text: text, state: state, ts: Self.at(at),
            input: kind == .ask ? try? LeoChatInput(kind: .buttons, options: [LeoChatOption(value: "a", label: "A")]) : nil
        )
    }

    static func chat(_ messageID: String, agent: String, text: String, at: TimeInterval = 0) -> LeoChatMessage {
        LeoChatMessage(id: messageID, agent: agent, direction: .outbound, kind: .text, text: text, ts: Self.at(at))
    }

    static func threadMap(_ asks: [LeoChatMessage], context: String? = nil) -> [LeoAgentID: LeoOpenAskThread] {
        Dictionary(grouping: asks, by: \.agent).reduce(into: [:]) { result, pair in
            result[id(pair.key)] = LeoOpenAskThread(asks: pair.value.sorted { $0.ts < $1.ts }, context: context)
        }
    }
}
