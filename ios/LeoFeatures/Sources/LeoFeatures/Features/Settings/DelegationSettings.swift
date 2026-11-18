import ComposableArchitecture
import Foundation
import LeoKit

/// The Delegation screens. The pane's data and transitions are LeoKit's
/// (`LeoDelegationPaneState`, shared with the Mac); this reducer runs the
/// reads and writes (`LeoDelegationOps`) as effects and feeds each outcome
/// back as an action.
///
/// The phone has no role × profile matrix: the profiles list (the active one
/// marked) drills into one profile's roles, each opening a cell editor. The
/// cell, a role's description and the hide list are edited in sheets with
/// Cancel and Save. Make Active previews what switching changes and writes
/// only on confirm. Deletes ask with the alert's own payload.
@Reducer
public struct DelegationSettings {
    /// What the open name sheet is for.
    public enum NamePurpose: Equatable, Sendable {
        case addRole
        case renameRole(String)
        case addProfile
        case renameProfile(String)
        case duplicateProfile(String)
    }

    @ObservableState
    public struct State: Equatable {
        /// One role as a profile's screen lists it.
        public struct RoleRow: Equatable, Identifiable, Sendable {
            public let role: String
            /// "template · model · effort", or "Not routed".
            public let summary: String
            public let isRouted: Bool
            public let isDeclared: Bool
            public var id: String { role }
        }

        public var core: LeoDelegationPaneState
        public let daemon: PairedDaemon
        public let connection: DaemonConnection
        /// The machine is connected right now. A disconnect keeps the edits
        /// and says so; a reconnect reads again.
        public var isMachineConnected = true
        /// The profile whose roles are on screen.
        public var openProfile: String?
        public var isEditingHiddenAgents = false
        public var namePurpose: NamePurpose?
        @Presents public var alert: AlertState<Action.Alert>?
        @Presents public var nameEntry: NameEntry.State?

        public init(daemon: PairedDaemon, connection: DaemonConnection) {
            core = LeoDelegationPaneState(machineHost: daemon.baseURL.host(), webOrigin: daemon.baseURL)
            self.daemon = daemon
            self.connection = connection
        }

        public func roles(in profile: String) -> [RoleRow] {
            core.matrix.rows.map { row in
                let cell = core.matrix.cell(profile: profile, role: row.role.name)
                return RoleRow(
                    role: row.role.name, summary: cell.map(Self.summary) ?? String(localized: "Not routed"), isRouted: cell != nil,
                    isDeclared: row.role.declared
                )
            }
        }

        static func summary(_ cell: LeoDelegationCell) -> String {
            [cell.template, cell.effectiveModel, cell.effort].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    public enum Action {
        case task
        case loaded(LeoDelegationLoad)
        /// A read that rebases every open edit (Reload, a reconnect).
        case reread(Result<LeoDelegationDocument, Error>)
        case enabledToggled(Bool)
        case profileTapped(String)
        case profileClosed
        case cellTapped(profile: String, role: String)
        case cellTemplateChanged(String)
        case cellModelChanged(String)
        case cellEffortChanged(String)
        case cellSaveTapped
        case cellCancelTapped
        case useForTapped(String)
        case useForTextChanged(String)
        case useForSaveTapped
        case useForCancelTapped
        case hiddenAgentsTapped
        case hiddenAgentsChanged([String])
        case hiddenAgentsSaveTapped
        case hiddenAgentsCancelTapped
        case activateTapped(String)
        case previewLoaded(LeoDelegationPreviewState, profile: String)
        case activateConfirmTapped
        case activateCancelTapped
        case addRoleTapped
        case renameRoleTapped(String)
        case deleteRoleTapped(String)
        case addProfileTapped
        case renameProfileTapped(String)
        case duplicateProfileTapped(String)
        case deleteProfileTapped(String)
        case writeFinished(LeoDelegationWriteOutcome)
        case reloadTapped
        case overwriteTapped
        case dismissErrorTapped
        case dismissRestartBanner
        case restartBannerTapped(MachineRestart.Kind)
        case alert(PresentationAction<Alert>)
        case nameEntry(PresentationAction<NameEntry.Action>)
        case delegate(Delegate)
        case machine(Machine)

        /// The button carries the confirmation it was shown for.
        @CasePathable
        public enum Alert: Equatable, Sendable {
            case confirm(LeoDelegationConfirmation)
        }

        @CasePathable
        public enum Delegate {
            case restart(MachineRestart.Kind)
        }

        @CasePathable
        public enum Machine {
            case connectionChanged(Bool)
        }
    }

    enum CancelID: Hashable {
        case preview
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
            case .reread(.success(let document)):
                state.core.adopt(document, rebasing: Set(LeoDelegationEditor.allCases))
            case .reread(.failure(let error)):
                state.core.report(error)
            case .machine(.connectionChanged(let isConnected)):
                state.isMachineConnected = isConnected
                guard isConnected else { return .none }
                guard state.core.document != nil, state.core.phase == .loaded else { return load(&state) }
                state.core.dismissConflict()
                return reread(state)
            case .writeFinished(let outcome):
                finish(&state, outcome)
            case .delegate:
                break
            default:
                return reduceEditing(&state, action)
            }
            return .none
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$nameEntry, action: \.nameEntry) { NameEntry() }
    }

