import ComposableArchitecture
import Foundation
import LeoKit

/// A machine's Service screen: the daemon's status and a polled tail of its
/// log. The restarts and Reload Config are `MachineRestart`'s.
///
/// The tail is read every 2 s, only while the screen is visible, the app is
/// active and the user hasn't paused it: one loop, started and cancelled by
/// `syncPolling` whenever any of those changes.
@Reducer
public struct ServiceSettings {
    @ObservableState
    public struct State: Equatable {
        public let daemon: PairedDaemon
        public let connection: DaemonConnection
        public var status: LeoTasksLoad<LeoServiceStatus> = .idle
        public var isVisible = false
        public var isActive = true
        public var isPaused = false
        var isPolling = false
        public var logText = ""
        public var logError: String?

        public init(daemon: PairedDaemon, connection: DaemonConnection) {
            self.daemon = daemon
            self.connection = connection
        }

        var shouldPoll: Bool { isVisible && isActive && !isPaused }
    }

    public enum Action {
        case appeared
        case disappeared
        case statusLoaded(Result<LeoServiceStatus, Error>)
        case refreshRequested
        case logPolled(Result<LeoServiceLog, Error>)
        case pauseTapped
        case resumeTapped
        case copyTapped
        case machine(Machine)

        @CasePathable
        public enum Machine {
            case scenePhaseChanged(isActive: Bool)
            case connectionChanged(Bool)
        }
    }

    enum CancelID: Hashable {
        case log
    }

    @Dependency(\.configClients) var configClients
    @Dependency(\.continuousClock) var clock
    @Dependency(\.pasteboard) var pasteboard

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                state.isVisible = true
                return loadStatus(&state)
            case .disappeared:
                state.isVisible = false
                return .none
            case .refreshRequested:
                return refreshStatus(state)
            case .statusLoaded(let result):
                switch result {
                case .success(let status): state.status = .loaded(status)
                case .failure(let error):
                    // A refresh that fails leaves what was shown.
                    if case .loaded = state.status { break }
                    state.status = .failed(LeoConfigCollectionState.message(for: error))
                }
                return .none
            case .logPolled(let result):
                switch result {
                case .success(let log):
                    let shown = LeoTaskLog(file: "", text: log.text).tail().text
                    if shown != state.logText { state.logText = shown }
                    state.logError = nil
                case .failure(let error):
                    state.logError = LeoConfigCollectionState.message(for: error)
                }
                return .none
            case .pauseTapped:
                state.isPaused = true
                return .none
            case .resumeTapped:
                state.isPaused = false
                return .none
            case .copyTapped:
                pasteboard.copy(state.logText)
                return .none
            case .machine(.scenePhaseChanged(let isActive)):
                state.isActive = isActive
                return isActive ? refreshStatus(state) : .none
            case .machine(.connectionChanged(let isConnected)):
                return isConnected ? refreshStatus(state) : .none
            }
        }
        Reduce { state, _ in syncPolling(&state) }
    }

    private func loadStatus(_ state: inout State) -> Effect<Action> {
        if case .loaded = state.status { return refreshStatus(state) }
        state.status = .loading
        return refreshStatus(state)
    }

    private func refreshStatus(_ state: State) -> Effect<Action> {
        let client = configClients.client(state.connection)
        return .run { send in
            await send(.statusLoaded(await Result { try await client.serviceStatus() }))
        }
    }

    /// One loop reads the log while it should be read; this starts and stops it.
    private func syncPolling(_ state: inout State) -> Effect<Action> {
        guard state.shouldPoll != state.isPolling else { return .none }
        state.isPolling = state.shouldPoll
        guard state.shouldPoll else { return .cancel(id: CancelID.log) }
        let client = configClients.client(state.connection)
        let clock = clock
        return .run { send in
            while !Task.isCancelled {
                await send(.logPolled(await Result { try await client.serviceLog(lines: LeoServicePane.logLines) }))
                do { try await clock.sleep(for: LeoServicePane.logInterval) } catch { return }
            }
        }
        .cancellable(id: CancelID.log, cancelInFlight: true)
    }
}
