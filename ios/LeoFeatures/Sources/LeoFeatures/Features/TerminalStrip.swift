import ComposableArchitecture
import Foundation
import LeoKit

/// The live, read-only strip under a chat thread's header: a `Terminal`
/// connection that only exists while the thread is on screen, the strip is
/// shown and the agent is known to the fleet. The parent reconciles that
/// (`reconcile`) after every action, so the strip never outlives its reasons.
///
/// It reads through its own output bus (`terminalStripOutput`): the bus
/// allows one subscriber per agent, and the full terminal screen, pushed from
/// the same thread, takes the other one.
@Reducer
public struct TerminalStrip {
    @ObservableState
    public struct State: Equatable {
        public var terminal: Terminal.State
        /// The user's choice in this thread; nil until they toggle. It lasts
        /// as long as the thread's state, so each opened thread starts from
        /// the Settings default.
        public var userChoice: Bool?
        @Shared(.showsTerminalInChats) public var showsByDefault

        public init(daemon: PairedDaemon, agentName: String, isAgentRunning: Bool) {
            terminal = Terminal.State(daemon: daemon, agentName: agentName, isAgentRunning: isAgentRunning)
        }

        public var isShown: Bool { userChoice ?? showsByDefault }
    }

    public enum Action {
        case scenePhaseChanged(isActive: Bool)
        case terminal(Terminal.Action)
        /// The strip's hide/show control (and the header's, once hidden).
        case toggleTapped
    }

    @Dependency(\.terminalStripOutput) var stripOutput

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .scenePhaseChanged(let isActive):
                return run(.scenePhaseChanged(isActive: isActive), state: &state)
            case .terminal(let action):
                return run(action, state: &state)
            case .toggleTapped:
                state.userChoice = !state.isShown
                return .none
            }
        }
    }

    /// Opens or closes the connection to match what the thread wants, and
    /// keeps its idea of the agent's state current.
    public func reconcile(_ state: inout State, wantsVisible: Bool, isAgentRunning: Bool) -> Effect<Action> {
        var effects: [Effect<Action>] = []
        if state.terminal.isAgentRunning != isAgentRunning {
            effects.append(run(.agentRunningChanged(isAgentRunning), state: &state))
        }
        if state.terminal.isVisible != wantsVisible {
            effects.append(run(wantsVisible ? .appeared : .disappeared, state: &state))
        }
        return .merge(effects)
    }

    /// Runs the connection state machine inline, so a parent's change takes
    /// effect in the same action.
    private func run(_ action: Terminal.Action, state: inout State) -> Effect<Action> {
        // Terminal reads its bus where it reduces, so both happen under the override.
        withDependencies { [stripOutput] in
            $0.terminalOutput = stripOutput
        } operation: {
            Terminal().reduce(into: &state.terminal, action: action).map(Action.terminal)
        }
    }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
    /// Settings > Chat > "Show live terminal in chats"; the default for each thread opened.
    public static var showsTerminalInChats: Self { Self[.appStorage("showsTerminalInChats"), default: true] }
}

private enum TerminalStripOutputKey: DependencyKey {
    static let liveValue = TerminalOutputBus()
    static var testValue: TerminalOutputBus { TerminalOutputBus() }
}

extension DependencyValues {
    /// The strip's own output bus, apart from the full terminal's.
    public var terminalStripOutput: TerminalOutputBus {
        get { self[TerminalStripOutputKey.self] }
        set { self[TerminalStripOutputKey.self] = newValue }
    }
}
