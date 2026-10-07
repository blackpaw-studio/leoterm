import Foundation

/// Why a compaction ran (`agent_compaction.trigger`).
enum LeoCompactionTrigger: String, Equatable, Sendable {
    case manual, auto
}

/// Where a compaction is (`agent_compaction.phase`).
enum LeoCompactionPhase: String, Equatable, Sendable {
    case started, completed, failed
}

/// One `agent_compaction` event (leo >= 0.35). `contextPercent` is the
/// value from before the compaction, so it is decoded but never shown;
/// rows show the context from `/state`.
struct LeoCompactionEvent: Equatable, Sendable {
    let agent: String
    let phase: LeoCompactionPhase
    let trigger: LeoCompactionTrigger?
    let contextPercent: Double?
}

extension LeoCompactionEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case agent, phase, trigger
        case contextPercent = "context_percent"
    }

    /// An unknown phase fails the decode (the event is then sequence-only);
    /// an unknown trigger or an unusable percent just reads as absent.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phase = try container.decode(String.self, forKey: .phase)
        guard let known = LeoCompactionPhase(rawValue: phase) else {
            throw DecodingError.dataCorruptedError(forKey: .phase, in: container, debugDescription: "unknown phase")
        }
        self.init(
            agent: try container.decode(String.self, forKey: .agent), phase: known,
            trigger: (try? container.decode(String.self, forKey: .trigger)).flatMap(LeoCompactionTrigger.init(rawValue:)),
            contextPercent: try? container.decode(Double.self, forKey: .contextPercent)
        )
    }
}
