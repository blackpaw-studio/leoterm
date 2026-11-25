import Foundation
import LeoKit

/// One line of an agent's brief as a list shows it.
public struct AgentBriefRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case goal, status, decision, open, updated }

    public let kind: Kind
    public let text: String
    /// Draw in secondary color: a stale brief's age.
    public let isMuted: Bool
}

/// The brief as ordered rows, in the spec's order: goal, status, decisions,
/// open items, age. Pure, so the agent detail screen and the chat header share it.
public enum AgentBriefRows {
    public static func make(_ brief: LeoAgentBriefPresentation?) -> [AgentBriefRow] {
        guard let brief else { return [] }
        let leading = [(AgentBriefRow.Kind.goal, brief.goal), (.status, brief.status)].compactMap { kind, text in
            text.map { AgentBriefRow(kind: kind, text: $0, isMuted: false) }
        }
        let bullets = brief.decisions.map { AgentBriefRow(kind: .decision, text: $0, isMuted: false) }
            + brief.open.map { AgentBriefRow(kind: .open, text: $0, isMuted: false) }
        let age = brief.ageText.map { [AgentBriefRow(kind: .updated, text: "Updated \($0)", isMuted: brief.isStale)] } ?? []
        return leading + bullets + age
    }
}
