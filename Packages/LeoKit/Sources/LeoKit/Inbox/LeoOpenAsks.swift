import Foundation

/// One agent's open chat asks (ask and permission rows), oldest first, plus
/// what the agent said just before the oldest one.
public struct LeoOpenAskThread: Equatable, Sendable {
    public let asks: [LeoChatMessage]
    public let context: String?

    public init(asks: [LeoChatMessage], context: String? = nil) {
        self.asks = asks
        self.context = context
    }
}

/// The open `leo_chat_ask` / permission rows of every connected host, kept
/// current from chat events. Seed it from the open-asks route (`complete`)
/// or from the threads list's last messages (partial: only what those
/// show); events received while the seed was in flight should be applied
/// again after it. A settled ask is remembered so a late, older seed cannot
/// bring it back.
public struct LeoOpenAsks: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var message: LeoChatMessage
        var context: String?
    }

    private struct Said: Equatable, Sendable {
        let text: String
        let at: Date
    }

    private struct HostState: Equatable, Sendable {
        var asks: [String: Entry] = [:]
        var lastSaid: [String: Said] = [:]
        var settled: Set<String> = []
    }

    private var hosts: [LeoHostID: HostState] = [:]

    public init() {}

    /// Open threads for every host, keyed by agent.
    public var threads: [LeoAgentID: LeoOpenAskThread] {
        hosts.keys.reduce(into: [:]) { result, host in result.merge(threads(host: host)) { current, _ in current } }
    }

    public func threads(host: LeoHostID) -> [LeoAgentID: LeoOpenAskThread] {
        guard let state = hosts[host] else { return [:] }
        return Dictionary(grouping: state.asks.values, by: \.message.agent).reduce(into: [:]) { result, pair in
            let sorted = pair.value.sorted { ($0.message.ts, $0.message.id) < ($1.message.ts, $1.message.id) }
            result[LeoAgentID(host: host, name: pair.key)] = LeoOpenAskThread(asks: sorted.map(\.message), context: sorted.first?.context)
        }
    }

    /// `complete`: `messages` is every open ask (replaces the host's set).
    /// Otherwise they are samples (thread last messages): open ones are
    /// added, settled ones removed, and live asks stay.
    public mutating func seed(host: LeoHostID, messages: [LeoChatMessage], complete: Bool) {
        var state = hosts[host] ?? HostState()
        if complete { state.asks = [:] }
        for message in messages { Self.fold(message, into: &state) }
        hosts[host] = state
    }

    public mutating func apply(host: LeoHostID, event: LeoChatEvent) {
        var state = hosts[host] ?? HostState()
        Self.fold(event.message, into: &state)
        hosts[host] = state
    }

    /// A disconnected host's asks drop out; they come back with the next seed.
    public mutating func disconnect(host: LeoHostID) {
        hosts[host] = nil
    }

    private static func fold(_ message: LeoChatMessage, into state: inout HostState) {
        if message.kind == .ask || message.kind == .permission {
            guard message.isOpen else {
                state.asks[message.id] = nil
                state.settled.insert(message.id)
                return
            }
            guard !state.settled.contains(message.id) else { return }
            let context = state.asks[message.id]?.context ?? state.lastSaid[message.agent].flatMap { $0.at <= message.ts ? $0.text : nil }
            state.asks[message.id] = Entry(message: message, context: context)
            return
        }
        guard message.isFromAgent, message.kind == .text || message.kind == .voice else { return }
        let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, message.ts >= (state.lastSaid[message.agent]?.at ?? .distantPast) else { return }
        state.lastSaid[message.agent] = Said(text: text, at: message.ts)
    }
}
