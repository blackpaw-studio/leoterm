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
/// the matching feature. Reserved `"actions"` (agent name ->
/// `{"kind": ..., "detail": ...}`) overrides `current_action` on `/state`
/// (B-260), e.g. `{"kind": "tool", "detail": "Bash make"}`. Reserved
/// `"compactions"` (agent name -> `[{"phase": "started", "trigger": "auto"},
/// {"phase": "completed"}]`) replays those `agent_compaction` events after
/// each hello, 1.5 s apart (B-261). Reserved `"control"` (`"deny"` or
/// `"unavailable"`) makes the control routes answer 403 or 503 locally
/// (B-262, see `LeoControlFixture.swift`) and advertises `agent_control`.
/// Reserved `"dispatch_moves"` (an array of dispatch records for one
/// dispatch, e.g. `attachable` and `viewer_kind` flipping) replays those as
/// `dispatch_changed` after each hello, 1.5 s apart, and advertises
/// `dispatch_tree`, `dispatch_attach` and `dispatch_placement_live`, so a
/// viewer moving between background and visible can be watched (B-272).
/// Reserved `"environments"` (B-283, see `LeoEnvironmentsFixture.swift`)
/// overlays named environments, answers their routes locally and
/// advertises `agent_environments`. Only named
/// agents change; nothing is sent anywhere.
enum LeoAttentionFixture {
    static let environmentKey = "LEO_ATTENTION_FIXTURE"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// The whole fixture file: attention by agent name, plus dispatches.
    struct File: Decodable, Equatable {
        static let dispatchesKey = "dispatches"
        static let usageKey = "usage"
        static let turnsKey = "turns"
        static let actionsKey = "actions"
        static let compactionsKey = "compactions"
        static let controlKey = "control"
        static let dispatchMovesKey = "dispatch_moves"
        static let environmentsKey = "environments"

        let attention: [String: LeoAttentionSignal]
        let dispatches: [LeoDispatch]
        let usage: [String: LeoAgentUsage]
        let turns: [String: LeoTurnCompletion]
        let actions: [String: LeoCurrentAction]
        let compactions: [String: [LeoCompactionEvent]]
        let control: LeoControlFixtureMode?
        /// Replayed in file order, not sorted.
        let dispatchMoves: [LeoDispatch]
        let environments: LeoEnvironmentsFixture?