    // MARK: editing

    private func reduceEditing(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        case .enabledToggled(let enabled):
            return write(&state, .enabled(enabled), retryingConflict: true)
        case .profileTapped(let profile):
            guard state.core.matrix.profiles.contains(where: { $0.name == profile }) else { return .none }
            state.openProfile = profile
        case .profileClosed:
            state.openProfile = nil
        case .cellTapped(let profile, let role):
            state.core.beginCellEdit(profile: profile, role: role)
        case .cellTemplateChanged(let template):
            state.core.setCellTemplate(template)
        case .cellModelChanged(let model):
            state.core.setCellModel(model)
        case .cellEffortChanged(let effort):
            state.core.setCellEffort(effort)
        case .cellSaveTapped:
            guard state.core.cellEditor?.edit.isDirty == true else { return .none }
            return write(&state, .cell)
        case .cellCancelTapped:
            guard let editor = state.core.cellEditor, !state.core.isBusy else { return .none }
            state.core.cancelCellEdit(profile: editor.profile, role: editor.role)
        case .useForTapped(let role):
            state.core.beginUseForEdit(role: role)
        case .useForTextChanged(let text):
            state.core.setUseForText(text)
        case .useForSaveTapped:
            guard state.core.useForEditor?.isDirty == true else { return .none }
            return write(&state, .useFor)
        case .useForCancelTapped:
            guard let editor = state.core.useForEditor, !state.core.isBusy else { return .none }
            state.core.cancelUseForEdit(role: editor.role)
        default:
            return reduceLists(&state, action)
        }
        return .none
    }

    private func reduceLists(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        case .hiddenAgentsTapped:
            guard state.core.isConfigured else { return .none }
            state.isEditingHiddenAgents = true
        case .hiddenAgentsChanged(let names):
            state.core.setHiddenAgents(names)
        case .hiddenAgentsSaveTapped:
            guard state.core.hiddenAgentsEdit?.isDirty == true else {
                state.isEditingHiddenAgents = false
                return .none
            }
            return write(&state, .hiddenAgents)
        case .hiddenAgentsCancelTapped:
            guard !state.core.isBusy else { return .none }
            state.core.revertHiddenAgents()
            state.isEditingHiddenAgents = false
        case .activateTapped(let profile):
            guard state.core.beginPreview(profile) else { return .none }
            let client = configClients.client(state.connection)
            return .run { send in
                await send(.previewLoaded(await LeoDelegationOps.preview(profile, client: client), profile: profile))
            }
            .cancellable(id: CancelID.preview, cancelInFlight: true)
        case .previewLoaded(let outcome, let profile):
            state.core.finishPreview(outcome, for: profile)
        case .activateConfirmTapped:
            guard let operation = state.core.confirmActivate() else { return .none }
            return write(&state, operation)
        case .activateCancelTapped:
            state.core.cancelPreview()
            return .cancel(id: CancelID.preview)
        default:
            return reduceStructure(&state, action)
        }
        return .none
    }

    // MARK: structure

    private func reduceStructure(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        case .addRoleTapped:
            openName(&state, .addRole, NameEntry.State(kind: .add, choices: state.core.templates.map(\.name)))
        case .renameRoleTapped(let role):
            openName(&state, .renameRole(role), NameEntry.State(kind: .rename(from: role)))
        case .addProfileTapped:
            openName(&state, .addProfile, NameEntry.State(kind: .add))
        case .renameProfileTapped(let profile):
            openName(&state, .renameProfile(profile), NameEntry.State(kind: .rename(from: profile)))
        case .duplicateProfileTapped(let profile):
            openName(&state, .duplicateProfile(profile), NameEntry.State(kind: .duplicate(from: profile)))
        case .deleteRoleTapped(let role):
            state.core.requestDeleteRole(role)
            state.alert = state.core.confirmation.map { Self.deleteAlert($0, machine: state.daemon.name) }
        case .deleteProfileTapped(let profile):
            state.core.requestDeleteProfile(profile)
            state.alert = state.core.confirmation.map { Self.deleteAlert($0, machine: state.daemon.name) }
        case .alert(.presented(.confirm(let pending))):
            guard let operation = state.core.take(pending) else { return .none }
            return write(&state, operation)
        case .alert(.dismiss):
            state.core.cancelConfirmation()
        case .nameEntry(.presented(.textChanged(let text))):
            let (core, purpose) = (state.core, state.namePurpose)
            let error = purpose.flatMap { nameError(text, for: $0, in: core) }
            state.nameEntry?.error = error
        case .nameEntry(.presented(.submitTapped)):
            return submitName(&state)
        case .nameEntry(.presented(.cancelTapped)):
            state.nameEntry = nil
            state.namePurpose = nil
        case .reloadTapped:
            guard state.core.beginReload() else { return .none }
            return reread(state)
        case .overwriteTapped:
            guard let pending = state.core.conflict else { return .none }
            return write(&state, pending.operation, overwriting: true)
        case .dismissErrorTapped:
            state.core.dismissError()
        case .dismissRestartBanner:
            state.core.dismissRestartPrompt()
        case .restartBannerTapped(let kind):
            guard state.core.restartPrompt != nil else { return .none }
            state.core.dismissRestartPrompt()
            return .send(.delegate(.restart(kind)))
        default:
            break
        }
        return .none
    }

    private func openName(_ state: inout State, _ purpose: NamePurpose, _ entry: NameEntry.State) {
        guard state.core.canRestructure else { return }
        state.namePurpose = purpose
        state.nameEntry = entry
    }

    private func nameError(_ name: String, for purpose: NamePurpose, in core: LeoDelegationPaneState) -> String? {
        switch purpose {
        case .addRole: core.roleNameError(name)
        case .renameRole(let role): core.roleNameError(name, excluding: role)
        case .addProfile, .duplicateProfile: core.profileNameError(name)
        case .renameProfile(let profile): core.profileNameError(name, excluding: profile)
        }
    }

    private func submitName(_ state: inout State) -> Effect<Action> {
        guard let entry = state.nameEntry, let purpose = state.namePurpose else { return .none }
        let name = entry.text
        if let error = nameError(name, for: purpose, in: state.core) {
            state.nameEntry?.error = error
            return .none
        }
        guard state.core.canRestructure else { return .none }
        let operation: LeoDelegationOperation
        switch purpose {
        case .addRole:
            guard let template = entry.choice else {
                state.nameEntry?.error = String(localized: "Choose a template.")
                return .none
            }
            operation = .addRole(name: name, template: template)
        case .renameRole(let role): operation = .renameRole(role, to: name)
        case .addProfile: operation = .addProfile(name)
        case .renameProfile(let profile): operation = .renameProfile(profile, to: name)
        case .duplicateProfile(let profile): operation = .duplicateProfile(profile, as: name)
        }
        return write(&state, operation)
    }

    static func deleteAlert(_ confirmation: LeoDelegationConfirmation, machine: String) -> AlertState<Action.Alert> {
        let title: String
        let message: String
        switch confirmation {
        case .deleteRole(let name, let profiles):
            title = "Delete role “\(name)”?"
            message = profiles.isEmpty
                ? "“\(name)” isn’t routed by any profile. It is removed from leo.yaml on \(machine)."
                : "“\(name)” is removed from leo.yaml on \(machine), along with its routing in \(list(profiles))."
        case .deleteProfile(let name, let roleCount):
            title = "Delete profile “\(name)”?"
            message = "“\(name)” and its \(roleCount == 1 ? "1 role routing" : "\(roleCount) role routings") are removed from leo.yaml on \(machine)."
        }
        return AlertState {
            TextState(title)
        } actions: {
            ButtonState(role: .destructive, action: .confirm(confirmation)) { TextState("Delete") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState(message)
        }
    }

    private static func list(_ names: [String]) -> String {
        names.count == 1 ? "profile “\(names[0])”" : "profiles " + names.map { "“\($0)”" }.joined(separator: ", ")
    }

    // MARK: effects

    private func load(_ state: inout State) -> Effect<Action> {
        state.core.beginLoading()
        let client = configClients.client(state.connection)
        return .run { send in await send(.loaded(await LeoDelegationOps.load(client: client))) }
    }

    private func reread(_ state: State) -> Effect<Action> {
        let client = configClients.client(state.connection)
        return .run { send in await send(.reread(Result { try await client.delegation() })) }
    }

    /// Starts one write, or none while one is out. The edits and document it
    /// is built from are those of this moment.
    private func write(
        _ state: inout State, _ operation: LeoDelegationOperation, retryingConflict: Bool = false, overwriting: Bool = false
    ) -> Effect<Action> {
        guard let document = state.core.document, state.core.beginWrite(operation) else { return .none }
        let edits = state.core.edits
        let client = configClients.client(state.connection)
        let revisions = configClients.revisions(state.daemon.id)
        return .run { send in
            let outcome = await LeoDelegationOps.write(
                operation, edits: edits, document: document, client: client, revisions: revisions,
                retryingConflict: retryingConflict, overwriting: overwriting
            )
            await send(.writeFinished(outcome))
        }
    }

    /// A write landed or failed. A landed one closes the sheet it came from;
    /// a refused name stays in its sheet with the daemon's message.
    private func finish(_ state: inout State, _ outcome: LeoDelegationWriteOutcome) {
        state.core.finishWrite(outcome)
        let landed: Bool
        if case .sent(_, _, let readBack) = outcome.reply { landed = readBack != nil } else { landed = false }
        if outcome.operation.changesStructure, state.nameEntry != nil {
            if landed {
                state.nameEntry = nil
                state.namePurpose = nil
            } else if case .failed(let error) = outcome.reply, !Self.isConflict(error) {
                state.nameEntry?.error = LeoDelegationPaneState.message(for: error)
            }
        }
        if landed, outcome.operation == .hiddenAgents { state.isEditingHiddenAgents = false }
        if landed { followOpenProfile(&state, after: outcome.operation) }
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case LeoConfigError.conflict = error { true } else { false }
    }

    /// The open profile follows a rename and closes when it is gone.
    private func followOpenProfile(_ state: inout State, after operation: LeoDelegationOperation) {
        guard let open = state.openProfile else { return }
        if case .renameProfile(let old, let new) = operation, old == open {
            state.openProfile = new
        } else if !state.core.matrix.profiles.contains(where: { $0.name == open }) {
            state.openProfile = nil
        }
    }
}
