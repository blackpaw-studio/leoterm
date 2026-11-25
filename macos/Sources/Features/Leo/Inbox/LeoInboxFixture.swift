#if DEBUG
import Foundation
import LeoKit

/// DEBUG builds only: replaces the inbox's agents and open asks with a JSON
/// file named by `LEO_INBOX_FIXTURE`, so it can be screenshotted without
/// real agents asking. The window comes up with the Inbox row selected.
/// ```
/// {"selected": "leoterm", "agents": [
///   {"name": "leoterm", "host": "local", "project": "leoterm", "state": "needs_input", "ageSeconds": 240,
///    "ask": {"text": "Ship tonight?", "input": "radio", "options": ["Ship tonight", "Hold"], "context": "CI is green."}},
///   {"name": "brooklyn-cam", "host": "Hestia", "state": "needs_input", "ageSeconds": 1600,
///    "reason": {"kind": "permission", "tool": "Bash", "detail": "nomad job run x"}},
///   {"name": "assistant", "state": "finished", "preview": "Booked Thursday.", "ageSeconds": 2400, "read": false}]}
/// ```
struct LeoInboxFixture: Decodable {
    struct Agent: Decodable {
        struct Reason: Decodable {
            let kind: String
            let tool: String?
            let detail: String?
        }

        struct Ask: Decodable {
            let text: String
            let input: String
            let options: [String]?
            let context: String?
        }

        struct Brief: Decodable {
            let goal: String?
            let status: String?
            let decisions: [String]?
            let open: [String]?
            /// Seconds before now the brief was written.
            let ageSeconds: Int?
        }

        let name: String
        let brief: Brief?
        let host: String?
        let project: String?
        let state: String
        let preview: String?
        let ageSeconds: Int
        let reason: Reason?
        let ask: Ask?
        let read: Bool?
    }

    let agents: [Agent]
    let selected: String?
    /// Lists this agent in the sidebar and selects it app-wide, so the
    /// toolbar has an agent to (wrongly) show while the Inbox is selected.
    let shownAgent: String?

    static let environmentKey = "LEO_INBOX_FIXTURE"

    static func loadFile() -> LeoInboxFixture? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey],
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(LeoInboxFixture.self, from: data)
    }

    @MainActor func install(into inbox: LeoInboxModel, now: Date = Date()) {
        var agents: [LeoInboxAgent] = []
        var messages: [LeoChatMessage] = []
        var seen = LeoInboxSeenState()
        for (index, agent) in self.agents.enumerated() {
            let host: LeoHostID = agent.host.map { $0 == "local" ? .local : .remote($0) } ?? .local
            let id = LeoAgentID(host: host, name: agent.name)
            let at = now.addingTimeInterval(-TimeInterval(agent.ageSeconds))
            let state = LeoAttentionState(rawValue: agent.state) ?? .unknown
            let reason = agent.reason.flatMap { reason in
                LeoAttentionReason.Kind(rawValue: reason.kind).map { LeoAttentionReason(kind: $0, tool: reason.tool, detail: reason.detail) }
            }
            let signal = LeoAttentionSignal(state: state, revision: index + 1, reason: reason, preview: agent.preview, at: at)
            let brief = agent.brief.map {
                LeoAgentBrief(
                    goal: $0.goal, status: $0.status, decisions: $0.decisions ?? [], open: $0.open ?? [],
                    updatedAt: now.addingTimeInterval(-TimeInterval($0.ageSeconds ?? 0))
                )
            }
            agents.append(LeoInboxAgent(
                id: id, name: agent.name, machine: LeoInboxAgents.machineName(host), project: agent.project, signal: signal, brief: brief
            ))
            if agent.read == true { seen.markSeen(id, at: at, revision: index + 1, bootID: nil, now: now) }
            if let ask = agent.ask { messages += Self.messages(for: ask, agent: agent.name, at: at) }
        }
        inbox.installFixture(agents: agents, messages: messages, seen: seen)
        if let selected { inbox.select(agents.first { $0.name == selected }?.id) }
    }

    /// The generation outranks every live snapshot, so the feed's later
    /// (failed-connection) ones can't replace the row.
    @MainActor func installShownAgent(into model: LeoSidebarModel) {
        guard let shownAgent else { return }
        let row = LeoAgentRow(
            host: .local, name: shownAgent, template: nil, status: .running, activity: .idle, actionDetail: nil,
            workspace: "/tmp/\(shownAgent)", startedAt: "s"
        )
        model.receive(LeoSidebarSnapshot(rows: [row], connectivity: .connected, generation: .max), for: .local)
        model.userSelected(row.id)
    }

    private static func messages(for ask: Agent.Ask, agent: String, at: Date) -> [LeoChatMessage] {
        let options = (ask.options ?? []).map { LeoChatOption(value: $0, label: $0) }
        let kind = LeoChatInput.Kind(rawValue: ask.input) ?? .text
        guard let input = try? LeoChatInput(kind: kind, options: options, allowsText: kind != .text && kind != .buttons) else { return [] }
        var result: [LeoChatMessage] = []
        if let context = ask.context {
            result.append(LeoChatMessage(
                id: "\(agent)-context", agent: agent, direction: .outbound, kind: .text, text: context, ts: at.addingTimeInterval(-30)
            ))
        }
        result.append(LeoChatMessage(
            id: "\(agent)-ask", agent: agent, direction: .outbound, kind: .ask, text: ask.text, state: "open", ts: at, input: input
        ))
        return result
    }
}
#endif
