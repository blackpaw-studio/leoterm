import ComposableArchitecture
import Foundation
import LeoKit

/// One collection resource's screens (Templates, Environments): the list, and
/// the editor for the item the user opened. The pane's data and transitions
/// are LeoKit's (`LeoConfigCollectionState`, shared with the Mac); this
/// reducer runs the reads and writes (`LeoConfigCollectionOps`) as effects and
/// feeds each outcome back as an action.
///
/// The editor is open while an item is selected. Leaving it with unsaved edits
/// asks first, and a Save from that question leaves only once the write has
/// landed: a conflict or a rejected value keeps the user on the form.
@Reducer
public struct ConfigCollection {
    @ObservableState
    public struct State: Equatable {
        /// The pane's data and transitions.
        public var core: LeoConfigCollectionState
        public let daemon: PairedDaemon
        public let connection: DaemonConnection
        /// The machine is connected right now. A disconnect keeps the editor
        /// and its draft and says so; a reconnect reads again.
        public var isMachineConnected = true
        @Presents public var alert: AlertState<Action.Alert>?
        @Presents public var leaveDialog: ConfirmationDialogState<Action.Leave>?
        @Presents public var nameEntry: NameEntry.State?

        public init(resource: String, daemon: PairedDaemon, connection: DaemonConnection) {
            core = LeoConfigCollectionState(
                resource: resource, machineHost: daemon.baseURL.host(), webOrigin: daemon.baseURL, autoSelectsFirst: false
            )
            self.daemon = daemon
            self.connection = connection
        }
    }

