import ComposableArchitecture
import Foundation
import LeoKit

/// A machine's Tasks screens: the list with its switches and Run Now, and the
/// open task's form, cron preview, prompt, history and log. The list and the
/// form are `ConfigCollection` (resource `tasks`); this adds what only tasks
/// have, over LeoKit's shared pieces (`LeoTaskPromptState`,
/// `LeoTaskToggleOverrides`, `LeoCronPreviewer`).
///
/// Everything that belongs to the open task (history, log, prompt, preview)
/// is cleared and cancelled when the selection changes, and every reply
/// names the task it was asked for, so a late one never lands on another.
@Reducer
public struct TaskSettings {
    /// A screen pushed over the open task.
    public enum Page: Equatable, Sendable {
        case prompt
        case history
        case log
    }

    struct ToggleRequest: Equatable, Sendable {
        let name: String
        let enabled: Bool
    }

    /// The schedule a preview was asked for, on the task it belongs to.
    struct PreviewKey: Equatable, Sendable {
        let task: String
        let schedule: String
    }

    @ObservableState
    public struct State: Equatable {
        public var collection: ConfigCollection.State
        public var toggles = LeoTaskToggleOverrides()
        var toggleQueue: [ToggleRequest] = []
        var toggleInFlight: ToggleRequest?
        /// A switch that didn't take, or another failure of the list.
        public var message: String?
        public var runNotice: LeoTaskRunNotice?
        /// What the open task's schedule means, as the form shows it.
        public var preview: LeoCronPreviewResult?
        var previewKey: PreviewKey?
        public var page: Page?
        public var history: LeoTasksLoad<[LeoTaskRun]> = .idle
        public var selectedRun: LeoTaskRun?
        public var log: LeoTasksLoad<LeoTaskLog> = .idle
        public var prompt = LeoTaskPromptState()
        /// The task the per-task state above belongs to.
        var activeTask: String?
        @Presents public var promptDialog: ConfirmationDialogState<Action.PromptChoice>?
        @Presents public var formSaveDialog: ConfirmationDialogState<Action.FormSaveChoice>?
        @Presents public var promptLeave: ConfirmationDialogState<Action.PromptLeave>?

        public init(daemon: PairedDaemon, connection: DaemonConnection) {
            collection = ConfigCollection.State(resource: "tasks", daemon: daemon, connection: connection)
        }
    }

    /// What a re-read of the prompt file is for.
    public enum Reread: Equatable, Sendable {
        /// Take the file as it is now (Reload, or Discard for the new file).
        case replace
        /// The task follows another file: put the typed text on it and save.
        case keepText(String)
    }

    public enum Action {
        case collection(ConfigCollection.Action)
        case toggleTapped(String, Bool)
        case runNowTapped(String)
        case runFinished(String, Result<LeoTaskRunStart, Error>)
        case dismissMessage
        case dismissRunNotice
        case previewed(String, String, LeoCronPreviewResult?)
        case addPreviewed(String, LeoCronPreviewResult?)

        case pageOpened(Page)
        case pagePopped(Page)
        case historyLoaded(String, Result<[LeoTaskRun], Error>)
        case runTapped(LeoTaskRun)
        case logLoaded(String, String, Result<LeoTaskLog, Error>)

        case promptLoaded(String, Result<LeoTaskPrompt, Error>)
        case promptTextChanged(String)
        case promptSaveTapped
        case promptSaved(String, String, leaveAfter: Bool, Result<LeoTaskPromptWrite, Error>)
        case promptConflictChecked(String, served: LeoTaskPrompt?, current: String)
        case promptReloadTapped
        case promptOverwriteTapped
        case promptRevertTapped
        case promptReread(String, Reread, Result<LeoTaskPrompt, Error>)
        case promptBackTapped
        case dismissPromptError
        case promptDialog(PresentationAction<PromptChoice>)
        case formSaveDialog(PresentationAction<FormSaveChoice>)
        case promptLeave(PresentationAction<PromptLeave>)
        case delegate(Delegate)

        @CasePathable
        public enum PromptChoice: Equatable, Sendable {
            /// Write the text typed for the old file to the new one.
            case keepText
            /// Drop it and take the new file as it is.
            case discardText
        }

        @CasePathable
        public enum FormSaveChoice: Equatable, Sendable {
            case discardPromptAndSave
        }

        @CasePathable
        public enum PromptLeave: Equatable, Sendable {
            case save
            case discard
        }

        @CasePathable
        public enum Delegate {
            case restart(LeoConfigRestartRequired)
        }
    }

