import Combine
import Foundation
import LeoKit

/// The Tasks pane: the generic collection model plus what only tasks have.
///
/// - The list's enabled toggle (a one-key write, shown at once and rolled back
///   if it fails) and Run Now.
/// - The schedule field's live reading from the daemon.
/// - The prompt editor: the task's configured `prompt_file`, with a revision of
///   its own. Another or a new file is a task write of `prompt_file`, then a
///   fresh read.
/// - The run history, newest first, and the selected run's log, read-only.
///
/// History, log and prompt are read when their page is shown and dropped when
/// the selection moves, so a late reply for the task you left never lands.
@MainActor final class LeoTasksSettingsModel: ObservableObject, LeoSettingsPane {
    enum Page: String, CaseIterable, Identifiable {
        case settings = "Settings"
        case prompt = "Prompt"
        case history = "History"

        var id: String { rawValue }
    }

    static let historyLimit = 20

    let collection: LeoConfigCollectionModel

    @Published private(set) var page = Page.settings
    @Published private(set) var message: String?
    @Published private(set) var runNotice: LeoTaskRunNotice?
    @Published private(set) var schedulePreview: LeoCronPreviewResult?
    @Published private(set) var history = LeoTasksLoad<[LeoTaskRun]>.idle
    @Published private(set) var selectedRunID: String?
    @Published private(set) var log = LeoTasksLoad<LeoTaskLog>.idle
    @Published private(set) var prompt = LeoTaskPromptState()
    @Published private var enabledOverrides: [String: Bool] = [:]

    private var client: any LeoConfigClient
    private var previewer: LeoCronPreviewer?
    private var pendingToggles: [String: Int] = [:]
    private var toggleChain: Task<Void, Never>?
    private var pageLoad: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewedSchedule: String?
    private lazy var addPreviewer = LeoCronPreviewer(fetch: makeFetch())
    private var historyToken = 0
    private var logToken = 0
    private var promptToken = 0
    private var subscriptions: Set<AnyCancellable> = []