    /// What a write was for, which decides what its outcome does.
    public struct WriteContext: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// The form's Save, with the draft that was sent.
            case save(sent: LeoConfigDraft)
            /// Add, rename or duplicate: the name sheet is open for it.
            case restructure
            case delete
        }

        public var kind: Kind
        public var preferring: String?
        public var selectingResult = false
        /// Close the editor once the write has landed.
        public var leaveAfter = false
    }

    public enum Action {
        case task
        case loaded(LeoConfigCollectionLoad)
        case refreshed(Result<LeoConfigCollection, Error>)
        case rowTapped(String)
        case field(String, LeoConfigValue)
        case revertTapped(String)
        case revertAllTapped
        case saveTapped
        case writeFinished(WriteContext, LeoConfigWriteOutcome)
        case reloadTapped
        case overwriteTapped
        case overwriteFinished(LeoConfigOverwriteOutcome, name: String)
        case backTapped
        case addTapped
        case renameTapped(String)
        case duplicateTapped(String)
        case deleteTapped(String)
        case dismissErrorTapped
        case dismissRestartBanner
        case restartBannerTapped
        case alert(PresentationAction<Alert>)
        case leaveDialog(PresentationAction<Leave>)
        case nameEntry(PresentationAction<NameEntry.Action>)
        case delegate(Delegate)
        case machine(Machine)

        /// The button reads the name it was shown for, never the current selection.
        @CasePathable
        public enum Alert: Equatable, Sendable {
            case confirmDelete(String)
        }

        @CasePathable
        public enum Leave: Equatable, Sendable {
            case save
            case discard
        }

        @CasePathable
        public enum Delegate {
            case restart(LeoConfigRestartRequired)
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
                return .none
            case .refreshed(let result):
                switch result {
                case .success(let collection):
                    state.core.apply(collection, preferring: state.core.selection, carrying: state.core.draft)
                case .failure(let error):
                    state.core.report(error)
                }
                return .none
            case .machine(.connectionChanged(let isConnected)):
                state.isMachineConnected = isConnected
                guard isConnected else { return .none }
                return state.core.schema == nil ? load(&state) : refresh(&state)
            case .delegate:
                return .none
            default:
                return reduceEditing(&state, action)
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$leaveDialog, action: \.leaveDialog)
        .ifLet(\.$nameEntry, action: \.nameEntry) { NameEntry() }
    }

    // MARK: editing

    private func reduceEditing(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        case .rowTapped(let name):
            guard !state.core.isDirty else { return .none }
            state.core.selectNow(name)
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
        case .restartBannerTapped:
            guard let prompt = state.core.restartPrompt else { return .none }
            state.core.dismissRestartPrompt()
            return .send(.delegate(.restart(prompt)))
        case .saveTapped:
            return save(&state, leaveAfter: false)
        case .reloadTapped:
            guard state.core.conflict != nil else { return .none }
            state.core.dismissConflict()
            return refresh(&state)
        case .overwriteTapped:
            return overwrite(&state)
        case .overwriteFinished(let outcome, let name):
            state.core.finishOverwrite(outcome, name: name)
        case .writeFinished(let context, let outcome):
            finish(&state, context, outcome)
        default:
            return reduceNavigation(&state, action)
        }
        return .none
    }

    // MARK: navigation and the questions

    private func reduceNavigation(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        case .backTapped:
            guard state.core.selection != nil else { return .none }
            guard state.core.isDirty else {
                state.core.selectNow(nil)
                return .none
            }
            state.leaveDialog = Self.leaveDialog(canSave: state.core.canSave)
        case .leaveDialog(.presented(.save)):
            return save(&state, leaveAfter: true)
        case .leaveDialog(.presented(.discard)):
            state.core.discardEdits()
            state.core.selectNow(nil)
        case .addTapped:
            guard state.core.allows(.add) else { return .none }
            state.nameEntry = NameEntry.State(kind: .add)
        case .renameTapped(let name):
            guard state.core.allows(.rename) else { return .none }
            state.nameEntry = NameEntry.State(kind: .rename(from: name))
        case .duplicateTapped(let name):
            guard state.core.allows(.duplicate) else { return .none }
            state.nameEntry = NameEntry.State(kind: .duplicate(from: name))
        case .nameEntry(.presented(.textChanged(let text))):
            guard let kind = state.nameEntry?.kind else { return .none }
            let error = state.core.nameError(text, excluding: Self.renamedItem(kind))
            state.nameEntry?.error = error
        case .nameEntry(.presented(.submitTapped)):
            return submitName(&state)
        case .nameEntry(.presented(.cancelTapped)):
            state.nameEntry = nil
        case .deleteTapped(let name):
            guard state.core.allows(.delete) else { return .none }
            state.alert = Self.deleteAlert(name)
        case .alert(.presented(.confirmDelete(let name))):
            return delete(&state, name)
        default:
            break
        }
        return .none
    }

    private static func renamedItem(_ kind: NameEntry.State.Kind) -> String? {
        if case .rename(let name) = kind { name } else { nil }
    }

    private static func leaveDialog(canSave: Bool) -> ConfirmationDialogState<Action.Leave> {
        ConfirmationDialogState {
            TextState("You have unsaved changes")
        } actions: {
            if canSave { ButtonState(action: .save) { TextState("Save") } }
            ButtonState(role: .destructive, action: .discard) { TextState("Discard Changes") }
            ButtonState(role: .cancel) { TextState("Keep Editing") }
        }
    }

    private static func deleteAlert(_ name: String) -> AlertState<Action.Alert> {
        AlertState {
            TextState("Delete “\(name)”?")
        } actions: {
            ButtonState(role: .destructive, action: .confirmDelete(name)) { TextState("Delete") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState("This can’t be undone.")
        }
    }

    // MARK: effects

    private func load(_ state: inout State) -> Effect<Action> {
        state.core.beginLoading()
        let (resource, references) = (state.core.resourceKey, state.core.references)
        let client = configClients.client(state.connection)
        return .run { send in
            await send(.loaded(await LeoConfigCollectionOps.load(resource: resource, client: client, references: references)))
        }
    }

    /// Reads the list again; the open draft is carried over the new document when it lands.
    private func refresh(_ state: inout State) -> Effect<Action> {
        let resource = state.core.resourceKey
        let client = configClients.client(state.connection)
        return .run { send in
            await send(.refreshed(Result { try await client.collection(resource) }))
        }
    }

    private func overwrite(_ state: inout State) -> Effect<Action> {
        guard let (stale, name) = state.core.beginOverwrite() else { return .none }
        let resource = state.core.resourceKey
        let client = configClients.client(state.connection)
        let revisions = configClients.revisions(state.daemon.id)
        return .run { send in
            let outcome = await LeoConfigCollectionOps.overwrite(
                stale: stale, resource: resource, name: name, client: client, revisions: revisions
            )
            await send(.overwriteFinished(outcome, name: name))
        }
    }

    private func save(_ state: inout State, leaveAfter: Bool) -> Effect<Action> {
        guard state.core.canSave, let sent = state.core.draft, let name = state.core.selection else { return .none }
        let resource = state.core.resourceKey
        let context = WriteContext(kind: .save(sent: sent), preferring: name, leaveAfter: leaveAfter)
        return write(&state, context, ifMatch: configClients.revisions(state.daemon.id).resolve(sent.revision)) { client, ifMatch in
            try await client.update(resource, name: name, patch: sent.patch, ifMatch: ifMatch)
        }
    }

    private func submitName(_ state: inout State) -> Effect<Action> {
        guard let entry = state.nameEntry else { return .none }
        let name = entry.text
        let nameError = state.core.nameError(name, excluding: Self.renamedItem(entry.kind))
        if let nameError {
            state.nameEntry?.error = nameError
            return .none
        }
        guard state.core.canRestructure else { return .none }
        let resource = state.core.resourceKey
        let ifMatch = configClients.revisions(state.daemon.id).resolve(state.core.revision)
        switch entry.kind {
        case .add:
            let context = WriteContext(kind: .restructure, preferring: name, selectingResult: true)
            return write(&state, context, ifMatch: ifMatch) { client, ifMatch in
                try await client.add(resource, name: name, values: [:], ifMatch: ifMatch)
            }
        case .rename(let from):
            return write(&state, WriteContext(kind: .restructure, preferring: nil), ifMatch: ifMatch) { client, ifMatch in
                try await client.rename(resource, name: from, to: name, ifMatch: ifMatch)
            }
        case .duplicate(let from):
            let context = WriteContext(kind: .restructure, preferring: name, selectingResult: true)
            return write(&state, context, ifMatch: ifMatch) { client, ifMatch in
                try await client.duplicate(resource, name: from, as: name, ifMatch: ifMatch)
            }
        }
    }

    private func delete(_ state: inout State, _ name: String) -> Effect<Action> {
        guard state.core.allows(.delete) else { return .none }
        let resource = state.core.resourceKey
        let ifMatch = configClients.revisions(state.daemon.id).resolve(state.core.revision)
        return write(&state, WriteContext(kind: .delete, preferring: nil), ifMatch: ifMatch) { client, ifMatch in
            try await client.delete(resource, name: name, ifMatch: ifMatch)
        }
    }

    /// Starts one write, then reads the list again.
    private func write(
        _ state: inout State, _ context: WriteContext, ifMatch: String,
        operation: @escaping @Sendable (any LeoConfigClient, String) async throws -> LeoConfigWriteResult
    ) -> Effect<Action> {
        guard state.core.beginWrite() else { return .none }
        let resource = state.core.resourceKey
        let draftRevision = state.core.draft?.revision
        let client = configClients.client(state.connection)
        let revisions = configClients.revisions(state.daemon.id)
        return .run { send in
            let outcome = await LeoConfigCollectionOps.write(
                resource: resource, client: client, revisions: revisions, ifMatch: ifMatch, draftRevision: draftRevision,
                operation: { try await operation(client, $0) }
            )
            await send(.writeFinished(context, outcome))
        }
    }

    /// A write landed or failed. Only a landed one closes the name sheet, and
    /// only a landed Save closes the editor.
    private func finish(_ state: inout State, _ context: WriteContext, _ outcome: LeoConfigWriteOutcome) {
        let failure = state.core.finishWrite(
            outcome, preferring: context.preferring, selectingResult: context.selectingResult
        )
        guard let failure else {
            state.nameEntry = nil
            if context.leaveAfter { state.core.selectNow(nil) }
            return
        }
        switch context.kind {
        case .save(let sent):
            state.core.failed(failure, sent: sent)
        case .restructure where state.nameEntry != nil:
            state.nameEntry?.error = LeoConfigCollectionState.message(for: failure)
        case .restructure, .delete:
            state.core.report(failure)
        }
    }
}
