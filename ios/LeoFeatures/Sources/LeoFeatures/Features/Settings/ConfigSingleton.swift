import ComposableArchitecture
import Foundation
import LeoKit

/// One singleton resource's form (Defaults, Web UI, Remote client). The
/// form's data and transitions are LeoKit's (`LeoConfigSingletonState`,
/// shared with the Mac); this reducer runs the reads and writes
/// (`LeoConfigSingletonOps`) as effects and feeds each outcome back as an
/// action.
///
/// Leaving the screen with unsaved edits asks first, and a Save from that
/// question leaves only once the write has landed: a conflict or a rejected
/// value keeps the user on the form. The parent pops the screen on `leave`.
@Reducer
public struct ConfigSingleton {
    @ObservableState
    public struct State: Equatable {
        /// The form's data and transitions.
        public var core: LeoConfigSingletonState
        public let daemon: PairedDaemon
        public let connection: DaemonConnection
        /// The machine is connected right now. A disconnect keeps the draft
        /// and says so; a reconnect reads again.
        public var isMachineConnected = true
        @Presents public var leaveDialog: ConfirmationDialogState<Action.Leave>?

        /// `references` are names a reference field picks from that the parent
        /// already holds (the Daemon screen's hosts); the rest are read.
        public init(resource: String, daemon: PairedDaemon, connection: DaemonConnection, references: [String: [String]] = [:]) {
            core = LeoConfigSingletonState(
                resource: resource, references: references, machineHost: daemon.baseURL.host(), webOrigin: daemon.baseURL
            )
            self.daemon = daemon
            self.connection = connection
        }
    }

    public enum Action {
        case task
        case loaded(LeoConfigSingletonLoad)
        case refreshed(Result<LeoConfigDocument, Error>)
        case field(String, LeoConfigValue)
        case revertTapped(String)
        case revertAllTapped
        case saveTapped
        case writeFinished(LeoConfigSingletonWriteOutcome, sent: LeoConfigDraft, leaveAfter: Bool)
        case reloadTapped
        case overwriteTapped
        case overwriteFinished(LeoConfigSingletonOverwriteOutcome)
        case backTapped
        case dismissErrorTapped
        case dismissRestartBanner
        /// The restart the banner offers, asked of the machine.
        case restartBannerTapped(MachineRestart.Kind)
        /// The names behind a reference field changed (a host was added).
        case referencesChanged([String: [String]])
        case leaveDialog(PresentationAction<Leave>)
        case delegate(Delegate)
        case machine(Machine)

        @CasePathable
        public enum Leave: Equatable, Sendable {
            case save
            case discard
        }

        @CasePathable
        public enum Delegate {
            case restart(MachineRestart.Kind)
            /// The form is done with: the parent pops it.
            case leave
        }

        @CasePathable
        public enum Machine {
            case connectionChanged(Bool)
        }
    }

