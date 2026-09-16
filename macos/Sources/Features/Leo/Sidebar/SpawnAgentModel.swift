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
        SpawnValidation.spawn(template: template, repo: repo, name: name.isEmpty ? nil : name)
    }

    func setError(_ value: String) { error = value }
}
