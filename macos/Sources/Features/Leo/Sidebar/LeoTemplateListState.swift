import Foundation

/// The selected host's template list as `LeoAgentActions` publishes it for
/// every reader (New Agent sheet, a row's Set Template submenu). Only ever
/// describes the currently selected host: a host switch resets it to
/// `.loading` before the new host's fetch lands.
enum LeoTemplateListState: Equatable, Sendable {
    case loading
    case loaded([LeoTemplate])
    case failed(String)

    /// The templates to offer; empty while loading or after a failure.
    var templates: [LeoTemplate] {
        if case .loaded(let templates) = self { return templates }
        return []
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}
