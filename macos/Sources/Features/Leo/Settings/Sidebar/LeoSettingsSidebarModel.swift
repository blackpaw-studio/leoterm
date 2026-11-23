import Combine
import Foundation
import LeoKit

/// The Settings sidebar's state: which row is selected, which machines are
/// expanded, and the machine rows. The sidebar selection is the only machine
/// selector; every change goes through the target model, so one dirty check
/// guards it, and a refused change leaves the old selection until confirmed.
@MainActor final class LeoSettingsSidebarModel: ObservableObject {
    /// A machine row: This Mac, or a remote from the Machines draft.
    struct MachineRow: Identifiable, Equatable {
        let ref: LeoSettingsMachineRef
        let name: String
        let status: LeoMachineStatus?
        /// Turned off in settings: shown as "Off" instead of a status dot.
        let isOff: Bool
        /// Known to the app. A machine that exists only in the draft isn't:
        /// its panes would edit another machine until it is saved.
        let isSaved: Bool

        var id: LeoSettingsMachineRef { ref }

        /// Whether the machine's panes can be opened. The overview always can.
        var panesEnabled: Bool { !isOff && isSaved && LeoSettingsSidebarItem.panesEnabled(status: status) }

        var statusText: String {
            if isOff { return "Off" }
            switch status {
            case .connected?: return "Connected"
            case .connecting?: return "Connecting"
            case .failed?: return "Unreachable"
            case .disabled?: return "Off"
            case nil: return "Not connected"
            }
        }

        /// What VoiceOver reads: "name, status".
        var accessibilityLabel: String { "\(name), \(statusText)" }
    }

    @Published private(set) var selection: LeoSettingsSidebarItem
    @Published private(set) var expanded: Set<LeoSettingsMachineRef>

    private let model: LeoMachinesSettingsModel
    private let target: LeoSettingsTargetModel
    private let status: (LeoHostID) -> LeoMachineStatus?
    private let configurations: () -> [LeoHostConfiguration]
    /// A selection waiting on the user's answer to the target's question.
    private var pendingItem: LeoSettingsSidebarItem?
    /// The machine the selection was last on; an app page keeps it, so it can still be collapsed.
    private var lastMachine: LeoSettingsMachineRef?
    private var subscriptions: Set<AnyCancellable> = []

