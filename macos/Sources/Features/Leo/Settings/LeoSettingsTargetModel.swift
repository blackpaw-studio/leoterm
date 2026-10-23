import Combine
import Foundation
import LeoKit

/// A Settings tab. Machines edits the machine list; a config tab edits one
/// schema resource (`templates`, `tasks`, …) on the machine the toolbar picks.
enum LeoSettingsTab: Hashable {
    case machines
    case config(String)

    /// Whether the toolbar's machine picker applies to this tab.
    var usesMachineTarget: Bool {
        if case .config = self { return true }
        return false
    }
}

/// A config pane's unsaved state, as the Settings window needs it to ask
/// before a tab or machine switch, and before closing.
@MainActor protocol LeoSettingsPane: AnyObject {
    var hasUnsavedChanges: Bool { get }
    /// Drops the draft: the user chose to leave.
    func discardChanges()
    /// The same machine is back with a new client: fetch its document again
    /// and rebase the draft onto it (`LeoConfigDraft.rebased(onto:)`), keeping
    /// the user's edits. Never called after a switch to another machine.
    func reload(using client: any LeoConfigClient) async
}

/// Which machine the config panes edit and whether it can be edited now.
///
/// It defaults to the machine of the agent selected in the sidebar and can
/// point at any machine over its existing connection. Every refresh bumps
/// `generation`, which makes a reply from before it unwelcome. Only a switch
/// bumps `machineEpoch`, the identity a pane is mounted under: a reconnect to
/// the same machine keeps a dirty pane (and its edits) mounted and reloads it.
/// A machine whose daemon lacks the config API is `.tooOld`, never a
/// half-working form.
@MainActor final class LeoSettingsTargetModel: ObservableObject {
    enum Availability {
        /// Looking at what the machine can do.
        case loading
        case ready(any LeoConfigClient)
        /// No live connection; the status says why.
        case disconnected(LeoMachineStatus?)
        /// The daemon answered but doesn't serve the config API (or is too old to say).
        case tooOld(LeoDaemonVersionInfo?)
    }

    /// A switch waiting on the user's answer to "discard unsaved changes?".
    enum PendingChange: Equatable {
        case machine(LeoHostID)
        case tab(LeoSettingsTab)
    }

    @Published private(set) var selectedHost: LeoHostID
    @Published private(set) var availability: Availability = .loading
    /// Bumped on every refresh, to drop replies from before it.
    @Published private(set) var generation = 0
    /// Bumped only when the selected machine changes: panes are rebuilt then,
    /// never on a refresh of the same machine.
    @Published private(set) var machineEpoch = 0
    @Published private(set) var selectedTab: LeoSettingsTab = .machines
    @Published private(set) var pendingChange: PendingChange?
    /// The revisions the app's own writes superseded on the selected machine.
    let revisions = LeoConfigRevisionTracker()

    private struct WeakPane {
        weak var pane: (any LeoSettingsPane)?
    }

    private let clients: any LeoMachineClientResolving
    private let machineList: () -> [LeoHostID]
    private let status: (LeoHostID) -> LeoMachineStatus?
    private let reconnectHost: (LeoHostID) -> Void
    private var panes: [LeoSettingsTab: WeakPane] = [:]
    private var refreshTask: Task<Void, Never>?
    /// The selected machine's last ready client, kept while it is briefly gone
    /// so a dirty pane can stay mounted; cleared on a switch.
    private var lastClient: (any LeoConfigClient)?
    /// The selected machine's status when last looked at, so an unrelated
    /// publish (another machine, or the same status again) does nothing.
    private var lastStatus: LeoMachineStatus?
    private var subscriptions: Set<AnyCancellable> = []

    /// `initialHost` is the selected agent's machine, if there is one.
    init(
        clients: any LeoMachineClientResolving, machines: @escaping () -> [LeoHostID],
        status: @escaping (LeoHostID) -> LeoMachineStatus?, statuses: AnyPublisher<[LeoHostID: LeoMachineStatus], Never>,
        reconnect: @escaping (LeoHostID) -> Void, initialHost: LeoHostID?
    ) {
        self.clients = clients
        machineList = machines
        self.status = status
        reconnectHost = reconnect
        selectedHost = initialHost.flatMap { machines().contains($0) ? $0 : nil } ?? .local
        lastStatus = status(selectedHost)
        statuses
            .sink { [weak self] statuses in self?.receive(statuses) }
            .store(in: &subscriptions)
        clients.clientChanges
            .sink { [weak self] host in if host == self?.selectedHost { self?.refresh() } }
            .store(in: &subscriptions)
        refresh()
    }

