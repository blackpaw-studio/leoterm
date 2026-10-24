import ComposableArchitecture
import Foundation
import LeoKit

/// One collection resource's screens (Templates, Environments): the list,
/// and the editor for the item the user opened.
@Reducer
public struct ConfigCollection {
    @ObservableState
    public struct State: Equatable {
        /// The pane's data and transitions, shared with the Mac.
        public var core: LeoConfigCollectionState
        public let daemon: PairedDaemon
        public let connection: DaemonConnection
        /// The machine is connected right now. A disconnect keeps the editor
        /// and its draft and says so; a reconnect reads again.
        public var isMachineConnected = true

        public init(resource: String, daemon: PairedDaemon, connection: DaemonConnection) {
            core = LeoConfigCollectionState(
                resource: resource, machineHost: daemon.baseURL.host(), webOrigin: daemon.baseURL, autoSelectsFirst: false
            )
            self.daemon = daemon
            self.connection = connection
        }
    }

    public enum Action {
        case machine(Machine)

        @CasePathable
        public enum Machine {
            case connectionChanged(Bool)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .machine(.connectionChanged(let isConnected)):
                state.isMachineConnected = isConnected
                return .none
            }
        }
    }
}
