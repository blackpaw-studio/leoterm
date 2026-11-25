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
        /// The daemon advertises `agent_brief`; the switch is hidden otherwise.
        public let supportsBrief: Bool
        /// `brief.enabled`; nil until read.
        public var isBriefEnabled: Bool?
        /// The revision `brief.enabled` was read at; a write sends it as `If-Match`.
        public var briefRevision: String?
        public var isBriefSaving = false
        /// The switch's value before an in-flight toggle, to put back if the write fails.
        var briefBeforeSave: Bool?
        @Presents public var alert: AlertState<Never>?
        @Presents public var destination: Destination.State?

        public init(daemon: PairedDaemon, connection: DaemonConnection, supportsBrief: Bool = false) {
            self.daemon = daemon
            self.connection = connection
            self.supportsBrief = supportsBrief
        }

        public var sections: [LeoDaemonPane.Section] { LeoDaemonPane.Section.allCases }
    }

    public enum Action {
        case sectionTapped(LeoDaemonPane.Section)
        case task
        case alert(PresentationAction<Never>)
        case briefLoaded(Result<LeoConfigDocument, any Error>)
        case briefToggled(Bool)
        case briefSaved(Result<LeoConfigWriteResult, any Error>)
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

    public static let briefHelp = String(localized: "Agents keep a short summary of their work. Uses a few tokens when it changes.")

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

            case .task:
                guard state.supportsBrief else { return .none }
                return loadBrief(state)

            case .alert:
                return .none

            case .briefLoaded(.success(let document)):
                state.isBriefEnabled = document.values[LeoAgentBriefWire.enabledField]?.boolValue ?? false
                state.briefRevision = document.revision
                return .none

            case .briefLoaded(.failure):
                // Leave the switch as it was; the next visit reads again.
                return .none

            case .briefToggled(let isOn):
                guard state.supportsBrief, !state.isBriefSaving, let revision = state.briefRevision else { return .none }
                state.isBriefSaving = true
                // The switch follows the tap at once; a failed write puts it back.
                state.briefBeforeSave = state.isBriefEnabled
                state.isBriefEnabled = isOn
                let client = configClients.client(state.connection)
                let revisions = configClients.revisions(state.daemon.id)
                return .run { send in
                    await send(.briefSaved(Result {
                        let result = try await client.update(
                            LeoAgentBriefWire.configResource, name: nil,
                            patch: [LeoAgentBriefWire.enabledField: .bool(isOn)], ifMatch: revisions.resolve(revision)
                        )
                        revisions.recordWrite(from: revision, to: result.revision)
                        return result
                    }))
                }

            case .briefSaved(.success(let result)):
                state.isBriefSaving = false
                state.briefBeforeSave = nil
                state.briefRevision = result.revision
                // The write carried the requested value; read it back so the switch shows what the machine holds.
                return loadBrief(state)

            case .briefSaved(.failure(let error)):
                state.isBriefSaving = false
                state.isBriefEnabled = state.briefBeforeSave ?? state.isBriefEnabled
                state.briefBeforeSave = nil
                let machine = state.daemon.name
                let isConflict = (error as? LeoConfigError).map { if case .conflict = $0 { true } else { false } } ?? false
                state.alert = AlertState {
                    TextState(isConflict ? "Settings changed" : "Couldn’t save")
                } message: {
                    TextState(isConflict ? "Agent briefs changed on \(machine) since you opened this. Showing its current setting." : error.localizedDescription)
                }
                return loadBrief(state)

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
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$destination, action: \.destination)
    }

    private func loadBrief(_ state: State) -> Effect<Action> {
        let client = configClients.client(state.connection)
        return .run { send in
            await send(.briefLoaded(Result { try await client.document(LeoAgentBriefWire.configResource) }))
        }
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
