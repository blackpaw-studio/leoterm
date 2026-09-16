import Combine
import Foundation

@MainActor final class SpawnAgentModel: ObservableObject {
    @Published var template = ""
    @Published var repo = ""
    @Published var name = ""
    @Published var branch = ""
    @Published var prompt = ""
    @Published private(set) var templates: [LeoTemplate] = []
    @Published private(set) var error: String?
    @Published private(set) var isSpawning = false
    private let cli: LeoCLI

    init(cli: LeoCLI) { self.cli = cli }
    func loadTemplates() async {
        do {
            templates = try await cli.templateList()
        } catch {
            self.error = error.localizedDescription
        }
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
