import Foundation

/// One agent as the inbox sees it: the caller (per platform) resolves display
/// strings and hands over the host's live committed attention signal.
public struct LeoInboxAgent: Equatable, Sendable {
    public let id: LeoAgentID
    /// The agent name shown on the row.
    public let name: String
    /// The machine name shown on the row.
    public let machine: String
    /// The project (repo) label, when the agent has one.
    public let project: String?
    /// `LeoAttentionReducer.committedSignal(for:)`; nil when unreported.
    public let signal: LeoAttentionSignal?
    /// The host's daemon boot, for local-mode seen marks.
    public let bootID: String?
    /// The agent's host is disconnected: it contributes nothing.
    public let isStale: Bool

    public init(
        id: LeoAgentID, name: String, machine: String, project: String? = nil, signal: LeoAttentionSignal? = nil,
        bootID: String? = nil, isStale: Bool = false
    ) {
        self.id = id
        self.name = name
        self.machine = machine
        self.project = project
        self.signal = signal
        self.bootID = bootID
        self.isStale = isStale
    }
}

/// Why an inbox item is there.
public enum LeoInboxKind: Equatable, Sendable {
    /// An open `leo_chat_ask` or chat permission row, answerable inline.
    case chatAsk(LeoChatMessage)
    /// A terminal permission prompt (no chat row): Go to Agent only.
    /// `input` is the full command when the daemon sent it; show it in
    /// preference to `detail`.
    case permission(tool: String?, detail: String?, input: String?)
    /// An AskUserQuestion or elicitation, or a needs-input with no reason.
    case question(text: String?)
    /// A finished (or errored) turn with its one-line result.
    case finished(result: String?)
}

/// One row of the inbox: one per agent, derived and never authored.
public struct LeoInboxItem: Equatable, Identifiable, Sendable {
    public let id: LeoAgentID
    public let kind: LeoInboxKind
    /// Always true for a blocked item; for a finished one, per the seen state.
    public let isUnread: Bool
    public let isError: Bool
    public let agent: String
    public let machine: String
    /// Nil when absent or equal to the agent name.
    public let projectLabel: String?
    /// When it happened (the ask's time, or the daemon's `attention.at`).
    public let at: Date?
    /// For a chat ask: the agent's last message before it.
    public let context: String?
    /// Further open chat asks the same agent has.
    public let moreCount: Int
    /// The signal revision and daemon boot behind this item (local seen marks).
    public let revision: Int?
    public let bootID: String?

    public init(
        id: LeoAgentID, kind: LeoInboxKind, isUnread: Bool, isError: Bool = false, agent: String, machine: String,
        projectLabel: String? = nil, at: Date? = nil, context: String? = nil, moreCount: Int = 0, revision: Int? = nil,
        bootID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isUnread = isUnread
        self.isError = isError
        self.agent = agent
        self.machine = machine
        self.projectLabel = projectLabel
        self.at = at
        self.context = context
        self.moreCount = moreCount
        self.revision = revision
        self.bootID = bootID
    }

    public var isBlocked: Bool {
        if case .finished = kind { false } else { true }
    }
}

/// The derived inbox: Blocked (oldest first) and Finished (newest first).
public struct LeoInbox: Equatable, Sendable {
    public let blocked: [LeoInboxItem]
    public let finished: [LeoInboxItem]

    public static let empty = LeoInbox(blocked: [], finished: [])

    /// Pure derivation across every connected machine.
    /// - Blocked: an open chat ask/permission row (even while the agent is
    ///   working), else attention `needsInput` (permission, question or
    ///   elicitation reason).
    /// - Finished: attention `finished` or `errored`; `isUnread` per `seen`.
    /// - A stale agent (disconnected host) contributes nothing.
    public static func derive(
        agents: [LeoInboxAgent], openAsks: [LeoAgentID: LeoOpenAskThread], seen: LeoInboxSeenState
    ) -> LeoInbox {
        let items = agents.filter { !$0.isStale }.compactMap { item(for: $0, thread: openAsks[$0.id], seen: seen) }
        return LeoInbox(
            blocked: items.filter(\.isBlocked).sorted { precedes($0, $1, oldestFirst: true) },
            finished: items.filter { !$0.isBlocked }.sorted { precedes($0, $1, oldestFirst: false) }
        )
    }

    private static func item(for agent: LeoInboxAgent, thread: LeoOpenAskThread?, seen: LeoInboxSeenState) -> LeoInboxItem? {
        if let thread, let first = thread.asks.first {
            return make(agent, kind: .chatAsk(first), at: first.ts, unread: true, context: thread.context, more: thread.asks.count - 1)
        }
        guard let signal = agent.signal else { return nil }
        switch signal.state {
        case .needsInput:
            return make(agent, kind: reasonKind(signal.reason), at: signal.at, unread: true)
        case .finished, .errored:
            let unread = seen.isUnread(agent.id, at: signal.at, revision: signal.revision, bootID: agent.bootID)
            return make(agent, kind: .finished(result: signal.preview), at: signal.at, unread: unread, isError: signal.state == .errored)
        case .working, .unknown:
            return nil
        }
    }

    private static func reasonKind(_ reason: LeoAttentionReason?) -> LeoInboxKind {
        switch reason?.kind {
        case .permission: .permission(tool: reason?.tool, detail: reason?.detail, input: reason?.input)
        case .question: .question(text: reason?.detail)
        case .elicitation: .question(text: reason?.detail ?? reason?.tool)
        case nil: .question(text: nil)
        }
    }

    private static func make(
        _ agent: LeoInboxAgent, kind: LeoInboxKind, at: Date?, unread: Bool, isError: Bool = false, context: String? = nil, more: Int = 0
    ) -> LeoInboxItem {
        LeoInboxItem(
            id: agent.id, kind: kind, isUnread: unread, isError: isError, agent: agent.name, machine: agent.machine,
            projectLabel: agent.project.flatMap { $0.isEmpty || $0 == agent.name ? nil : $0 }, at: at, context: context, moreCount: more,
            revision: agent.signal?.revision, bootID: agent.bootID
        )
    }

    /// Known times order first; an item without one sorts last, then by name.
    private static func precedes(_ lhs: LeoInboxItem, _ rhs: LeoInboxItem, oldestFirst: Bool) -> Bool {
        switch (lhs.at, rhs.at) {
        case (let left?, let right?) where left != right: oldestFirst ? left < right : left > right
        case (nil, _?): false
        case (_?, nil): true
        default: lhs.id.name < rhs.id.name
        }
    }
}
