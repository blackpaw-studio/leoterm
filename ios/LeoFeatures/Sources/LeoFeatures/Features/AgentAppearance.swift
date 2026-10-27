import ComposableArchitecture
import Foundation
import LeoKit

/// The Appearance sheet for one agent. Every pick is one manual write that
/// shows at once and is put back if the daemon refuses it; the fleet's next
/// value wins once nothing is in flight. The rules are fetched on open only
/// to name a rule in the source line.
@Reducer
public struct AgentAppearance {
    @ObservableState
    public struct State: Equatable, Identifiable {
        public var daemon: PairedDaemon
        public let agentName: String
        /// Kept live by the parent from `Fleet`.
        public var appearance: LeoAgentAppearance?
        public var query = ""
        public var rules: [LeoAppearanceRule]?
        public var recents: [String] = []
        public var error: String?
        public var isSaving = false
        var appearanceBeforeWrite: LeoAgentAppearance?

        public init(daemon: PairedDaemon, agentName: String, appearance: LeoAgentAppearance?) {
            self.daemon = daemon
            self.agentName = agentName
            self.appearance = appearance
        }

        public var ref: AgentRef { AgentRef(daemonID: daemon.id, name: agentName) }
        public var id: AgentRef { ref }

        public var emojiSourceText: String { LeoAppearanceText.emojiSource(appearance, rules: rules) }
        public var colorSourceText: String { LeoAppearanceText.colorSource(appearance, rules: rules) }
        public var colorPick: LeoAppearanceColor? { LeoAppearanceText.colorPick(appearance) }
        public var noneColorLabel: String { LeoAppearanceText.noneColorLabel(appearance, rules: rules) }
        public var canReset: Bool { LeoAppearanceText.canReset(appearance) }

        /// The fleet's latest value; ignored while a write is in flight,
        /// whose answer is newer.
        public mutating func receive(_ appearance: LeoAgentAppearance?) {
            guard !isSaving else { return }
            self.appearance = appearance
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case colorPicked(LeoAppearanceColor?)
        case doneTapped
        case emojiCleared
        case emojiPicked(String)
        case resetTapped
        case rulesLoaded(Result<[LeoAppearanceRule], any Error>)
        case task
        case writeFinished(Result<LeoAgentAppearance?, any Error>)
    }

    @Dependency(\.daemonClient) var daemonClient
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.emojiRecents) var emojiRecents
    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .doneTapped:
                let dismiss = dismiss
                return .run { _ in await dismiss() }

            case .task:
                state.recents = emojiRecents.emoji
                let (daemon, daemonClient, secrets) = (state.daemon, daemonClient, secrets)
                return .run { send in
                    await send(.rulesLoaded(Result {
                        try await daemonClient.appearanceRules(try Self.connection(daemon, secrets: secrets))
                    }))
                }

            case .rulesLoaded(let result):
                state.rules = try? result.get()
                return .none

            case .emojiPicked(let emoji):
                emojiRecents.record(emoji)
                state.recents = emojiRecents.emoji
                return write(emoji: .set(emoji), color: .unchanged, state: &state)

            case .emojiCleared:
                return write(emoji: .cleared, color: .unchanged, state: &state)

            case .colorPicked(let color):
                return write(emoji: .unchanged, color: color.map { .set($0) } ?? .cleared, state: &state)

            case .resetTapped:
                return write(emoji: .cleared, color: .cleared, state: &state)

            case .writeFinished(let result):
                state.isSaving = false
                switch result {
                case .success(let appearance):
                    state.appearance = appearance
                    state.error = nil
                case .failure(let error):
                    state.appearance = state.appearanceBeforeWrite
                    state.error = error.localizedDescription
                }
                state.appearanceBeforeWrite = nil
                return .none
            }
        }
    }

    private func write(
        emoji: LeoAppearanceChange<String>, color: LeoAppearanceChange<LeoAppearanceColor>, state: inout State
    ) -> Effect<Action> {
        state.appearanceBeforeWrite = state.appearance
        state.appearance = LeoAppearanceText.optimistic(state.appearance, emoji: emoji, color: color)
        state.isSaving = true
        let (daemon, agent, daemonClient, secrets) = (state.daemon, state.agentName, daemonClient, secrets)
        return .run { send in
            await send(.writeFinished(Result {
                try await daemonClient.setAppearance(try Self.connection(daemon, secrets: secrets), agent, emoji, color)
            }))
        }
    }

    private static func connection(_ daemon: PairedDaemon, secrets: SecretsClient) throws -> DaemonConnection {
        guard let saved = try secrets.load(daemon.id) else { throw MissingToken(daemonName: daemon.name) }
        return DaemonConnection(daemon: daemon, secrets: saved)
    }
}
