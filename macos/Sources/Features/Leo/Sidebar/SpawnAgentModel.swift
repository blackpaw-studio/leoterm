import Combine
import Foundation

@MainActor final class SpawnAgentModel: ObservableObject {
    @Published var template = ""
    @Published var repo = ""
    @Published var name = ""
    @Published var branch = ""
    @Published var prompt = ""
    /// The selected host's list, mirrored from `LeoAgentActions
    /// .templateList` (B-054): never fetched here, so the sheet offers
    /// exactly what a row's Set Template submenu does, for the same host.
    @Published private(set) var templateList: LeoTemplateListState = .loading
    /// B-283: the ordered environments to spawn with, prefilled from the
    /// template's default whenever the template (or the catalog) changes.
    /// Changed by the user only through `editEnvironments`.
    @Published private(set) var environments = LeoEnvironmentList([])
    /// Set by any user edit; cleared only when the template or host changes,
    /// so a catalog republish never overwrites an edited list.
    private(set) var hasUserEdited = false
    @Published private(set) var environmentCatalog: LeoEnvironmentCatalogState = .loading
    /// The template default the list follows until the user edits it; an
    /// unedited list isn't sent, so the agent isn't marked an override.
    private var environmentPrefill: [String] = []
    /// The spawn host's daemon advertises `agent_environments` now: follows
    /// hello live, so the section comes and goes with the connection.
    @Published private(set) var showsEnvironments = false
    /// The template and host `environmentPrefill` was taken for: only a
    /// change of either resets the list; a catalog republish keeps edits.
    private var prefillKey: (template: String, host: LeoHostID?)?
    private var prefillObservation: AnyCancellable?
    @Published private(set) var error: String?
    @Published private(set) var isSpawning = false

    /// The selected host, mirrored so a worktree spawn can tell when the
    /// user switched away from the source agent's host (D-103).
    @Published private(set) var selectedHost: LeoHostID?
    /// B-176: the agent row a "New Agent in Worktree…" spawn branches from.
    /// Nil for a plain New Agent sheet.
    let source: LeoAgentRow?
    private var editObservation: AnyCancellable?

    init(templateList: AnyPublisher<LeoTemplateListState, Never>, source: LeoAgentRow? = nil,
         selectedHost: AnyPublisher<LeoHostID, Never> = Empty().eraseToAnyPublisher(),
         environmentCatalog: AnyPublisher<LeoEnvironmentCatalogState, Never> = Empty().eraseToAnyPublisher(),
         environmentsSupported: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher()) {
        self.source = source
        environmentsSupported.removeDuplicates().assign(to: &$showsEnvironments)
        if let source {
            template = source.template ?? ""
            repo = source.repo ?? ""
        }
        templateList.assign(to: &$templateList)
        selectedHost.map(Optional.some).assign(to: &$selectedHost)
        editObservation = Publishers.Merge4(
            $template.dropFirst().map { _ in () }, $name.dropFirst().map { _ in () },
            $branch.dropFirst().map { _ in () }, $selectedHost.dropFirst().map { _ in () }
        ).sink { [weak self] in self?.error = nil }
        environmentCatalog.assign(to: &$environmentCatalog)
        prefillObservation = Publishers.CombineLatest3($template, $environmentCatalog, $selectedHost).sink { [weak self] template, catalog, host in
            self?.prefillEnvironments(template: template, catalog: catalog, host: host)
        }
    }

    /// A template or host change resets the list to the template's
    /// default. A catalog republish for the same pair (reconnect, refresh)
    /// only refreshes the default, and the list follows it unless edited.
    private func prefillEnvironments(template: String, catalog: LeoEnvironmentCatalogState, host: LeoHostID?) {
        let keyChanged = prefillKey.map { $0.template != template || $0.host != host } ?? true
        guard keyChanged || catalog.catalog != nil else { return }
        if keyChanged { hasUserEdited = false }
        prefillKey = (template, host)
        environmentPrefill = catalog.catalog?.defaults(for: template) ?? []
        if !hasUserEdited { environments = LeoEnvironmentList(environmentPrefill) }
    }

    /// The editor's add, remove and reorder.
    func editEnvironments(_ list: LeoEnvironmentList) {
        hasUserEdited = true
        environments = list
    }

    /// What the spawn sends: only a list the user edited.
    var requestedEnvironments: [String]? {
        guard showsEnvironments, hasUserEdited else { return nil }
        return environments.names
    }

    var isWorktree: Bool { source != nil }

    var templates: [LeoTemplate] { templateList.templates }

    var templateError: String? {
        if case .failed(let message) = templateList { return "Templates unavailable: \(message)" }
        return nil
    }
    var validationError: String? {
        if !template.isEmpty, !templates.contains(where: { $0.name == template }) {
            return "Choose an available template"
        }
        if isWorktree {
            return hostMismatch(selected: selectedHost)
                ?? SpawnValidation.worktree(template: template, repo: repo, branch: branch, name: name.nilIfEmpty)
        }
        return SpawnValidation.spawn(template: template, repo: repo, name: name.nilIfEmpty)
    }

    /// A worktree spawn runs on whichever host is selected, so it is only
    /// valid while that is still the source agent's host. Fails closed: a
    /// worktree model that was never told the selected host can't create.
    func hostMismatch(selected: LeoHostID?) -> String? {
        guard let source else { return nil }
        guard let selected else { return "Not connected to \(source.host.displayName)" }
        guard selected != source.host else { return nil }
        return "Host changed: switch back to \(source.host.displayName) to create this agent"
    }

    /// No `base`: a worktree branch starts from origin's default branch.
    func request() -> LeoSpawnRequest {
        LeoSpawnRequest(
            template: template, repo: repo, name: name.nilIfEmpty, branch: branch.nilIfEmpty, prompt: prompt.nilIfEmpty,
            environments: requestedEnvironments
        )
    }

    func setError(_ value: String) { error = value }

    func spawn(_ request: LeoSpawnRequest, actions: LeoAgentActions,
               attach: @escaping (LeoAgentRow, AttachDisposition) -> Void,
               dismiss: @escaping () -> Void) {
        guard !isSpawning else { return }
        isSpawning = true
        actions.spawn(request, on: source?.host ?? actions.hostSelection.selected, attach: attach, dismiss: {
            self.isSpawning = false
            dismiss()
        }, failure: { error in
            self.isSpawning = false
            self.setError(error)
        })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
