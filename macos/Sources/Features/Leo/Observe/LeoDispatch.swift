import Foundation

/// One leo dispatch as the daemon reports it (`Snapshot.dispatches[]` and
/// `dispatch_changed.dispatch`, leo >= 0.35, `dispatch_tree` feature).
/// Token and cost fields are left out on purpose: nothing here shows them,
/// and decoding them would only make every 1 s token tick look like a change.
struct LeoDispatch: Decodable, Equatable, Sendable {
    /// Every status the daemon treats as the end of a dispatch
    /// (leo `consult.Status.Terminal`).
    static let terminalStatuses: Set<String> = ["done", "failed", "timeout", "canceled", "closed", "released"]

    let id: String
    let name: String?
    let role: String?
    let template: String?
    let model: String?
    let status: String
    let stalled: Bool
    let callerAgent: String?
    let parentDispatchID: String?
    let startedAt: String?
    let endedAt: String?
    /// The daemon can attach a terminal to this dispatch (leo >= the
    /// `dispatch_attach` feature). Absent on older daemons: false.
    let attachable: Bool
    /// The tmux pane (`%N`) the daemon placed this dispatch's viewer in,
    /// attachable or not. Absent when headless, on older daemons, or when
    /// the value isn't a pane id.
    let tmuxTarget: String?

    init(
        id: String, name: String? = nil, role: String? = nil, template: String? = nil, model: String? = nil,
        status: String, stalled: Bool = false, callerAgent: String? = nil, parentDispatchID: String? = nil,
        startedAt: String? = nil, endedAt: String? = nil, attachable: Bool = false, tmuxTarget: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.template = template
        self.model = model
        self.status = status
        self.stalled = stalled
        self.callerAgent = callerAgent
        self.parentDispatchID = parentDispatchID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attachable = attachable
        self.tmuxTarget = tmuxTarget
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, template, model, status, stalled, attachable
        case tmuxTarget = "tmux_target"
        case callerAgent = "caller_agent"
        case parentDispatchID = "parent_dispatch_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    /// `id` and `status` are required (an entry without them can't be
    /// placed or ended); every other field degrades to absent, and an empty
    /// string reads as absent (the daemon uses `omitempty`).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        guard !id.isEmpty, !status.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty dispatch id or status"))
        }
        func optional(_ key: CodingKeys) -> String? {
            guard let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil, !value.isEmpty else { return nil }
            return value
        }
        name = optional(.name)
        role = optional(.role)
        template = optional(.template)
        model = optional(.model)
        stalled = ((try? container.decodeIfPresent(Bool.self, forKey: .stalled)) ?? nil) ?? false
        attachable = ((try? container.decodeIfPresent(Bool.self, forKey: .attachable)) ?? nil) ?? false
        callerAgent = optional(.callerAgent)
        parentDispatchID = optional(.parentDispatchID)
        startedAt = optional(.startedAt)
        endedAt = optional(.endedAt)
        tmuxTarget = optional(.tmuxTarget).flatMap { Self.isPaneID($0) ? $0 : nil }
    }

    /// A tmux pane id, `%` and digits only: safe as one tmux target.
    static func isPaneID(_ value: String) -> Bool {
        value.count > 1 && value.hasPrefix("%") && value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Still running as far as the daemon said: no `ended_at` and a
    /// non-terminal status. Idle and settling interactive runs are live.
    var isLive: Bool { endedAt == nil && !Self.terminalStatuses.contains(status) }
}

/// Decodes a `dispatches` array without ever failing its parent: a
/// malformed entry is dropped, the others survive.
struct LeoLenientDispatches: Decodable, Sendable {
    let dispatches: [LeoDispatch]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [LeoDispatch] = []
        while !container.isAtEnd {
            if let dispatch = try? container.decode(LeoDispatch.self) {
                decoded.append(dispatch)
            } else {
                // A failed decode leaves the cursor in place; skip the
                // element (any JSON value) so it advances.
                guard (try? container.decode(LeoSkippedValue.self)) != nil else { break }
            }
        }
        dispatches = decoded
    }
}

/// Consumes any one JSON value without looking at it.
private struct LeoSkippedValue: Decodable {
    init(from decoder: any Decoder) throws {}
}