    @Dependency(\.configClients) var configClients

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return load(&state)
            case .loaded(let load):
                state.core.loaded(load)
            case .refreshed(.success(let document)):
                state.core.apply(document, carrying: state.core.draft)
            case .refreshed(.failure(let error)):
                state.core.report(error)
            case .machine(.connectionChanged(let isConnected)):
                state.isMachineConnected = isConnected
                guard isConnected else { return .none }
                guard state.core.schema != nil, state.core.phase == .loaded else { return load(&state) }
                state.core.dismissConflict()
                return refresh(state)
            case .referencesChanged(let references):
                state.core.setReferences(references)
            case .delegate:
                break
            default:
                return reduceEditing(&state, action)
            }
            return .none
        }
        .ifLet(\.$leaveDialog, action: \.leaveDialog)
    }

    private func reduceEditing(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        case .field(let path, let value):
            state.core.set(path, value)
        case .revertTapped(let path):
            state.core.revert(path)
        case .revertAllTapped:
            state.core.revertAll()
        case .dismissErrorTapped:
            state.core.dismissError()
        case .dismissRestartBanner:
            state.core.dismissRestartPrompt()
        case .restartBannerTapped(let kind):
            guard state.core.restartPrompt != nil else { return .none }
            state.core.dismissRestartPrompt()
            return .send(.delegate(.restart(kind)))
        case .saveTapped:
            return save(&state, leaveAfter: false)
        case .writeFinished(let outcome, let sent, let leaveAfter):
            guard let failure = state.core.finishWrite(outcome) else {
                return leaveAfter ? .send(.delegate(.leave)) : .none
            }
            state.core.failed(failure, sent: sent)
        case .reloadTapped:
            guard state.core.conflict != nil else { return .none }
            state.core.dismissConflict()
            return refresh(state)
        case .overwriteTapped:
            return overwrite(&state)
        case .overwriteFinished(let outcome):
            state.core.finishOverwrite(outcome)
        case .backTapped:
            guard state.core.isDirty else { return .send(.delegate(.leave)) }
            state.leaveDialog = ConfigLeaveDialog.make(canSave: state.core.canSave)
        case .leaveDialog(.presented(.save)):
            return save(&state, leaveAfter: true)
        case .leaveDialog(.presented(.discard)):
            state.core.revertAll()
            return .send(.delegate(.leave))
        default:
            break
        }
        return .none
    }

    // MARK: effects

    /// The transform a resource's form is drawn with: the client's default
    /// host picks from the hosts.
    static func transform(for resource: String) -> (@Sendable (LeoConfigResource) -> LeoConfigResource)? {
        resource == LeoDaemonPane.clientKey ? LeoDaemonPane.clientResource : nil
    }

    private func load(_ state: inout State) -> Effect<Action> {
        state.core.beginLoading()
        let (resource, references) = (state.core.resourceKey, state.core.references)
        let client = configClients.client(state.connection)
        return .run { send in
            let load = await LeoConfigSingletonOps.load(
                resource: resource, client: client, references: references, transform: Self.transform(for: resource)
            )
            await send(.loaded(load))
        }
    }

    /// Reads the document again; the open draft is carried over it when it lands.
    private func refresh(_ state: State) -> Effect<Action> {
        let resource = state.core.resourceKey
        let client = configClients.client(state.connection)
        return .run { send in
            await send(.refreshed(Result { try await client.document(resource) }))
        }
    }

    private func save(_ state: inout State, leaveAfter: Bool) -> Effect<Action> {
        guard state.core.canSave, let sent = state.core.draft, state.core.beginWrite() else { return .none }
        let resource = state.core.resourceKey
        let client = configClients.client(state.connection)
        let revisions = configClients.revisions(state.daemon.id)
        return .run { send in
            let outcome = await LeoConfigSingletonOps.write(resource: resource, client: client, revisions: revisions, sent: sent)
            await send(.writeFinished(outcome, sent: sent, leaveAfter: leaveAfter))
        }
    }

    private func overwrite(_ state: inout State) -> Effect<Action> {
        guard let stale = state.core.beginOverwrite() else { return .none }
        let resource = state.core.resourceKey
        let client = configClients.client(state.connection)
        let revisions = configClients.revisions(state.daemon.id)
        return .run { send in
            let outcome = await LeoConfigSingletonOps.overwrite(stale: stale, resource: resource, client: client, revisions: revisions)
            await send(.overwriteFinished(outcome))
        }
    }
}

/// The question asked when leaving a form with unsaved edits.
enum ConfigLeaveDialog {
    static func make<Leave: Equatable>(canSave: Bool, save: Leave, discard: Leave) -> ConfirmationDialogState<Leave> {
        ConfirmationDialogState {
            TextState("You have unsaved changes")
        } actions: {
            if canSave { ButtonState(action: save) { TextState("Save") } }
            ButtonState(role: .destructive, action: discard) { TextState("Discard Changes") }
            ButtonState(role: .cancel) { TextState("Keep Editing") }
        }
    }

    static func make(canSave: Bool) -> ConfirmationDialogState<ConfigSingleton.Action.Leave> {
        make(canSave: canSave, save: .save, discard: .discard)
    }
}