    enum CancelID: Hashable {
        case history, log, prompt, preview, addPreview
    }

    static let historyLimit = 20

    @Dependency(\.configClients) var configClients
    @Dependency(\.continuousClock) var clock

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.collection, action: \.collection) { ConfigCollection() }
        Reduce { state, action in
            switch action {
            case .collection(let action):
                return reduceCollection(&state, action)
            case .toggleTapped(let name, let enabled):
                state.message = nil
                state.toggles.begin(name, enabled: enabled)
                state.toggleQueue.append(ToggleRequest(name: name, enabled: enabled))
                return startNextToggle(&state)
            case .runNowTapped(let name):
                return runNow(&state, name)
            case .runFinished(let name, let result):
                guard state.runNotice == .starting(name) else { return .none }
                switch result {
                case .success: state.runNotice = .started(name)
                case .failure(let error): state.runNotice = .failed(name, LeoConfigCollectionState.message(for: error))
                }
                return .none
            case .dismissMessage:
                state.message = nil
                return .none
            case .dismissRunNotice:
                state.runNotice = nil
                return .none
            case .previewed(let task, let schedule, let result):
                guard state.previewKey == PreviewKey(task: task, schedule: schedule) else { return .none }
                state.preview = result
                return .none
            case .addPreviewed(let schedule, let result):
                guard state.collection.nameEntry?.schedule == schedule else { return .none }
                state.collection.nameEntry?.schedulePreview = result
                return .none
            case .delegate:
                return .none
            case .pageOpened(.prompt), .pagePopped(.prompt):
                return reducePrompt(&state, action)
            case .pageOpened, .pagePopped, .historyLoaded, .runTapped, .logLoaded:
                return reduceHistory(&state, action)
            default:
                return reducePrompt(&state, action)
            }
        }
        .ifLet(\.$promptDialog, action: \.promptDialog)
        .ifLet(\.$formSaveDialog, action: \.formSaveDialog)
        .ifLet(\.$promptLeave, action: \.promptLeave)
        Reduce { state, action in sync(&state, action) }
    }

    // MARK: the list

    private func reduceCollection(_ state: inout State, _ action: ConfigCollection.Action) -> Effect<Action> {
        switch action {
        case .delegate(.patchFinished(let name, let failure)):
            guard state.toggleInFlight?.name == name else { return .none }
            if let failure { state.message = failure }
            state.toggles.finish(name)
            state.toggleInFlight = nil
            return startNextToggle(&state)
        case .delegate(.restart(let required)):
            return .send(.delegate(.restart(required)))
        case .delegate(.saveHeld):
            let patch = state.collection.core.draft?.patch ?? [:]
            _ = state.prompt.formSaveAllowed(patch: patch)
            return .none
        case .delegate(.discarded):
            state.prompt.discardEdits()
            return .none
        case .nameEntry(.presented(.scheduleChanged(let schedule))):
            return previewAdd(state, schedule)
        default:
            return .none
        }
    }

    /// Switches are written one at a time, in the order they were flipped.
    private func startNextToggle(_ state: inout State) -> Effect<Action> {
        guard state.toggleInFlight == nil, !state.toggleQueue.isEmpty else { return .none }
        let next = state.toggleQueue.removeFirst()
        state.toggleInFlight = next
        return .send(.collection(.patch(name: next.name, patch: ["enabled": .bool(next.enabled)])))
    }

    private func runNow(_ state: inout State, _ name: String) -> Effect<Action> {
        guard state.runNotice != .starting(name) else { return .none }
        state.runNotice = .starting(name)
        let client = configClients.client(state.collection.connection)
        return .run { send in
            await send(.runFinished(name, Result { try await client.runTask(name) }))
        }
    }

    private func previewAdd(_ state: State, _ schedule: String) -> Effect<Action> {
        let client = configClients.client(state.collection.connection)
        return preview(schedule, client: client) { .addPreviewed(schedule, $0) }
            .cancellable(id: CancelID.addPreview, cancelInFlight: true)
    }

    // MARK: history and log

    private func reduceHistory(_ state: inout State, _ action: Action) -> Effect<Action> {
        guard let task = state.collection.core.selection else { return .none }
        switch action {
        case .pageOpened(.history):
            state.page = .history
            switch state.history {
            case .idle, .failed: return loadHistory(&state, task)
            case .loading, .loaded: return .none
            }
        case .pageOpened(.log):
            state.page = .log
        case .pagePopped(.history):
            if state.page == .history || state.page == .log { state.page = nil }
        case .pagePopped(.log):
            if state.page == .log { state.page = .history }
        case .historyLoaded(let reply, let result):
            guard reply == task else { return .none }
            switch result {
            case .success(let runs):
                state.history = .loaded(runs)
                state.selectedRun = runs.first
                return state.selectedRun.map { loadLog(&state, task, $0) } ?? .none
            case .failure(let error):
                state.history = .failed(LeoConfigCollectionState.message(for: error))
            }
        case .runTapped(let run):
            state.selectedRun = run
            state.page = .log
            return loadLog(&state, task, run)
        case .logLoaded(let reply, let file, let result):
            guard reply == task, state.selectedRun?.logFile == file else { return .none }
            switch result {
            case .success(let log): state.log = .loaded(log.tail())
            case .failure(let error): state.log = .failed(LeoConfigCollectionState.message(for: error))
            }
        default:
            break
        }
        return .none
    }

    private func loadHistory(_ state: inout State, _ task: String) -> Effect<Action> {
        state.history = .loading
        let client = configClients.client(state.collection.connection)
        return .run { send in
            await send(.historyLoaded(task, Result { try await client.taskHistory(task, limit: Self.historyLimit) }))
        }
        .cancellable(id: CancelID.history, cancelInFlight: true)
    }

    private func loadLog(_ state: inout State, _ task: String, _ run: LeoTaskRun) -> Effect<Action> {
        guard !run.logFile.isEmpty else {
            state.log = .failed("This run left no log.")
            return .cancel(id: CancelID.log)
        }
        state.log = .loading
        let client = configClients.client(state.collection.connection)
        let file = run.logFile
        return .run { send in
            await send(.logLoaded(task, file, Result { try await client.taskLog(task, file: file) }))
        }
        .cancellable(id: CancelID.log, cancelInFlight: true)
    }

    // MARK: prompt

    private func reducePrompt(_ state: inout State, _ action: Action) -> Effect<Action> {
        guard let task = state.collection.core.selection else { return .none }
        switch action {
        case .pageOpened(.prompt):
            state.page = .prompt
            switch state.prompt.phase {
            case .idle, .failed: return loadPrompt(&state, task)
            case .loading, .loaded, .unavailable: return .none
            }
        case .pagePopped(.prompt):
            if state.page == .prompt, !state.prompt.isDirty { closePrompt(&state) }
        case .promptLoaded(let reply, let result):
            guard reply == task else { return .none }
            switch result {
            case .success(let document): install(document, in: &state)
            case .failure(let error): state.prompt.phase = Self.phase(for: error)
            }
        case .promptTextChanged(let text):
            state.prompt.text = text
        case .promptSaveTapped:
            return savePrompt(&state, task, leaveAfter: false)
        case .promptSaved(let reply, let sent, let leaveAfter, let result):
            guard reply == task else { return .none }
            return promptSaved(&state, task, sent: sent, leaveAfter: leaveAfter, result)
        case .promptConflictChecked(let reply, let served, let current):
            guard reply == task else { return .none }
            state.prompt.conflictOutcome(served: served, current: current)
        case .promptReloadTapped:
            guard state.prompt.conflict != nil else { return .none }
            return reread(state, task, .replace)
        case .promptOverwriteTapped:
            guard let current = state.prompt.conflict else { return .none }
            return savePrompt(&state, task, leaveAfter: false, ifMatch: current, checkingFile: false)
        case .promptRevertTapped:
            state.prompt.discardEdits()
        case .promptReread(let reply, let intent, let result):
            guard reply == task else { return .none }
            return rereadFinished(&state, task, intent, result)
        case .promptBackTapped:
            guard state.prompt.isDirty else {
                closePrompt(&state)
                return .none
            }
            state.promptLeave = Self.leaveDialog(canSave: state.prompt.canWrite)
        case .dismissPromptError:
            state.prompt.error = nil
        case .promptLeave(.presented(.save)):
            return savePrompt(&state, task, leaveAfter: true)
        case .promptLeave(.presented(.discard)):
            state.prompt.discardEdits()
            closePrompt(&state)
        case .promptDialog(.presented(let choice)):
            return answerFileChanged(&state, task, choice)
        case .promptDialog(.dismiss):
            state.prompt.confirmation = nil
        case .formSaveDialog(.presented(.discardPromptAndSave)):
            state.prompt.discardEdits()
            return .send(.collection(.saveTapped))
        case .formSaveDialog(.dismiss):
            state.prompt.confirmation = nil
        default:
            break
        }
        return .none
    }

    private static func phase(for error: Error) -> LeoTaskPromptState.Phase {
        let message = LeoConfigCollectionState.message(for: error)
        if case LeoConfigError.invalid = error { return .unavailable(message) }
        return .failed(message)
    }

    private func closePrompt(_ state: inout State) {
        state.page = nil
        state.prompt = LeoTaskPromptState()
        state.promptDialog = nil
        state.promptLeave = nil
    }

    private func install(_ document: LeoTaskPrompt, in state: inout State) {
        state.prompt.phase = .loaded
        state.prompt.file = document.file
        state.prompt.document = document
        state.prompt.text = document.content
        state.prompt.conflict = nil
        state.prompt.error = nil
        state.prompt.confirmation = nil
    }

    private func loadPrompt(_ state: inout State, _ task: String) -> Effect<Action> {
        state.prompt = LeoTaskPromptState(phase: .loading, file: state.configuredPromptFile)
        let client = configClients.client(state.collection.connection)
        return .run { send in
            await send(.promptLoaded(task, Result { try await client.taskPrompt(task) }))
        }
        .cancellable(id: CancelID.prompt, cancelInFlight: true)
    }

    /// Reads the file the task is configured with now.
    private func reread(_ state: State, _ task: String, _ intent: Reread) -> Effect<Action> {
        let client = configClients.client(state.collection.connection)
        return .run { send in
            await send(.promptReread(task, intent, Result { try await client.taskPrompt(task) }))
        }
        .cancellable(id: CancelID.prompt, cancelInFlight: true)
    }

    private func rereadFinished(
        _ state: inout State, _ task: String, _ intent: Reread, _ result: Result<LeoTaskPrompt, Error>
    ) -> Effect<Action> {
        switch result {
        case .failure(let error):
            state.prompt.error = LeoConfigCollectionState.message(for: error)
            return .none
        case .success(let document):
            install(document, in: &state)
            guard case .keepText(let text) = intent else { return .none }
            state.prompt.text = text
            return savePrompt(&state, task, leaveAfter: false, checkingFile: false)
        }
    }

    private func answerFileChanged(_ state: inout State, _ task: String, _ choice: Action.PromptChoice) -> Effect<Action> {
        state.prompt.confirmation = nil
        switch choice {
        case .keepText: return reread(state, task, .keepText(state.prompt.text))
        case .discardText: return reread(state, task, .replace)
        }
    }

    private static func leaveDialog(canSave: Bool) -> ConfirmationDialogState<Action.PromptLeave> {
        ConfirmationDialogState {
            TextState("You have unsaved changes")
        } actions: {
            if canSave { ButtonState(action: .save) { TextState("Save") } }
            ButtonState(role: .destructive, action: .discard) { TextState("Discard Changes") }
            ButtonState(role: .cancel) { TextState("Keep Editing") }
        }
    }

    private static func fileChangedDialog(_ file: String) -> ConfirmationDialogState<Action.PromptChoice> {
        ConfirmationDialogState {
            TextState("This task now uses \(file)")
        } actions: {
            ButtonState(action: .keepText) { TextState("Keep My Text for \(file)") }
            ButtonState(role: .destructive, action: .discardText) { TextState("Discard My Text") }
            ButtonState(role: .cancel) { TextState("Keep Editing") }
        } message: {
            TextState("The text you typed was for the file it used before.")
        }
    }

    private static func formSaveDialog(_ file: String) -> ConfirmationDialogState<Action.FormSaveChoice> {
        ConfirmationDialogState {
            TextState("This task will use \(file)")
        } actions: {
            ButtonState(role: .destructive, action: .discardPromptAndSave) { TextState("Discard Prompt Text and Save") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState("Your unsaved prompt text is for the file it uses now.")
        }
    }

    /// Writes the typed text to the file it was read from. `ifMatch` is the
    /// file's own revision; `checkingFile: false` skips the question of
    /// whether the task still uses that file (it was just answered).
    private func savePrompt(
        _ state: inout State, _ task: String, leaveAfter: Bool, ifMatch: String? = nil, checkingFile: Bool = true
    ) -> Effect<Action> {
        guard state.prompt.canWrite, let document = state.prompt.document else { return .none }
        if checkingFile, state.prompt.saveCheck(configuredFile: state.configuredPromptFile) == .askFileChanged { return .none }
        state.prompt.isSaving = true
        state.prompt.error = nil
        let (sent, revision) = (state.prompt.text, ifMatch ?? document.revision)
        let client = configClients.client(state.collection.connection)
        return .run { send in
            let result = await Result { try await client.saveTaskPrompt(task, content: sent, ifMatch: revision) }
            await send(.promptSaved(task, sent, leaveAfter: leaveAfter, result))
        }
    }

    private func promptSaved(
        _ state: inout State, _ task: String, sent: String, leaveAfter: Bool, _ result: Result<LeoTaskPromptWrite, Error>
    ) -> Effect<Action> {
        state.prompt.isSaving = false
        switch result {
        case .success(let write):
            state.prompt.saved(write, sent: sent)
            if leaveAfter { closePrompt(&state) }
            return .none
        case .failure(LeoConfigError.conflict(let current)):
            let client = configClients.client(state.collection.connection)
            return .run { send in
                await send(.promptConflictChecked(task, served: try? await client.taskPrompt(task), current: current))
            }
        case .failure(let error):
            state.prompt.error = LeoConfigCollectionState.message(for: error)
            return .none
        }
    }

    // MARK: keeping the task's state in step

    /// Runs after every action: the state that belongs to the open task is
    /// reset when the selection changes, the schedule preview follows the
    /// draft, and the form learns what the prompt needs of its Save.
    private func sync(_ state: inout State, _ action: Action) -> Effect<Action> {
        var effects: [Effect<Action>] = []
        let selection = state.collection.core.selection
        if selection != state.activeTask {
            state.activeTask = selection
            state.history = .idle
            state.selectedRun = nil
            state.log = .idle
            state.prompt = LeoTaskPromptState()
            state.page = nil
            state.promptDialog = nil
            state.formSaveDialog = nil
            state.promptLeave = nil
            state.preview = nil
            state.previewKey = nil
            effects.append(.merge(.cancel(id: CancelID.history), .cancel(id: CancelID.log), .cancel(id: CancelID.prompt), .cancel(id: CancelID.preview)))
        }
        effects.append(syncPreview(&state))
        effects.append(syncPrompt(&state, action))
        return .merge(effects)
    }

    /// The prompt's side of the form: whether Save must wait on a question, and
    /// what the task's list changing means for an open prompt. The prompt's
    /// questions become dialogs.
    private func syncPrompt(_ state: inout State, _ action: Action) -> Effect<Action> {
        var probe = state.prompt
        state.collection.saveHeld = !probe.formSaveAllowed(patch: state.collection.core.draft?.patch ?? [:])
        state.collection.extraUnsaved = state.prompt.isDirty
        var effect = Effect<Action>.none
        if Self.changesList(action), let task = state.collection.core.selection {
            let change = state.prompt.itemsChanged(configuredFile: state.configuredPromptFile)
            if change == .reload { effect = loadPrompt(&state, task) }
        }
        switch state.prompt.confirmation {
        case .saveWithFile(let file)?:
            if state.formSaveDialog == nil { state.formSaveDialog = Self.formSaveDialog(file) }
        case .fileChanged(let file)?:
            if state.promptDialog == nil { state.promptDialog = Self.fileChangedDialog(file) }
        case .switchFile?, nil:
            break
        }
        return effect
    }

    private static func changesList(_ action: Action) -> Bool {
        switch action {
        case .collection(.loaded), .collection(.refreshed), .collection(.writeFinished), .collection(.overwriteFinished): true
        default: false
        }
    }

    private func syncPreview(_ state: inout State) -> Effect<Action> {
        let key = state.collection.core.selection.flatMap { task in
            state.collection.core.draft?.value(at: "schedule").stringValue.map { PreviewKey(task: task, schedule: $0) }
        }
        guard key != state.previewKey else { return .none }
        state.previewKey = key
        state.preview = nil
        guard let key else { return .cancel(id: CancelID.preview) }
        let client = configClients.client(state.collection.connection)
        return preview(key.schedule, client: client) { .previewed(key.task, key.schedule, $0) }
            .cancellable(id: CancelID.preview, cancelInFlight: true)
    }

    private func preview(
        _ schedule: String, client: any LeoConfigClient, reply: @escaping @Sendable (LeoCronPreviewResult?) -> Action
    ) -> Effect<Action> {
        let clock = clock
        return .run { send in
            let previewer = LeoCronPreviewer(sleep: { try await clock.sleep(for: $0) }, fetch: { try await client.cronPreview($0) })
            await send(reply(await previewer.preview(schedule)))
        }
    }
}

extension TaskSettings.State {
    /// The configured prompt file of the open task.
    var configuredPromptFile: String {
        collection.core.items.first { $0.name == collection.core.selection }?.values["prompt_file"]?.stringValue ?? ""
    }
}
