import Foundation

/// One task an agent advertised (leo `agent_progress`): a build, deploy or
/// test sweep with optional progress. The daemon owns the data; this is the
/// decoded wire value. Decoding is lenient (see `LeoAgentTaskWire`).
public struct LeoAgentTask: Equatable, Sendable, Identifiable {
    public enum Mode: String, Equatable, Sendable { case determinate, indeterminate }
    public enum State: String, Equatable, Sendable { case running, succeeded, failed, cancelled }

    public let id: String
    public let title: String
    public let mode: Mode
    /// 0...100; only for a determinate task.
    public let percent: Double?
    public let status: String?
    /// The agent-supplied ETA, absolute.
    public let etaAt: Date?
    public let state: State
    /// Running with no update for 15 minutes (daemon-computed).
    public let stale: Bool
    public let startedAt: Date
    public let updatedAt: Date
    public let endedAt: Date?
    /// Per-task and monotonic; resets only when the task is removed.
    public let revision: Int

    public init(
        id: String, title: String, mode: Mode = .indeterminate, percent: Double? = nil, status: String? = nil,
        etaAt: Date? = nil, state: State = .running, stale: Bool = false, startedAt: Date,
        updatedAt: Date? = nil, endedAt: Date? = nil, revision: Int = 1
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.percent = percent
        self.status = status
        self.etaAt = etaAt
        self.state = state
        self.stale = stale
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.endedAt = endedAt
        self.revision = revision
    }

    public var isRunning: Bool { state == .running }
    public var hasEnded: Bool { state != .running }
}

extension LeoAgentTask: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LeoEnvironmentsWire.Key.self)
        func key(_ name: String) -> LeoEnvironmentsWire.Key { .init(stringValue: name) }
        func string(_ name: String) -> String? { (try? c.decodeIfPresent(String.self, forKey: key(name))) ?? nil }
        func date(_ name: String) -> Date? { string(name).flatMap(LeoAgentTaskWire.date) }

        let id = try c.decode(String.self, forKey: key("id"))
        guard !id.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "empty task id"))
        }
        let rawPercent = (try? c.decodeIfPresent(Double.self, forKey: key("percent"))) ?? nil
        let percent = rawPercent.map { min(max($0, 0), 100) }
        let started = date("started_at") ?? date("updated_at") ?? Date(timeIntervalSince1970: 0)
        self.init(
            id: id,
            title: string("title") ?? id,
            mode: string("mode").flatMap(Mode.init(rawValue:)) ?? (percent == nil ? .indeterminate : .determinate),
            percent: percent,
            status: string("status").flatMap { $0.isEmpty ? nil : $0 },
            etaAt: date("eta_at"),
            state: string("state").flatMap(State.init(rawValue:)) ?? .running,
            stale: ((try? c.decodeIfPresent(Bool.self, forKey: key("stale"))) ?? nil) ?? false,
            startedAt: started,
            updatedAt: date("updated_at") ?? started,
            endedAt: date("ended_at"),
            revision: ((try? c.decodeIfPresent(Int.self, forKey: key("revision"))) ?? nil) ?? 0
        )
    }
}