    init(
        client: any LeoConfigClient, revisions: LeoConfigRevisionTracker, machineHost: String? = nil, previewer: LeoCronPreviewer? = nil
    ) {
        self.client = client
        collection = LeoConfigCollectionModel(resource: "tasks", client: client, revisions: revisions, machineHost: machineHost)
        self.previewer = previewer ?? LeoCronPreviewer(fetch: makeFetch())
        collection.extraUnsavedChanges = { [weak self] in self?.prompt.isDirty ?? false }
        collection.onDiscard = { [weak self] in self?.discardPromptEdits() }
        collection.$selection.removeDuplicates().sink { [weak self] in self?.selectionChanged(to: $0) }.store(in: &subscriptions)
        collection.$items.sink { [weak self] in self?.itemsChanged($0) }.store(in: &subscriptions)
        collection.$draft.sink { [weak self] in self?.draftChanged($0) }.store(in: &subscriptions)
        collection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    private var selectedTask: String? { collection.selection }

    /// The daemon read behind a preview: whichever client the pane has now.
    private func makeFetch() -> LeoCronPreviewer.Fetch {
        { [weak self] expression in
            guard let client = await self?.client else { throw CancellationError() }
            return try await client.cronPreview(expression)
        }
    }

    /// Waits for the page read and schedule reading now under way.
    func settled() async {
        await pageLoad?.value
        await previewTask?.value
    }

    // MARK: LeoSettingsPane

    var hasUnsavedChanges: Bool { collection.hasUnsavedChanges }

    func discardChanges() {
        collection.discardChanges()
    }

    /// The machine reconnected: read again. A prompt with unsaved text keeps
    /// the text and the revision it was based on, so saving it over a newer
    /// file is a conflict, not a silent overwrite.
    func reload(using client: any LeoConfigClient) async {
        self.client = client
        await collection.reload(using: client)
        guard let name = selectedTask else { return }
        if prompt.phase != .idle, !prompt.isDirty { await loadPrompt(for: name) }
        if history != .idle { await loadHistory(for: name) }
    }

    func load() async {
        await collection.load()
        await settled()
    }

    // MARK: Pages

    func setPage(_ newPage: Page) {
        page = newPage
        guard let name = selectedTask else { return }
        switch newPage {
        case .settings: break
        case .prompt: if prompt.phase == .idle { pageLoad = Task { await loadPrompt(for: name) } }
        case .history: if history == .idle { pageLoad = Task { await loadHistory(for: name) } }
        }
    }

    private func selectionChanged(to name: String?) {
        pageLoad?.cancel()
        historyToken += 1
        logToken += 1
        promptToken += 1
        runNotice = nil
        history = .idle
        selectedRunID = nil
        log = .idle
        prompt = LeoTaskPromptState()
        guard let name else { return }
        switch page {
        case .settings: break
        case .prompt: pageLoad = Task { await loadPrompt(for: name) }
        case .history: pageLoad = Task { await loadHistory(for: name) }
        }
    }

    /// The form saved a new `prompt_file` (or another writer changed it): a
    /// prompt with no edits follows it. One with edits stays; saving it over
    /// the other file is then a conflict.
    private func itemsChanged(_ items: [LeoConfigItem]) {
        guard prompt.phase != .idle, !prompt.isDirty, let name = selectedTask else { return }
        guard Self.promptFile(of: name, in: items) != prompt.file else { return }
        pageLoad = Task { await loadPrompt(for: name) }
    }

    private func configuredPromptFile(of name: String) -> String {
        Self.promptFile(of: name, in: collection.items)
    }

    private static func promptFile(of name: String, in items: [LeoConfigItem]) -> String {
        items.first { $0.name == name }?.values["prompt_file"]?.stringValue ?? ""
    }

    // MARK: Enabled toggle

    func isEnabled(_ item: LeoConfigItem) -> Bool {
        enabledOverrides[item.name] ?? item.values["enabled"]?.boolValue ?? false
    }

    /// Shows `enabled` at once and writes it alone. Toggles run one at a time;
    /// a failure rolls the switch back and says why.
    func setEnabled(_ enabled: Bool, for name: String) async {
        message = nil
        enabledOverrides[name] = enabled
        pendingToggles[name, default: 0] += 1
        let previous = toggleChain
        let toggle = Task {
            await previous?.value
            let failure = await collection.applyPatch(["enabled": .bool(enabled)], to: name)
            if let failure { message = failure }
        }
        toggleChain = toggle
        await toggle.value
        pendingToggles[name, default: 0] -= 1
        if pendingToggles[name, default: 0] <= 0 {
            pendingToggles[name] = nil
            enabledOverrides[name] = nil
        }
    }

    func dismissMessage() {
        message = nil
    }

    // MARK: Run now

    func runNow(_ name: String) async {
        runNotice = .starting(name)
        do {
            _ = try await client.runTask(name)
            runNotice = .started(name)
        } catch {
            runNotice = .failed(name, Self.message(for: error))
        }
    }

    // MARK: Add

    /// A task needs a schedule to exist; the daemon fills in the rest.
    func add(name: String, schedule: String) async {
        let schedule = schedule.trimmingCharacters(in: .whitespaces)
        guard !schedule.isEmpty else { return }
        await collection.add(name: name, values: ["schedule": .string(schedule)])
    }

    // MARK: Schedule preview

    /// The reading of a new task's schedule, from a previewer of its own so
    /// typing in the Add sheet never cancels the form's.
    func previewNewSchedule(_ expression: String) async -> LeoCronPreviewResult? {
        await addPreviewer.preview(expression)
    }

    private func draftChanged(_ draft: LeoConfigDraft?) {
        let schedule = draft?.value(at: "schedule").stringValue
        guard schedule != previewedSchedule else { return }
        previewedSchedule = schedule
        previewTask?.cancel()
        schedulePreview = nil
        guard let schedule, let previewer else { return }
        previewTask = Task {
            let result = await previewer.preview(schedule)
            guard !Task.isCancelled, previewedSchedule == schedule else { return }
            schedulePreview = result
        }
    }

    // MARK: History and log

    private func loadHistory(for name: String) async {
        historyToken += 1
        let token = historyToken
        history = .loading
        selectedRunID = nil
        log = .idle
        do {
            let runs = try await client.taskHistory(name, limit: Self.historyLimit)
            guard token == historyToken else { return }
            history = .loaded(runs)
            if let newest = runs.first { await selectRun(newest.id) }
        } catch {
            guard token == historyToken else { return }
            history = .failed(Self.message(for: error))
        }
    }

    func reloadHistory() async {
        guard let name = selectedTask else { return }
        await loadHistory(for: name)
    }

    func selectRun(_ id: String) async {
        guard case .loaded(let runs) = history, let run = runs.first(where: { $0.id == id }), let name = selectedTask else { return }
        logToken += 1
        let token = logToken
        selectedRunID = id
        guard !run.logFile.isEmpty else {
            log = .idle
            return
        }
        log = .loading
        do {
            let reply = try await client.taskLog(name, file: run.logFile)
            guard token == logToken else { return }
            log = .loaded(reply)
        } catch {
            guard token == logToken else { return }
            log = .failed(Self.message(for: error))
        }
    }

    // MARK: Prompt

    func loadPrompt(for name: String) async {
        promptToken += 1
        let token = promptToken
        prompt = LeoTaskPromptState(phase: .loading, file: configuredPromptFile(of: name))
        do {
            let document = try await client.taskPrompt(name)
            guard token == promptToken else { return }
            prompt.document = document
            prompt.text = document.content
            prompt.phase = .loaded
        } catch LeoConfigError.invalid(let errors) {
            guard token == promptToken else { return }
            prompt.phase = .unavailable(errors.first?.message ?? "The machine won't serve this prompt file.")
        } catch {
            guard token == promptToken else { return }
            prompt.phase = .failed(Self.message(for: error))
        }
    }

    func setPromptText(_ text: String) {
        guard prompt.phase == .loaded else { return }
        prompt.text = text
        prompt.error = nil
    }

    func savePrompt() async {
        guard prompt.conflict == nil, let revision = prompt.document?.revision else { return }
        await writePrompt(ifMatch: revision)
    }

    /// After a conflict: my text over the file as it is now.
    func overwritePrompt() async {
        guard let current = prompt.conflict else { return }
        await writePrompt(ifMatch: current)
    }

    /// After a conflict: theirs, dropping my text.
    func reloadPrompt() async {
        guard let name = selectedTask else { return }
        await loadPrompt(for: name)
    }

    private func writePrompt(ifMatch: String) async {
        guard prompt.phase == .loaded, prompt.isDirty, !prompt.isSaving, let name = selectedTask, let document = prompt.document else { return }
        let token = promptToken
        let sent = prompt.text
        prompt.isSaving = true
        prompt.error = nil
        defer { if token == promptToken { prompt.isSaving = false } }
        do {
            let saved = try await client.saveTaskPrompt(name, content: sent, ifMatch: ifMatch)
            guard token == promptToken else { return }
            let files = Set(document.files + [saved.file]).sorted()
            prompt.document = LeoTaskPrompt(revision: saved.revision, file: saved.file, files: files, content: sent)
            prompt.conflict = nil
        } catch LeoConfigError.conflict(let current) {
            guard token == promptToken else { return }
            prompt.conflict = current
        } catch {
            guard token == promptToken else { return }
            prompt.error = Self.message(for: error)
        }
    }

    /// Drops the unsaved prompt text (the editor's Revert).
    func revertPrompt() {
        discardPromptEdits()
    }

    private func discardPromptEdits() {
        prompt.text = prompt.document?.content ?? ""
        prompt.conflict = nil
        prompt.error = nil
        prompt.confirmation = nil
    }

    // MARK: Switching the prompt file

    /// Another file, or a new one: a task write of `prompt_file` alone (the
    /// form's other edits stay), then a fresh read. Unsaved prompt text asks first.
    func choosePromptFile(_ file: String) async {
        guard let name = selectedTask, file != prompt.document?.file else { return }
        guard !prompt.isDirty else {
            prompt.confirmation = .switchFile(file)
            return
        }
        await switchPromptFile(to: file, of: name)
    }

    func createPromptFile(_ path: String) async {
        let path = path.trimmingCharacters(in: .whitespaces)
        if let problem = LeoTaskPromptFile.problem(with: path) {
            prompt.error = problem
            return
        }
        await choosePromptFile(path)
    }

    func confirmPromptFileSwitch() async {
        guard case .switchFile(let file)? = prompt.confirmation, let name = selectedTask else { return }
        discardPromptEdits()
        await switchPromptFile(to: file, of: name)
    }

    func cancelPromptFileSwitch() {
        prompt.confirmation = nil
    }

    private func switchPromptFile(to file: String, of name: String) async {
        prompt.error = nil
        if let failure = await collection.applyPatch(["prompt_file": .string(file)], to: name) {
            prompt.error = failure
            return
        }
        await settled()
    }

    func dismissPromptError() {
        prompt.error = nil
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
