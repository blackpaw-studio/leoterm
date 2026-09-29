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

    init(templateList: AnyPublisher<LeoTemplateListState, Never>) {
        templateList.assign(to: &$templateList)
    }

    var templates: [LeoTemplate] { templateList.templates }

    var templateError: String? {
        if case .failed(let message) = templateList { return "Templates unavailable: \(message)" }
        return nil
    }
    var validationError: String? {
        if !template.isEmpty, !templates.contains(where: { $0.name == template }) {
            return "Choose an available template"
        }
        return SpawnValidation.spawn(template: template, repo: repo, name: name.isEmpty ? nil : name)
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
