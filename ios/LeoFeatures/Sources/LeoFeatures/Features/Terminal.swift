import ComposableArchitecture
import Foundation
import LeoKit

/// A read-only view of an agent's tmux session: the connection's state
/// machine. Output bypasses state and goes to the view through
/// `TerminalOutputBus`. The socket is open only while the screen is
/// visible, the app is in the foreground and the agent is running; a drop
/// reconnects with backoff, output the view fell behind on reconnects at
/// once (tmux redraws), and a revoked device never retries.
@Reducer
public struct Terminal {
    @ObservableState
    public struct State: Equatable {
        public var daemon: PairedDaemon
        public let agentName: String
        /// Kept in step by the parent from the agent's status.
        public var isAgentRunning: Bool
        public var isSceneActive = true
        public var isVisible = false
        public var phase: Phase = .idle
        /// Consecutive failed attempts; drives the backoff.
        public var failures = 0
        @Shared(.terminalSize) public var size

        public init(daemon: PairedDaemon, agentName: String, isAgentRunning: Bool) {
            self.daemon = daemon
            self.agentName = agentName
            self.isAgentRunning = isAgentRunning
        }

        public var ref: AgentRef { AgentRef(daemonID: daemon.id, name: agentName) }
    }

    public enum Phase: Equatable, Sendable {
        /// Off screen.
        case idle
        case connecting
        case live
        /// Dropped; the next attempt is scheduled with backoff.
        case disconnected(attempt: Int, reason: String)
        /// The daemon refused this device (revoked, or no token). Final.
        case revoked
        /// The agent is stopped, or the daemon doesn't know it.
        case notRunning
        /// Closed because the app went to the background.
        case paused
    }

    public enum Action {
        case agentRunningChanged(Bool)
        case appeared
        case connect
        case disappeared
        case ended(TerminalEnd)
        case opened
        case retryButtonTapped
        case scenePhaseChanged(isActive: Bool)
        case sizeSelected(TerminalSize)
    }

    enum CancelID: Hashable { case connection }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.secrets) var secrets
    @Dependency(\.terminalClient) var terminalClient
    @Dependency(\.terminalOutput) var output

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            // Revoked is final for this screen: only pairing again (a new
            // token, so a new screen) reconnects.
            if state.phase == .revoked { return Self.noteWhileRevoked(action, state: &state) }
            switch action {
            case .agentRunningChanged(let isRunning):
                state.isAgentRunning = isRunning
                guard state.isVisible, state.isSceneActive else { return .none }
                if !isRunning {
                    state.phase = .notRunning
                    return .cancel(id: CancelID.connection)
                }
                guard state.phase == .notRunning else { return .none }
                state.failures = 0
                return start(&state)

            case .appeared:
                state.isVisible = true
                state.failures = 0
                return start(&state)

            case .connect:
                return start(&state)

            case .disappeared:
                state.isVisible = false
                state.phase = .idle
                state.failures = 0
                return .cancel(id: CancelID.connection)

            case .ended(let end):
                guard state.isVisible, state.isSceneActive else { return .none }
                return ended(end, state: &state)

            case .opened:
                state.phase = .live
                state.failures = 0
                return .none

            case .retryButtonTapped:
                state.failures = 0
                return start(&state)

            case .scenePhaseChanged(let isActive):
                state.isSceneActive = isActive
                guard state.isVisible else { return .none }
                if isActive {
                    state.failures = 0
                    return start(&state)
                }
                state.phase = .paused
                state.failures = 0
                return .cancel(id: CancelID.connection)

            case .sizeSelected(let size):
                guard size != state.size else { return .none }
                state.$size.withLock { $0 = size }
                guard state.isVisible, state.isSceneActive, state.isAgentRunning, state.phase != .revoked else { return .none }
                state.failures = 0
                return start(&state)
            }
        }
    }

    /// Keeps the screen's facts current without reconnecting.
    private static func noteWhileRevoked(_ action: Action, state: inout State) -> Effect<Action> {
        switch action {
        case .agentRunningChanged(let isRunning): state.isAgentRunning = isRunning
        case .appeared: state.isVisible = true
        case .disappeared: state.isVisible = false
        case .scenePhaseChanged(let isActive): state.isSceneActive = isActive
        case .sizeSelected(let size): if size != state.size { state.$size.withLock { $0 = size } }
        case .connect, .ended, .opened, .retryButtonTapped: break
        }
        return .none
    }

    private func ended(_ end: TerminalEnd, state: inout State) -> Effect<Action> {
        switch end {
        case .overflowed:
            return start(&state)
        case .revoked:
            state.phase = .revoked
            return .none
        case .notRunning:
            state.phase = .notRunning
            return .none
        case .sessionEnded where !state.isAgentRunning:
            state.phase = .notRunning
            return .none
        case .sessionEnded, .dropped:
            state.failures += 1
            let failures = state.failures
            state.phase = .disconnected(attempt: failures, reason: end.reason)
            return .run { [clock] send in
                try await clock.sleep(for: Fleet.backoff(failures))
                await send(.connect)
            }
            .cancellable(id: CancelID.connection, cancelInFlight: true)
        }
    }

    /// (Re)opens the attach when the screen can show it.
    private func start(_ state: inout State) -> Effect<Action> {
        guard state.isVisible, state.isSceneActive else { return .none }
        guard state.isAgentRunning else {
            state.phase = .notRunning
            return .cancel(id: CancelID.connection)
        }
        state.phase = .connecting
        let (ref, daemon, size) = (state.ref, state.daemon, state.size)
        let (secrets, terminalClient, output) = (secrets, terminalClient, output)
        return .run { send in
            guard let saved = try secrets.load(daemon.id) else {
                await send(.ended(.revoked))
                return
            }
            let connection = DaemonConnection(daemon: daemon, secrets: saved)
            for try await event in terminalClient.attach(connection, ref.name, size) {
                switch event {
                case .opened:
                    output.send(.reset, to: ref)
                    await send(.opened)
                case .output(let data):
                    guard output.send(.bytes(data), to: ref) else {
                        await send(.ended(.overflowed))
                        return
                    }
                }
            }
            await send(.ended(.dropped("Connection closed")))
        } catch: { error, send in
            await send(.ended(TerminalEnd(error)))
        }
        .cancellable(id: CancelID.connection, cancelInFlight: true)
    }
}

/// How an attach ended, as the terminal screen cares.
public enum TerminalEnd: Equatable, Sendable {
    case revoked
    case notRunning
    /// tmux exited (the session ended, or the attach failed): retried only
    /// while the agent still reports running.
    case sessionEnded
    case dropped(String)
    /// The view fell behind and output was dropped: reattach so tmux
    /// redraws the screen.
    case overflowed

    init(_ error: any Error) {
        switch error {
        case LeoTerminalAttachError.closed(LeoTerminalAttachError.policyViolation, _),
             LeoTerminalAttachError.rejected(401), LeoTerminalAttachError.rejected(403):
            self = .revoked
        case LeoTerminalAttachError.rejected(404):
            self = .notRunning
        case LeoTerminalAttachError.closed(1000, _), LeoTerminalAttachError.closed(1011, _):
            self = .sessionEnded
        default:
            self = .dropped(error.localizedDescription)
        }
    }

    var reason: String {
        switch self {
        case .sessionEnded: "The agent's session ended."
        case .dropped(let reason): reason
        case .revoked, .notRunning, .overflowed: ""
        }
    }
}
