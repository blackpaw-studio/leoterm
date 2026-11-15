import Combine
import Foundation
import LeoKit

/// Where the spawn sheet reads a machine's templates from, by the machine
/// name plugins use (`LeoHostID.displayName`).
struct LeoPluginSpawnTemplateFeed {
    var list: (String) -> AnyPublisher<LeoTemplateListState, Never>
    /// The sheet switched to this machine: refetch its templates.
    var reload: (String) -> Void
}

/// The spawn sheet's Template picker. The templates belong to the chosen
/// machine and are re-read when it changes; the plugin's own `template` only
/// preselects, and nothing is selected unless it is on that machine.
@MainActor final class LeoPluginSpawnTemplateModel: ObservableObject {
    @Published var machine: String {
        didSet {
            guard machine != oldValue else { return }
            feed.reload(machine)
            subscribe()
        }
    }
    @Published var template: String
    @Published private(set) var templateList: LeoTemplateListState = .loading

    private let preselect: String?
    private let feed: LeoPluginSpawnTemplateFeed
    private var subscription: AnyCancellable?

    init(machine: String, preselect: String?, feed: LeoPluginSpawnTemplateFeed) {
        self.machine = machine
        self.preselect = preselect
        self.feed = feed
        template = ""
        subscribe()
    }

    var templateNames: [String] { templateList.templates.map(\.name) }
    var templateError: String? {
        if case .failed(let message) = templateList { return "Templates unavailable: \(message)" }
        return nil
    }
    /// A template that this machine offers is selected.
    var isReady: Bool { templateNames.contains(template) }

    private func subscribe() {
        subscription = feed.list(machine).sink { [weak self] list in self?.apply(list) }
    }

    private func apply(_ list: LeoTemplateListState) {
        templateList = list
        guard list.isLoaded else { return }
        let names = list.templates.map(\.name)
        if names.contains(template) { return }
        template = preselect.flatMap { names.contains($0) ? $0 : nil } ?? ""
    }
}
