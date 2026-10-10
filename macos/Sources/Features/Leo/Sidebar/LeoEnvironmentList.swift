import Foundation

/// The selected host's environment catalog as `LeoAgentActions` publishes
/// it (B-283): reset to `.loading` on a host switch, like `templateList`.
enum LeoEnvironmentCatalogState: Equatable, Sendable {
    case loading
    case loaded(LeoEnvironmentCatalog)
    case failed(String)

    var catalog: LeoEnvironmentCatalog? {
        if case .loaded(let catalog) = self { return catalog }
        return nil
    }
}

/// An ordered list of environment names (B-283). Order is the user's; the
/// daemon applies them in this order. One value serves the spawn sheet, the
/// Set Environments submenu and the Edit Order sheet.
struct LeoEnvironmentList: Equatable, Sendable {
    let names: [String]

    init(_ names: [String]) {
        self.names = names
    }

    func contains(_ name: String) -> Bool { names.contains(name) }

    /// Appends; a name already listed keeps its place.
    func adding(_ name: String) -> LeoEnvironmentList {
        contains(name) ? self : LeoEnvironmentList(names + [name])
    }

    func removing(_ name: String) -> LeoEnvironmentList {
        LeoEnvironmentList(names.filter { $0 != name })
    }

    /// The submenu's toggle: on appends to the end, off removes.
    func toggling(_ name: String) -> LeoEnvironmentList {
        contains(name) ? removing(name) : adding(name)
    }

    /// Moves `name` up (negative) or down (positive), stopping at the ends.
    func moving(_ name: String, by offset: Int) -> LeoEnvironmentList {
        guard let index = names.firstIndex(of: name) else { return self }
        let target = min(max(index + offset, 0), names.count - 1)
        guard target != index else { return self }
        var next = names
        next.remove(at: index)
        next.insert(name, at: target)
        return LeoEnvironmentList(next)
    }

    /// SwiftUI's `onMove` reorder.
    func moving(fromOffsets source: IndexSet, toOffset destination: Int) -> LeoEnvironmentList {
        let moved = source.map { names[$0] }
        let before = names.enumerated().filter { $0.offset < destination && !source.contains($0.offset) }.map(\.element)
        let after = names.enumerated().filter { $0.offset >= destination && !source.contains($0.offset) }.map(\.element)
        return LeoEnvironmentList(before + moved + after)
    }

    /// The catalog's names not yet listed, alphabetically.
    func addable(from catalog: [String]) -> [String] {
        catalog.filter { !contains($0) }.sorted()
    }
}

/// One item of the Set Environments submenu, the same in the row's context
/// menu and the Agent menu.
enum LeoEnvironmentMenuEntry: Equatable, Sendable {
    case placeholder(String)
    case toggle(name: String, isOn: Bool)
    /// Switch to ▸ item: replaces the whole list with just `name`.
    case switchTo(name: String, isCurrent: Bool)
    case separator
    case editOrder(isEnabled: Bool)
    case reset(isEnabled: Bool)
}

enum LeoEnvironmentMenu {
    static let title = "Set Environments"
    static let editOrderTitle = "Edit Order…"
    static let resetTitle = "Reset to Template Default"

    /// One toggle per configured name (alphabetical), checked when it is in
    /// effect, then any effective name config no longer has (so it can be
    /// turned off); then Edit Order… and Reset, which is only for an override.
    static func entries(catalog: LeoEnvironmentCatalogState, current: LeoAgentEnvironments?) -> [LeoEnvironmentMenuEntry] {
        let effective = current?.names ?? []
        let tail: [LeoEnvironmentMenuEntry] = [
            .separator, .editOrder(isEnabled: catalog.catalog != nil), .reset(isEnabled: current?.isOverride == true),
        ]
        switch catalog {
        case .loading:
            return [.placeholder("Loading…")] + tail
        case .failed(let message):
            return [.placeholder("Environments Unavailable: \(message)")] + tail
        case .loaded(let catalog):
            let missing = effective.filter { !catalog.names.contains($0) }
            let names = catalog.names + missing
            guard !names.isEmpty else { return [.placeholder("No Environments")] + tail }
            return names.map { .toggle(name: $0, isOn: effective.contains($0)) } + tail
        }
    }
}

/// The Switch to submenu next to Set Environments: one item per configured
/// environment, checked only when it is the agent's sole one, so changing
/// from A to B is one pick and one restart instead of two toggles.
enum LeoEnvironmentSwitchMenu {
    static let title = "Switch to"

    static func entries(catalog: LeoEnvironmentCatalogState, current: LeoAgentEnvironments?) -> [LeoEnvironmentMenuEntry] {
        switch catalog {
        case .loading:
            return [.placeholder("Loading…")]
        case .failed(let message):
            return [.placeholder("Environments Unavailable: \(message)")]
        case .loaded(let catalog):
            guard !catalog.names.isEmpty else { return [.placeholder("No Environments")] }
            return catalog.names.map { .switchTo(name: $0, isCurrent: current?.names == [$0]) }
        }
    }
}

/// What every environment change asks first: the agent restarts.
struct LeoEnvironmentConfirmation: Equatable {
    let title: String
    let message: String
    let confirmTitle = "Restart and Resume"

    init(agent: String, names: [String]) {
        title = "Restart “\(agent)” with new environments?"
        message = names.isEmpty
            ? "\(agent) restarts and resumes its session with its template’s default environments."
            : "\(agent) restarts and resumes its session with: \(names.joined(separator: ", "))."
    }
}
