import Foundation
import LeoKit

/// A machine in the Settings sidebar. Keyed by the configuration's UUID, not
/// by name, so renaming a remote keeps the selection on it.
enum LeoSettingsMachineRef: Hashable {
    case local
    case remote(UUID)

    /// The ref for `host` among `configurations`; nil for a remote that isn't there.
    init?(host: LeoHostID, configurations: [LeoHostConfiguration]) {
        switch host {
        case .local:
            self = .local
        case .remote(let name):
            guard let configuration = configurations.first(where: { $0.name == name }) else { return nil }
            self = .remote(configuration.id)
        }
    }
}

/// A pane under a machine in the sidebar, in display order.
enum LeoSettingsMachinePane: CaseIterable, Hashable {
    case templates, tasks, environments, delegation, appearance, defaults, daemon

    var tab: LeoSettingsTab {
        switch self {
        case .templates: LeoTemplatesSettingsView.tab
        case .tasks: LeoTasksSettingsView.tab
        case .environments: LeoEnvironmentsSettingsView.tab
        case .delegation: LeoDelegationSettingsView.tab
        case .appearance: LeoAppearanceSettingsView.tab
        case .defaults: LeoDefaultsSettingsView.tab
        case .daemon: LeoDaemonSettingsView.tab
        }
    }

    var title: String {
        switch self {
        case .templates: "Templates"
        case .tasks: "Tasks"
        case .environments: "Environments"
        case .delegation: "Delegation"
        case .appearance: "Appearance"
        case .defaults: "Defaults"
        case .daemon: "Daemon"
        }
    }

    var systemImage: String {
        switch self {
        case .templates: "doc.text"
        case .tasks: "clock"
        case .environments: "leaf"
        case .delegation: "arrow.triangle.branch"
        case .appearance: "paintpalette"
        case .defaults: "slider.horizontal.3"
        case .daemon: "gearshape.2"
        }
    }
}

/// One row of the Settings sidebar: an app-wide page, a machine's overview,
/// or one of a machine's panes.
enum LeoSettingsSidebarItem: Hashable {
    case general
    case plugins
    case machine(LeoSettingsMachineRef)
    case pane(LeoSettingsMachineRef, LeoSettingsMachinePane)

    /// The machine this item belongs to; nil for the app-wide pages.
    var machine: LeoSettingsMachineRef? {
        switch self {
        case .general, .plugins: nil
        case .machine(let ref), .pane(let ref, _): ref
        }
    }

    /// What a selection means to the target model: which machine to edit and
    /// which tab to show. The host is nil for items that carry no machine and
    /// for a remote that exists only in the unsaved draft (there is nothing to
    /// connect to yet).
    struct Resolution: Equatable {
        let item: LeoSettingsSidebarItem
        let host: LeoHostID?
        let tab: LeoSettingsTab
    }

    /// `configurations` are the saved machines and `draft` the Machines model's
    /// unsaved list. A remote in neither is gone and falls back to This Mac.
    static func resolve(
        _ item: LeoSettingsSidebarItem, configurations: [LeoHostConfiguration], draft: [LeoHostConfiguration] = []
    ) -> Resolution {
        guard let ref = item.machine else {
            return Resolution(item: item, host: nil, tab: item == .general ? .general : .plugins)
        }
        let tab: LeoSettingsTab
        if case .pane(_, let pane) = item { tab = pane.tab } else { tab = .overview }
        switch ref {
        case .local:
            return Resolution(item: item, host: .local, tab: tab)
        case .remote(let id):
            if let saved = configurations.first(where: { $0.id == id }) {
                return Resolution(item: item, host: .remote(saved.name), tab: tab)
            }
            if draft.contains(where: { $0.id == id }) {
                return Resolution(item: item, host: nil, tab: tab)
            }
            return Resolution(item: .machine(.local), host: .local, tab: .overview)
        }
    }

    /// Whether a machine's panes can be opened: only one that is on and
    /// hasn't failed. Its overview opens regardless.
    static func panesEnabled(status: LeoMachineStatus?) -> Bool {
        switch status {
        case .connected?, .connecting?: true
        case .disabled?, .failed?, nil: false
        }
    }
}

/// How Settings was asked to open: the entry points.
enum LeoSettingsEntry: Equatable {
    /// App menu ▸ Settings…
    case settings
    /// Agents ▸ Machines… (no host), or a remote header's Edit Machine….
    case machines(LeoHostID?)
    /// An agent row's or the appearance popover's Edit Appearance Rules….
    case appearance(LeoHostID)
    /// A `leo://plugin/install` link: Settings ▸ Plugins.
    case plugins

    /// The item to land on. `remembered` is the last item shown; a machine
    /// that is gone falls back to This Mac.
    func item(remembered: LeoSettingsSidebarItem?, configurations: [LeoHostConfiguration]) -> LeoSettingsSidebarItem {
        let fallback = LeoSettingsSidebarItem.machine(.local)
        func ref(_ host: LeoHostID) -> LeoSettingsMachineRef {
            LeoSettingsMachineRef(host: host, configurations: configurations) ?? .local
        }
        switch self {
        case .settings:
            return remembered.map { LeoSettingsSidebarItem.resolve($0, configurations: configurations).item } ?? fallback
        case .machines(let host?):
            return .machine(ref(host))
        case .machines(nil):
            guard let remembered, let machine = remembered.machine else { return fallback }
            return .machine(LeoSettingsSidebarItem.resolve(.machine(machine), configurations: configurations).item.machine ?? .local)
        case .appearance(let host):
            return .pane(ref(host), .appearance)
        case .plugins:
            return .plugins
        }
    }
}
