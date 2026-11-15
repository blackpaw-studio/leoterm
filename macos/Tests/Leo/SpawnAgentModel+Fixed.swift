import Combine
import Foundation
@testable import Ghostty
@testable import LeoKit

extension SpawnAgentModel {
    /// A model whose machines all read the same feeds, for tests about the
    /// rest of the sheet. This Mac, the source's machine, the context machine
    /// and `reachable` are connected; the model starts on the first of
    /// source, context, This Mac.
    convenience init(
        templateList: AnyPublisher<LeoTemplateListState, Never>, source: LeoAgentRow? = nil, context: LeoHostID? = nil,
        reachable: [LeoHostID] = [],
        environmentCatalog: AnyPublisher<LeoEnvironmentCatalogState, Never> = Empty().eraseToAnyPublisher(),
        environmentsSupported: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher()
    ) {
        let hosts = ([.local, source?.host, context].compactMap { $0 } + reachable).reduce(into: [LeoHostID]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        self.init(
            source: source, context: context,
            feeds: SpawnMachineFeeds(
                machines: Just(hosts.map { SpawnMachineOption(host: $0, status: .connected) }).eraseToAnyPublisher(),
                templateList: { _ in templateList }, environmentCatalog: { _ in environmentCatalog },
                environmentsSupported: { _ in environmentsSupported }, reload: { _ in }
            )
        )
    }
}
