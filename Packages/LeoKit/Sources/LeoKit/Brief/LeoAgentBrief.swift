import Foundation

/// An agent's own short summary of its current work (`agent_brief`). Every
/// field is optional plain text; use `LeoAgentBriefPresentation` to show it.
public struct LeoAgentBrief: Equatable, Sendable {
    public let goal: String?
    public let status: String?
    public let decisions: [String]
    public let open: [String]
    /// Daemon time of the last write; nil when absent or unparseable.
    public let updatedAt: Date?

    public init(goal: String? = nil, status: String? = nil, decisions: [String] = [], open: [String] = [], updatedAt: Date? = nil) {
        self.goal = goal
        self.status = status
        self.decisions = decisions
        self.open = open
        self.updatedAt = updatedAt
    }
}

extension LeoAgentBrief: Decodable {
    private enum CodingKeys: String, CodingKey {
        case goal, status, decisions, open
        case updatedAt = "updated_at"
    }

    /// Strict about shape (a wrong type throws, so callers drop the whole
    /// brief), lenient about absence.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        open = try c.decodeIfPresent([String].self, forKey: .open) ?? []
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)).flatMap { $0 }.flatMap(LeoAgentBriefWire.date)
    }
}

/// The only place that knows the brief wire format. Decoding never fails its
/// parent: a malformed brief reads as none.
public enum LeoAgentBriefWire {
    public static let key = "brief"
    public static let eventType = "agent_brief"
    public static let configEventType = "brief_config_changed"
    /// The daemon config resource; the switch is its `enabled` field.
    public static let configResource = "brief"
    public static let enabledField = "enabled"

    static func date(_ string: String) -> Date? { LeoAgentTaskWire.date(string) }

    private struct Lenient: Decodable {
        let value: LeoAgentBrief?
        init(from decoder: any Decoder) throws { value = try? LeoAgentBrief(from: decoder) }
    }

    /// An agent object's `brief`; nil when absent, null or malformed.
    static func agent(from decoder: any Decoder) -> LeoAgentBrief? {
        guard let container = try? decoder.container(keyedBy: LeoEnvironmentsWire.Key.self),
              let wrapped = try? container.decodeIfPresent(Lenient.self, forKey: .init(stringValue: key))
        else { return nil }
        return wrapped.value
    }

    struct EventPayload: Decodable {
        let seq: Int
        let at: String?
        let agent: String
        /// Nil means the brief was cleared.
        let brief: LeoAgentBrief?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: LeoEnvironmentsWire.Key.self)
            seq = try c.decode(Int.self, forKey: .init(stringValue: "seq"))
            at = try? c.decodeIfPresent(String.self, forKey: .init(stringValue: "at"))
            agent = try c.decode(String.self, forKey: .init(stringValue: "agent"))
            let briefKey = LeoEnvironmentsWire.Key(stringValue: LeoAgentBriefWire.key)
            brief = try c.decodeNil(forKey: briefKey) ? nil : try c.decode(LeoAgentBrief.self, forKey: briefKey)
        }
    }

    /// An `agent_brief` payload; nil when malformed (the caller keeps only the sequence).
    static func event(_ data: Data) -> EventPayload? {
        guard let payload = try? JSONDecoder().decode(EventPayload.self, from: data), !payload.agent.isEmpty else { return nil }
        return payload
    }

    struct ConfigPayload: Decodable {
        let seq: Int
        let enabled: Bool
    }

    static func configEnabled(_ data: Data) -> ConfigPayload? {
        try? JSONDecoder().decode(ConfigPayload.self, from: data)
    }
}
