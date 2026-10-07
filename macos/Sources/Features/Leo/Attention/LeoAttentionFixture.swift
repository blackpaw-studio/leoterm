#if DEBUG
import Foundation
import OSLog

/// DEBUG builds only: overlays attention states onto the local daemon's
/// `/state` from a JSON file named by `LEO_ATTENTION_FIXTURE`
/// (`{"alpha": {"state": "needs_input", "revision": 1, "reason": {"kind": "permission", "tool": "Bash"}}, ...}`), so the
/// badges can be seen and screenshotted before the daemon emits
/// `attention` itself. A reserved `"dispatches"` key holds an array of
/// dispatch records added to `/state` (B-257), so nested dispatch rows can
/// be screenshotted too. Reserved `"usage"` (agent name -> `Agent.usage`,
/// overlaid on `/state`) and `"turns"` (agent name -> `{"preview": ...,
/// "outcome": ...}`, replayed as `agent_turn_completed` shortly after each
/// hello) show the B-259 row details; with either, hello also advertises
/// the matching feature. Only named agents change; nothing is sent anywhere.
enum LeoAttentionFixture {
    static let environmentKey = "LEO_ATTENTION_FIXTURE"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// The whole fixture file: attention by agent name, plus dispatches.
    struct File: Decodable, Equatable {
        static let dispatchesKey = "dispatches"
        static let usageKey = "usage"
        static let turnsKey = "turns"

        let attention: [String: LeoAttentionSignal]
        let dispatches: [LeoDispatch]
        let usage: [String: LeoAgentUsage]
        let turns: [String: LeoTurnCompletion]

        private struct FixtureTurn: Decodable, Sendable {
            let preview: String?
            let outcome: String?
        }

        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            var attention: [String: LeoAttentionSignal] = [:]
            var dispatches: [LeoDispatch] = []
            var usage: [String: LeoAgentUsage] = [:]
            var turns: [String: LeoTurnCompletion] = [:]
            for key in container.allKeys {
                if key.stringValue == Self.dispatchesKey {
                    // A malformed value degrades to none, never breaks the fixture.
                    dispatches = (try? container.decode(LeoLenientDispatches.self, forKey: key))?.dispatches ?? []
                } else if key.stringValue == Self.usageKey {
                    usage = LeoAttentionFixture.lenientEntries(container, key, as: LeoAgentUsage.self)
                } else if key.stringValue == Self.turnsKey {
                    turns = LeoAttentionFixture.lenientEntries(container, key, as: FixtureTurn.self).reduce(into: [:]) { result, entry in
                        result[entry.key] = LeoTurnCompletion(
                            agent: entry.key, outcome: LeoTurnOutcome(wire: entry.value.outcome ?? "completed"),
                            preview: LeoSFTPServerText.sanitized(entry.value.preview ?? "")
                        )
                    }
                } else {
                    attention[key.stringValue] = try container.decode(LeoAttentionSignal.self, forKey: key)
                }
            }
            self.attention = attention
            self.usage = usage
            self.turns = turns
            self.dispatches = dispatches.sorted { ($0.startedAt ?? "", $0.id) < ($1.startedAt ?? "", $1.id) }
        }
    }

    /// A name -> value object under `key`; a malformed value, or entry, degrades to none.
    static func lenientEntries<Value: Decodable & Sendable>(
        _ container: KeyedDecodingContainer<File.Key>, _ key: File.Key, as _: Value.Type
    ) -> [String: Value] {
        guard let entries = try? container.decode([String: LeoLenient<Value>].self, forKey: key) else { return [:] }
        return entries.compactMapValues(\.value)
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: LeoAttentionSignal]? {
        loadFile(environment: environment)?.attention
    }

    static func loadFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> File? {
        guard let path = environment[environmentKey] else { return nil }
        do {
            return try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            logger.error("attention fixture \(path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func wrap(
        _ source: LeoSidebarActivitySource, overlay: [String: LeoAttentionSignal], dispatches: [LeoDispatch] = [],
        usage: [String: LeoAgentUsage] = [:], turns: [String: LeoTurnCompletion] = [:]
    ) -> LeoSidebarActivitySource {
        LeoSidebarActivitySource(events: { await advertising(await source.events(), usage: !usage.isEmpty, turns: turns) }, observedState: {
            let state = try await source.fetchState()
            let agents = state.agents.map { agent in
                guard overlay[agent.name] != nil || usage[agent.name] != nil else { return agent }
                return LeoObservedAgent(
                    name: agent.name, host: agent.host, status: agent.status, activity: agent.activity,
                    currentAction: agent.currentAction, lastActivityAt: agent.lastActivityAt, attention: overlay[agent.name] ?? agent.attention,
                    startedAt: agent.startedAt, surfacedFiles: agent.surfacedFiles, surfacedFilesSent: agent.surfacedFilesSent,
                    usage: usage[agent.name] ?? agent.usage
                )
            }
            let fixtureIDs = Set(dispatches.map(\.id))
            return LeoObservedState(agents: agents, dispatches: state.dispatches.filter { !fixtureIDs.contains($0.id) } + dispatches)
        })
    }

    /// Each hello also names the features the fixture needs, and the turns
    /// follow it after the rows have had time to load (a turn for an agent
    /// with no row yet is dropped). Without either, the stream is untouched.
    private static let turnReplayDelay: UInt64 = 1_500_000_000

    static func advertising(
        _ events: AsyncStream<LeoObserveEvent>, usage: Bool, turns: [String: LeoTurnCompletion]
    ) -> AsyncStream<LeoObserveEvent> {
        guard usage || !turns.isEmpty else { return events }
        let extra = (usage ? ["agent_usage"] : []) + (turns.isEmpty ? [] : ["bridge_turns"])
        return AsyncStream { continuation in
            let task = Task {
                var replays: [Task<Void, Never>] = []
                for await event in events {
                    guard case .hello(let seq, let at, let version, let serverTime, let bootID, let features) = event else {
                        continuation.yield(event)
                        continue
                    }
                    continuation.yield(.hello(
                        seq: seq, at: at, version: version, serverTime: serverTime, bootID: bootID,
                        features: features + extra.filter { !features.contains($0) }
                    ))
                    replays.append(Task {
                        try? await Task.sleep(nanoseconds: turnReplayDelay)
                        for turn in turns.values.sorted(by: { $0.agent < $1.agent }) where !Task.isCancelled {
                            continuation.yield(.agentTurnCompleted(seq: -1, turn: turn))
                        }
                    })
                }
                continuation.finish()
                replays.forEach { $0.cancel() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
