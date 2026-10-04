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
    @Published private(set) var error: String?
    @Published private(set) var isSpawning = false

    /// The selected host, mirrored so a worktree spawn can tell when the
    /// user switched away from the source agent's host (D-103).
    @Published private(set) var selectedHost: LeoHostID?
    /// B-176: the agent row a "New Agent in Worktree…" spawn branches from.
    /// Nil for a plain New Agent sheet.
    let source: LeoAgentRow?

    init(templateList: AnyPublisher<LeoTemplateListState, Never>, source: LeoAgentRow? = nil,
         selectedHost: AnyPublisher<LeoHostID, Never> = Empty().eraseToAnyPublisher()) {
        self.source = source
        if let source {
            template = source.template ?? ""
            repo = source.repo ?? ""
        }
        templateList.assign(to: &$templateList)
        selectedHost.map(Optional.some).assign(to: &$selectedHost)
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
    /// valid while that is still the source agent's host.
    func hostMismatch(selected: LeoHostID?) -> String? {
        guard let source, let selected, selected != source.host else { return nil }
        return "Host changed: switch back to \(source.host.displayName) to create this agent"
    }

    /// No `base`: a worktree branch starts from origin's default branch.
    func request() -> LeoSpawnRequest {
        LeoSpawnRequest(
            template: template, repo: repo, name: name.nilIfEmpty, branch: branch.nilIfEmpty, prompt: prompt.nilIfEmpty
        )
    }

    func setError(_ value: String) { error = value }

    func spawn(_ request: LeoSpawnRequest, actions: LeoAgentActions,
               attach: @escaping (LeoAgentRow, AttachDisposition) -> Void,
               dismiss: @escaping () -> Void) {
        guard !isSpawning else { return }
        isSpawning = true
        actions.spawn(request, attach: attach, dismiss: {
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