    var machines: [LeoHostID] { machineList() }

    var isLoading: Bool {
        if case .loading = availability { return true }
        return false
    }

    /// Waits for the current look at the machine to finish.
    func settled() async {
        await refreshTask?.value
    }

    // MARK: Panes

    func register(_ pane: any LeoSettingsPane, for tab: LeoSettingsTab) {
        panes[tab] = WeakPane(pane: pane)
    }

    /// The pane mounted for `tab`, if it is still alive.
    func pane(for tab: LeoSettingsTab) -> (any LeoSettingsPane)? {
        panes[tab]?.pane
    }

    var hasUnsavedChanges: Bool {
        panes.values.contains { $0.pane?.hasUnsavedChanges == true }
    }

    /// The client a pane keeps editing against: the ready one, or, while the
    /// same machine reconnects, the last one if this tab's pane holds edits.
    /// Nil when the pane should give way to the status notice.
    func retainedClient(for tab: LeoSettingsTab) -> (any LeoConfigClient)? {
        switch availability {
        case .ready(let client): return client
        case .tooOld: return nil
        case .loading, .disconnected: break
        }
        guard panes[tab]?.pane?.hasUnsavedChanges == true else { return nil }
        return lastClient
    }

    func discardAllChanges() {
        panes.values.forEach { $0.pane?.discardChanges() }
    }

    // MARK: Switching

    /// Moves to `host` unless a pane has unsaved edits; then it asks
    /// (`pendingChange`) and returns false.
    @discardableResult func requestSwitch(to host: LeoHostID) -> Bool {
        guard host != selectedHost else { return true }
        guard !hasUnsavedChanges else {
            pendingChange = .machine(host)
            return false
        }
        switchNow(to: host)
        return true
    }

    /// Moves to `tab` unless the tab being left has unsaved edits.
    @discardableResult func requestTab(_ tab: LeoSettingsTab) -> Bool {
        guard tab != selectedTab else { return true }
        guard panes[selectedTab]?.pane?.hasUnsavedChanges != true else {
            pendingChange = .tab(tab)
            return false
        }
        selectedTab = tab
        return true
    }

    func confirmPendingChange() {
        guard let change = pendingChange else { return }
        pendingChange = nil
        switch change {
        case .machine(let host):
            discardAllChanges()
            switchNow(to: host)
        case .tab(let tab):
            panes[selectedTab]?.pane?.discardChanges()
            selectedTab = tab
        }
    }

    func cancelPendingChange() {
        pendingChange = nil
    }

    /// Asks the registry to reconnect the selected machine; its status change
    /// then brings the panes back.
    func reconnect() {
        reconnectHost(selectedHost)
    }

    /// Looks again at the selected machine: a window that is reopened, or a
    /// connection that came up.
    func refresh() {
        generation += 1
        let token = generation
        let host = selectedHost
        let isSameMachineAgain = lastClient != nil
        refreshTask?.cancel()
        refreshTask = nil
        guard let daemon = clients.daemon(for: host) else {
            availability = Self.isPending(status(host)) ? .loading : .disconnected(status(host))
            return
        }
        guard let config = daemon.configClient() else {
            availability = .tooOld(nil)
            return
        }
        availability = .loading
        refreshTask = Task { [weak self] in
            let info = try? await config.versionInfo()
            guard let self, !Task.isCancelled, generation == token else { return }
            guard let info, LeoConfigAPI.isSupported(by: info) else {
                availability = info.map { .tooOld($0) } ?? .disconnected(status(host))
                return
            }
            availability = .ready(config)
            lastClient = config
            guard isSameMachineAgain else { return }
            for pane in panes.values.compactMap(\.pane) { await pane.reload(using: config) }
        }
    }

    // MARK: Internals

    private func switchNow(to host: LeoHostID) {
        selectedHost = host
        machineEpoch += 1
        lastClient = nil
        lastStatus = status(host)
        revisions.reset()
        refresh()
    }

    private func receive(_ statuses: [LeoHostID: LeoMachineStatus]) {
        guard machineList().contains(selectedHost) else {
            pendingChange = nil
            discardAllChanges()
            switchNow(to: .local)
            return
        }
        let current = statuses[selectedHost]
        guard current != lastStatus else { return }
        lastStatus = current
        refresh()
    }

    /// A machine that is connecting, or connected but still building its
    /// client, has nothing to show yet; failure and absence do.
    private static func isPending(_ status: LeoMachineStatus?) -> Bool {
        switch status {
        case .connecting?, .connected?: true
        case .failed?, .disabled?, nil: false
        }
    }
}