        private struct FixtureCompaction: Decodable, Sendable {
            let phase: LeoCompactionPhase?
            let trigger: LeoCompactionTrigger?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                phase = (try? container.decode(String.self, forKey: Key(stringValue: "phase"))).flatMap(LeoCompactionPhase.init(rawValue:))
                trigger = (try? container.decode(String.self, forKey: Key(stringValue: "trigger"))).flatMap(LeoCompactionTrigger.init(rawValue:))
            }
        }

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
            var actions: [String: LeoCurrentAction] = [:]
            var compactions: [String: [LeoCompactionEvent]] = [:]
            var control: LeoControlFixtureMode?
            var dispatchMoves: [LeoDispatch] = []
            var environments: LeoEnvironmentsFixture?
            for key in container.allKeys {
                if key.stringValue == Self.dispatchesKey {
                    // A malformed value degrades to none, never breaks the fixture.
                    dispatches = (try? container.decode(LeoLenientDispatches.self, forKey: key))?.dispatches ?? []
                } else if key.stringValue == Self.dispatchMovesKey {
                    dispatchMoves = (try? container.decode(LeoLenientDispatches.self, forKey: key))?.dispatches ?? []
                } else if key.stringValue == Self.environmentsKey {
                    environments = try? container.decode(LeoEnvironmentsFixture.self, forKey: key)
                } else if key.stringValue == Self.usageKey {
                    usage = LeoAttentionFixture.lenientEntries(container, key, as: LeoAgentUsage.self)
                } else if key.stringValue == Self.actionsKey {
                    actions = LeoAttentionFixture.lenientEntries(container, key, as: LeoCurrentAction.self)
                } else if key.stringValue == Self.controlKey {
                    control = (try? container.decode(String.self, forKey: key)).flatMap(LeoControlFixtureMode.init(rawValue:))
                } else if key.stringValue == Self.compactionsKey {
                    let steps = LeoAttentionFixture.lenientEntries(container, key, as: [LeoLenient<FixtureCompaction>].self)
                    // A step with no usable phase is dropped.
                    compactions = steps.reduce(into: [:]) { result, entry in
                        result[entry.key] = entry.value.compactMap(\.value).compactMap { step in
                            step.phase.map { LeoCompactionEvent(agent: entry.key, phase: $0, trigger: step.trigger, contextPercent: nil) }
                        }
                    }
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
            self.actions = actions
            self.compactions = compactions
            self.control = control
            self.dispatchMoves = dispatchMoves
            self.environments = environments
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
        usage: [String: LeoAgentUsage] = [:], turns: [String: LeoTurnCompletion] = [:],
        actions: [String: LeoCurrentAction] = [:], compactions: [String: [LeoCompactionEvent]] = [:],
        control: LeoControlFixtureMode? = nil, dispatchMoves: [LeoDispatch] = [], environments: LeoEnvironmentsFixture? = nil
    ) -> LeoSidebarActivitySource {
        let environmentOverlay = environments?.agents ?? [:]
        return LeoSidebarActivitySource(events: {
            await advertising(
                await source.events(), usage: !usage.isEmpty, turns: turns, compactions: compactions, control: control != nil,
                dispatchTree: !dispatches.isEmpty, dispatchMoves: dispatchMoves, environments: environments != nil
            )
        }, observedState: {
            let state = try await source.fetchState()
            let agents = state.agents.map { agent in
                guard overlay[agent.name] != nil || usage[agent.name] != nil || actions[agent.name] != nil || environmentOverlay[agent.name] != nil else {
                    return agent
                }
                return LeoObservedAgent(
                    name: agent.name, host: agent.host, status: agent.status, activity: agent.activity,
                    currentAction: actions[agent.name] ?? agent.currentAction, lastActivityAt: agent.lastActivityAt, attention: overlay[agent.name] ?? agent.attention,
                    startedAt: agent.startedAt, surfacedFiles: agent.surfacedFiles, surfacedFilesSent: agent.surfacedFilesSent,
                    usage: usage[agent.name] ?? agent.usage, environments: environmentOverlay[agent.name] ?? agent.environments
                )
            }
            let fixtureIDs = Set(dispatches.map(\.id))
            return LeoObservedState(agents: agents, dispatches: state.dispatches.filter { !fixtureIDs.contains($0.id) } + dispatches)
        })
    }

    /// Each hello also names the features the fixture needs (`dispatch_tree`
    /// when it lists dispatches, D-396), and the turns
    /// follow it after the rows have had time to load (a turn for an agent
    /// with no row yet is dropped). Without either, the stream is untouched.
    static let turnReplayDelay: UInt64 = 1_500_000_000

    /// Moves are replayed with seqs far above any real daemon's, so the
    /// dispatch tree's `state_seq` bookkeeping never calls them stale, and
    /// above an earlier replay's after a reconnect.
    static func currentMoveSeq() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    static func advertising(
        _ events: AsyncStream<LeoObserveEvent>, usage: Bool, turns: [String: LeoTurnCompletion],
        compactions: [String: [LeoCompactionEvent]] = [:], control: Bool = false, dispatchTree: Bool = false,
        dispatchMoves: [LeoDispatch] = [], environments: Bool = false, replayDelay: UInt64 = turnReplayDelay, firstMoveSeq: @escaping @Sendable () -> Int = currentMoveSeq
    ) -> AsyncStream<LeoObserveEvent> {
        let moving = !dispatchMoves.isEmpty
        guard usage || !turns.isEmpty || !compactions.isEmpty || control || dispatchTree || moving || environments else { return events }
        let flagged: [(Bool, [String])] = [
            (dispatchTree || moving, ["dispatch_tree"]), (usage, ["agent_usage"]), (!turns.isEmpty, ["bridge_turns"]),
            (control, ["agent_control"]), (moving, ["dispatch_attach", "dispatch_placement_live"]), (environments, ["agent_environments"]),
        ]
        let extra = flagged.filter(\.0).flatMap(\.1)
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
                    // Replaying after every hello is intentional (DEBUG): a
                    // disconnect clears previews, so a Retry should show them again.
                    let moveSeq = firstMoveSeq()
                    replays.append(Task {
                        try? await Task.sleep(nanoseconds: replayDelay)
                        for (step, move) in dispatchMoves.enumerated() where !Task.isCancelled {
                            continuation.yield(.dispatchChanged(seq: moveSeq + step, dispatch: move))
                            try? await Task.sleep(nanoseconds: replayDelay)
                        }
                    })
                    replays.append(Task {
                        try? await Task.sleep(nanoseconds: replayDelay)
                        for turn in turns.values.sorted(by: { $0.agent < $1.agent }) where !Task.isCancelled {
                            continuation.yield(.agentTurnCompleted(seq: -1, turn: turn))
                        }
                        // Each agent's steps run in order, one interval apart.
                        for step in 0..<(compactions.values.map(\.count).max() ?? 0) {
                            for steps in compactions.sorted(by: { $0.key < $1.key }).map(\.value) where step < steps.count && !Task.isCancelled {
                                continuation.yield(.agentCompaction(seq: -1, compaction: steps[step]))
                            }
                            try? await Task.sleep(nanoseconds: replayDelay)
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
