import Combine
import Foundation
import LeoKit

@MainActor final class SpawnAgentModel: ObservableObject {
    @Published var template = ""
    @Published var repo = ""
    @Published var name = ""
    @Published var branch = ""
    @Published var prompt = ""
    /// The chosen machine's list, mirrored from `LeoAgentActions
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

    /// The machine the agent will run on. Changed only by `choose`, and
    /// never for a worktree spawn, which runs where its source agent is.
    @Published private(set) var machine: LeoHostID = .local
    /// Every machine, with where it stands; unreachable ones are listed but
    /// can't be chosen.
    @Published private(set) var machineOptions: [SpawnMachineOption] = []
    /// B-176: the agent row a "New Agent in Worktree…" spawn branches from.
    /// Nil for a plain New Agent sheet.
    let source: LeoAgentRow?
    private let feeds: SpawnMachineFeeds
    private let remember: (LeoHostID) -> Void
    private var editObservation: AnyCancellable?

    /// `context`: the machine "New Agent Here" (or a board, or a row) was
    /// opened from. `lastUsed`: the machine of the last successful spawn.
    /// `remember` is told the machine after every successful spawn.
    init(source: LeoAgentRow? = nil, context: LeoHostID? = nil, lastUsed: LeoHostID? = nil,
         feeds: SpawnMachineFeeds, remember: @escaping (LeoHostID) -> Void = { _ in }) {
        self.source = source
        self.feeds = feeds
        self.remember = remember
        feeds.machines.assign(to: &$machineOptions)
        machine = source?.host ?? LeoSpawnMachineDefault.resolve(
            context: context, lastUsed: lastUsed,
            statuses: Dictionary(machineOptions.map { ($0.host, $0.status) }, uniquingKeysWith: { first, _ in first })
        )
        if let source {
            template = source.template ?? ""
            repo = source.repo ?? ""
        }
        $machine.map(feeds.templateList).switchToLatest().assign(to: &$templateList)
        $machine.map(feeds.environmentCatalog).switchToLatest().assign(to: &$environmentCatalog)
        $machine.map(feeds.environmentsSupported).switchToLatest().removeDuplicates().assign(to: &$showsEnvironments)
        editObservation = Publishers.Merge4(
            $template.dropFirst().map { _ in () }, $name.dropFirst().map { _ in () },
            $branch.dropFirst().map { _ in () }, $machine.dropFirst().map { _ in () }
        ).sink { [weak self] in self?.error = nil }
        prefillObservation = Publishers.CombineLatest3($template, $environmentCatalog, $machine).sink { [weak self] template, catalog, host in
            self?.prefillEnvironments(template: template, catalog: catalog, host: host)
        }
    }

    /// Picks the machine to spawn on and re-reads its templates, environment
    /// options and feature gates. A template the new machine lacks stays
    /// chosen, and `validationError` says so. Ignored for a worktree spawn, and for a
    /// machine that is unreachable or not listed.
    func choose(_ host: LeoHostID) {
        guard !isMachineLocked, host != machine, isSelectable(host) else { return }
        machine = host
        feeds.reload(host)
    }

    /// A worktree spawn branches from its source agent's repository, which
    /// only exists on that agent's machine.
    var isMachineLocked: Bool { source != nil }

    /// "Choose…" opens a folder on this Mac, which means nothing on another
    /// machine, where the path has to be typed.
    var canBrowseRepository: Bool { machine == .local }

    /// A machine missing from the list is not selectable, except This Mac.
    private func isSelectable(_ host: LeoHostID) -> Bool {
        machineOptions.first { $0.host == host }?.isSelectable ?? (host == .local)
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
        if !isSelectable(machine) { return "\(SpawnMachineOption.title(for: machine)) is unavailable" }
        if !template.isEmpty, !templates.contains(where: { $0.name == template }) {
            return "Choose an available template"
        }
        if isWorktree {
            return SpawnValidation.worktree(template: template, repo: repo, branch: branch, name: name.nilIfEmpty)
        }
        return SpawnValidation.spawn(template: template, repo: repo, name: name.nilIfEmpty, on: machine)
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
        let host = machine
        actions.spawn(request, on: host, attach: attach, dismiss: {
            self.isSpawning = false
            self.remember(host)
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
