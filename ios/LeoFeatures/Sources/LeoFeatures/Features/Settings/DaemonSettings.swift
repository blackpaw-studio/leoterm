import ComposableArchitecture
import Foundation
import LeoKit

/// The Daemon screen: the service (status, actions, log), the web UI form,
/// the remote client form and the remote hosts, in the Mac's order
/// (`LeoDaemonPane.Section`). Each section pushes its own screen, and the
/// machine's news (connection, scene phase, a finished restart) reaches
/// whichever one is open.
///
/// The client's `default_host` picks from the hosts: its form reads their
/// names each time it opens, so a host added a moment ago is offered. Hosts
/// asks before deleting the default host, saying the setting stays as it was.
@Reducer
public struct DaemonSettings {
    @Reducer
    public enum Destination {
        case service(ServiceSettings)
        case web(ConfigSingleton)
        case client(ConfigSingleton)
        case hosts(ConfigCollection)
    }

    @ObservableState
    public struct State: Equatable {
        public let daemon: PairedDaemon
        public let connection: DaemonConnection
        @Presents public var destination: Destination.State?

        public init(daemon: PairedDaemon, connection: DaemonConnection) {
            self.daemon = daemon
            self.connection = connection
        }

        public var sections: [LeoDaemonPane.Section] { LeoDaemonPane.Section.allCases }
    }

    public enum Action {
        case sectionTapped(LeoDaemonPane.Section)
        /// The client's default host, read when Hosts opens, for its delete question.
        case defaultHostRead(String?)
        case destination(PresentationAction<Destination.Action>)
        case delegate(Delegate)
        case machine(Machine)

        @CasePathable
        public enum Delegate {
            case restart(MachineRestart.Kind)
        }

        @CasePathable
        public enum Machine {
            case connectionChanged(Bool)
            case scenePhaseChanged(isActive: Bool)
            /// A restart the machine ran finished: the service's status is stale.
            case restartFinished
        }
    }

    @Dependency(\.configClients) var configClients

    public init() {}

    public static func title(for section: LeoDaemonPane.Section) -> String {
        switch section {
        case .service: String(localized: "Service")
        case .web: String(localized: "Web UI")
        case .client: String(localized: "Remote client")
        case .hosts: String(localized: "Remote hosts")
        }
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .sectionTapped(let section):
                return open(section, &state)

            case .defaultHostRead(let host):
                guard case .hosts(var hosts)? = state.destination else { return .none }
                hosts.deleteNotes = Self.deleteNotes(defaultHost: host)
                state.destination = .hosts(hosts)
                return .none

            case .destination(.presented(.web(.delegate(.restart(let kind))))),
                 .destination(.presented(.client(.delegate(.restart(let kind))))),
                 .destination(.presented(.hosts(.delegate(.restart(let kind))))):
                return .send(.delegate(.restart(kind)))

            case .destination(.presented(.web(.delegate(.leave)))), .destination(.presented(.client(.delegate(.leave)))):
                state.destination = nil
                return .none

            case .machine(let news):
                return forward(news, state: state)

            case .destination, .delegate:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func open(_ section: LeoDaemonPane.Section, _ state: inout State) -> Effect<Action> {
        let (daemon, connection) = (state.daemon, state.connection)
        switch section {
        case .service:
            state.destination = .service(ServiceSettings.State(daemon: daemon, connection: connection))
        case .web:
            state.destination = .web(ConfigSingleton.State(resource: LeoDaemonPane.webKey, daemon: daemon, connection: connection))
        case .client:
            state.destination = .client(ConfigSingleton.State(resource: LeoDaemonPane.clientKey, daemon: daemon, connection: connection))
        case .hosts:
            state.destination = .hosts(ConfigCollection.State(resource: LeoDaemonPane.hostsKey, daemon: daemon, connection: connection))
            let client = configClients.client(connection)
            return .run { send in
                let document = try? await client.document(LeoDaemonPane.clientKey)
                await send(.defaultHostRead(document?.values[LeoDaemonPane.defaultHostKey]?.stringValue))
            }
        }
        return .none
    }

    static func deleteNotes(defaultHost: String?) -> [String: String] {
        guard let defaultHost else { return [:] }
        let client = LeoConfigDraft(document: LeoConfigDocument(revision: "", values: [LeoDaemonPane.defaultHostKey: .string(defaultHost)]))
        return LeoDaemonPane.deleteNote(forHost: defaultHost, client: client).map { [defaultHost: $0] } ?? [:]
    }

    private func forward(_ news: Action.Machine, state: State) -> Effect<Action> {
        switch (news, state.destination) {
        case (.connectionChanged(let isConnected), .service?):
            .send(.destination(.presented(.service(.machine(.connectionChanged(isConnected))))))
        case (.connectionChanged(let isConnected), .web?):
            .send(.destination(.presented(.web(.machine(.connectionChanged(isConnected))))))
        case (.connectionChanged(let isConnected), .client?):
            .send(.destination(.presented(.client(.machine(.connectionChanged(isConnected))))))
        case (.connectionChanged(let isConnected), .hosts?):
            .send(.destination(.presented(.hosts(.machine(.connectionChanged(isConnected))))))
        case (.scenePhaseChanged(let isActive), .service?):
            .send(.destination(.presented(.service(.machine(.scenePhaseChanged(isActive: isActive))))))
        case (.restartFinished, .service?):
            .send(.destination(.presented(.service(.refreshRequested))))
        default:
            .none
        }
    }
}

extension DaemonSettings.Destination.State: Equatable {}
