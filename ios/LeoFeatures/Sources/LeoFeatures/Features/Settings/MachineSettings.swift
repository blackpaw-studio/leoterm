import ComposableArchitecture
import Foundation
import LeoKit

/// What a machine's settings screens need to know of its live session: who
/// it is, whether it is connected, and what its daemon advertised. The rest
/// of `DaemonSession` (agents, stats) changes constantly and is not theirs.
public struct MachineLink: Equatable, Sendable {
    public var daemon: PairedDaemon
    public var connection: ConnectionStatus
    public var features: LeoDaemonFeatures

    public init(daemon: PairedDaemon, connection: ConnectionStatus, features: LeoDaemonFeatures) {
        self.daemon = daemon
        self.connection = connection
        self.features = features
    }

    public init(session: DaemonSession) {
        self.init(daemon: session.daemon, connection: session.connection, features: session.features)
    }
}

/// One machine's settings: the rows that open its Templates, Environments,
/// and later Tasks and Service panes. The machine is implied by the
/// navigation path that got here. An open pane is never dismissed by a
/// connection change: a disconnect keeps it and its draft, and a reconnect
/// tells it to read again.
@Reducer
public struct MachineSettings {
    @Reducer
    public enum Destination {
        case templates(ConfigCollection)
        case environments(ConfigCollection)
        case tasks(TaskSettings)
    }

    public enum Row: String, CaseIterable, Equatable, Sendable {
        case templates
        case environments
        case tasks

        public var title: String {
            switch self {
            case .templates: String(localized: "Templates")
            case .environments: String(localized: "Environments")
            case .tasks: String(localized: "Tasks")
            }
        }
    }

    /// What the machine screen offers right now.
    public enum Availability: Equatable, Sendable {
        case rows([Row])
        /// Connected, but the daemon predates the config API.
        case requires(String)
        /// Not connected: the status, with a way to reconnect.
        case unavailable(ConnectionStatus)
    }

    @ObservableState
    public struct State: Equatable, Identifiable {
        public var link: MachineLink
        @Presents public var alert: AlertState<Never>?
        @Presents public var destination: Destination.State?

        public init(link: MachineLink) {
            self.link = link
        }

        public var id: PairedDaemon.ID { link.daemon.id }

        public var availability: Availability {
            if destination != nil { return .rows(Row.allCases) }
            guard link.connection.isConnected else { return .unavailable(link.connection) }
            guard link.features.contains(.configAPI) else { return .requires(Self.requirementText) }
            return .rows(Row.allCases)
        }

        static var requirementText: String {
            LeoConfigAPI.minimumVersion.map { "Requires leo ≥ \($0.major).\($0.minor).\($0.patch)" } ?? "Update leo on this machine"
        }
    }

    public enum Action {
        case alert(PresentationAction<Never>)
        case delegate(Delegate)
        case destination(PresentationAction<Destination.Action>)
        /// The machine's live session changed (the parent keeps this in step with `Fleet`).
        case linkUpdated(MachineLink)
        case reconnectTapped
        case rowTapped(Row)

        @CasePathable
        public enum Delegate: Equatable {
            case retry(PairedDaemon.ID)
        }
    }

    @Dependency(\.secrets) var secrets

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .alert, .delegate, .destination:
                return .none

            case .linkUpdated(let link):
                let wasConnected = state.link.connection.isConnected
                state.link = link
                guard wasConnected != link.connection.isConnected else { return .none }
                return forwardConnection(link.connection.isConnected, state: state)

            case .reconnectTapped:
                return .send(.delegate(.retry(state.id)))

            case .rowTapped(let row):
                let daemon = state.link.daemon
                guard let connection = try? secrets.connection(for: daemon) else {
                    state.alert = AlertState { TextState("Can’t open \(row.title)") } message: {
                        TextState("This device has no saved token for \(daemon.name). Pair it again.")
                    }
                    return .none
                }
                state.destination = switch row {
                case .templates: .templates(ConfigCollection.State(resource: row.rawValue, daemon: daemon, connection: connection))
                case .environments: .environments(ConfigCollection.State(resource: row.rawValue, daemon: daemon, connection: connection))
                case .tasks: .tasks(TaskSettings.State(daemon: daemon, connection: connection))
                }
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$destination, action: \.destination)
    }

    private func forwardConnection(_ isConnected: Bool, state: State) -> Effect<Action> {
        switch state.destination {
        case .templates?: .send(.destination(.presented(.templates(.machine(.connectionChanged(isConnected))))))
        case .environments?: .send(.destination(.presented(.environments(.machine(.connectionChanged(isConnected))))))
        case .tasks?: .send(.destination(.presented(.tasks(.collection(.machine(.connectionChanged(isConnected)))))))
        case nil: .none
        }
    }
}

extension MachineSettings.Destination.State: Equatable {}