    /// `machinesChanged` fires after the registry's machine list changes (a
    /// save); `configurations` are the saved machines.
    init(
        model: LeoMachinesSettingsModel, target: LeoSettingsTargetModel, status: @escaping (LeoHostID) -> LeoMachineStatus?,
        configurations: @escaping () -> [LeoHostConfiguration], machinesChanged: AnyPublisher<Void, Never>,
        initial: LeoSettingsSidebarItem
    ) {
        self.model = model
        self.target = target
        self.status = status
        self.configurations = configurations
        selection = initial
        expanded = initial.machine.map { [$0] } ?? []
        lastMachine = initial.machine
        model.$hosts.dropFirst()
            .sink { [weak self] hosts in self?.resync(draft: hosts) }
            .store(in: &subscriptions)
        machinesChanged
            .sink { [weak self] in self?.resync(draft: self?.model.hosts ?? []) }
            .store(in: &subscriptions)
        model.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        target.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    // MARK: Rows

    /// This Mac, then the draft's remotes in order (so an unsaved machine shows).
    var rows: [MachineRow] {
        let saved = configurations()
        let local = MachineRow(ref: .local, name: "This Mac", status: status(.local), isOff: false, isSaved: true)
        let remotes = model.hosts.map { host in
            // The registry knows a machine by its saved name, not the draft's.
            let liveName = saved.first { $0.id == host.id }?.name
            return MachineRow(
                ref: .remote(host.id), name: host.name.isEmpty ? "Untitled" : host.name,
                status: host.isEnabled ? liveName.flatMap { status(.remote($0)) } : .disabled, isOff: !host.isEnabled,
                isSaved: liveName != nil
            )
        }
        return [local] + remotes
    }

    func isExpanded(_ ref: LeoSettingsMachineRef) -> Bool { expanded.contains(ref) }

    // MARK: Actions

    /// Selects `item`. It takes effect now when the target accepts the move,
    /// else once the user confirms the discard question (`confirm(_:)`).
    /// Returns whether `item` is now selected: false when the move is waiting
    /// on the discard question (or `item` can't be selected).
    @discardableResult
    func select(_ item: LeoSettingsSidebarItem) -> Bool {
        guard item != selection else { return true }
        guard canSelect(item) else { return false }
        let resolution = resolve(item, draft: model.hosts)
        guard target.requestSelection(host: resolution.host, tab: resolution.tab) else {
            pendingItem = resolution.item
            return false
        }
        commit(resolution.item)
        return true
    }

    /// Entry points (menus, the appearance popover): like `select`, but a pane
    /// whose machine can't open panes lands on that machine's overview.
    /// Returns whether the selection moved (or was already there).
    @discardableResult
    func open(_ item: LeoSettingsSidebarItem) -> Bool {
        select(canSelect(item) ? item : .machine(item.machine ?? .local))
    }

    /// A pane row is selectable only while its machine's panes are enabled:
    /// the list can still land on a disabled row, and an unsaved machine's
    /// panes would show and save another machine's config.
    private func canSelect(_ item: LeoSettingsSidebarItem) -> Bool {
        guard case .pane(let ref, _) = item else { return true }
        return rows.first { $0.ref == ref }?.panesEnabled ?? false
    }

    /// The disclosure chevron: expands or collapses a machine, never selects.
    func toggleDisclosure(_ ref: LeoSettingsMachineRef) {
        if expanded.contains(ref) { expanded.remove(ref) } else { expanded.insert(ref) }
    }

    /// The `+` in the Machines header: a new unsaved machine, selected.
    func addMachine() {
        model.addHost()
        guard let id = model.selectedID else { return }
        select(.machine(.remote(id)))
    }

    /// The discard question's content: the target's refused change and the
    /// row the sidebar will move to. nil while nothing is pending.
    struct PendingSelection: Equatable {
        let change: LeoSettingsTargetModel.PendingChange
        let item: LeoSettingsSidebarItem
    }

    var pendingSelection: PendingSelection? {
        guard let pendingItem, let change = target.pendingChange else { return nil }
        return PendingSelection(change: change, item: pendingItem)
    }

    /// The user chose Discard: the target applies its move, and the sidebar
    /// follows. Takes the pair the alert showed, since the alert's dismiss
    /// (`cancelPending`) has already cleared the model's own copy.
    func confirm(_ pending: PendingSelection) {
        target.confirmPendingChange(pending.change)
        commit(pending.item)
        pendingItem = nil
    }

    func cancelPending() {
        target.cancelPendingChange()
        pendingItem = nil
    }

    // MARK: Internals

    private func commit(_ item: LeoSettingsSidebarItem) {
        let previous = selection.machine
        selection = item
        if let machine = item.machine {
            if machine != previous { expanded.insert(machine) }
            // The machine shown last collapses, even across an app page (General, Plugins).
            if let lastMachine, lastMachine != machine { expanded.remove(lastMachine) }
            lastMachine = machine
        }
        if case .remote(let id)? = item.machine, model.selectedID != id { model.selectedID = id }
    }

    /// A machine removed from the draft is gone from the sidebar even while
    /// the saved list still has it, so only saved machines the draft still
    /// holds count as configured.
    private func resolve(_ item: LeoSettingsSidebarItem, draft: [LeoHostConfiguration]) -> LeoSettingsSidebarItem.Resolution {
        let kept = configurations().filter { saved in draft.contains { $0.id == saved.id } }
        return LeoSettingsSidebarItem.resolve(item, configurations: kept, draft: draft)
    }

    /// The machine list changed: a selected remote that is gone falls back to
    /// This Mac; one that was renamed is followed to its new name, which the
    /// target lost when the old name left the registry.
    private func resync(draft: [LeoHostConfiguration]) {
        let resolution = resolve(selection, draft: draft)
        if resolution.item != selection {
            pendingItem = nil
            _ = target.requestSelection(host: resolution.host, tab: resolution.tab)
            commit(resolution.item)
        } else if let host = resolution.host, host != target.selectedHost {
            _ = target.requestSelection(host: host, tab: resolution.tab)
        }
    }
}
