import Foundation

/// The only place that knows the agent-progress wire format: key names, the
/// event type and the dismiss route. Decoding is lenient throughout: a
/// malformed task is dropped and a missing `tasks` reads as none, so `/state`
/// and the event stream never fail on it.
public enum LeoAgentTaskWire {
    public static let key = "tasks"
    public static let eventType = "agent_task_changed"
    /// `DELETE /agents/{name}/tasks/{id}`, unprefixed on the socket and under `/api/v1` on the web.
    public static let dismissAction = "tasks"

    /// RFC 3339, with or without fractional seconds. Nil when malformed.
    static func date(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: string) ?? fractional.date(from: string)
    }

    private struct LenientTask: Decodable {
        let value: LeoAgentTask?
        init(from decoder: any Decoder) throws { value = try? LeoAgentTask(from: decoder) }
    }

    /// An agent object's `tasks`; empty when absent or malformed.
    static func agent(from decoder: any Decoder) -> [LeoAgentTask] {
        guard let container = try? decoder.container(keyedBy: LeoEnvironmentsWire.Key.self),
              let list = try? container.decodeIfPresent([LenientTask].self, forKey: .init(stringValue: key))
        else { return [] }
        return list.compactMap(\.value)
    }

    struct EventPayload: Decodable {
        let seq: Int
        let at: String?
        let agent: String
        let id: String
        /// Nil means the task was removed.
        let task: LeoAgentTask?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: LeoEnvironmentsWire.Key.self)
            seq = try c.decode(Int.self, forKey: .init(stringValue: "seq"))
            at = try? c.decodeIfPresent(String.self, forKey: .init(stringValue: "at"))
            agent = try c.decode(String.self, forKey: .init(stringValue: "agent"))
            id = try c.decode(String.self, forKey: .init(stringValue: "id"))
            let taskKey = LeoEnvironmentsWire.Key(stringValue: "task")
            task = try c.decodeNil(forKey: taskKey) ? nil : try c.decode(LeoAgentTask.self, forKey: taskKey)
        }
    }

    /// An `agent_task_changed` payload; nil when malformed, so the caller
    /// keeps only its sequence.
    static func event(_ data: Data) -> EventPayload? {
        try? JSONDecoder().decode(EventPayload.self, from: data)
    }
}
