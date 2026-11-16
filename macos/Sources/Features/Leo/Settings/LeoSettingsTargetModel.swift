import Combine
import Foundation
import LeoKit

/// A Settings page. General and Plugins are app-wide; the overview and the
/// config tabs edit one machine, the one the sidebar selection names.
enum LeoSettingsTab: Hashable {
    /// App-wide settings (stats style, agent browser, Terminal tab).
    case general
    /// A machine's overview page.
    case overview
    case config(String)
    /// Plugins live in this app, not on a machine, so the pane has no machine target.
    case plugins

    /// Whether the page edits the selected machine.
    var usesMachineTarget: Bool {
        switch self {
        case .overview, .config: true
        case .general, .plugins: false
        }
    }

    /// The Service content, whose model the target owns so a daemon restart can
    /// be waited out from any pane's prompt. It shows inside the Daemon pane.
    static let service = LeoSettingsTab.config("service")
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
    /// Whether the pane stays on screen, over a reconnecting banner, while its
    /// machine is gone. A pane with edits must; the default is just that.
    var staysMountedWhileReconnecting: Bool { get }
}

extension LeoSettingsPane {
    var staysMountedWhileReconnecting: Bool { hasUnsavedChanges }
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
        /// Move to a machine (nil keeps the current one) and a tab together.
        case selection(LeoHostID?, LeoSettingsTab)
    }

    @Published private(set) var selectedHost: LeoHostID
    @Published private(set) var availability: Availability = .loading
    /// Bumped on every refresh, to drop replies from before it.
    @Published private(set) var generation = 0
    /// Bumped only when the selected machine changes: panes are rebuilt then,
    /// never on a refresh of the same machine.
    @Published private(set) var machineEpoch = 0
    @Published private(set) var selectedTab: LeoSettingsTab = .overview
    @Published private(set) var pendingChange: PendingChange?
    /// The selected machine's daemon version, once its config API has
    /// answered (ready or too old); nil before that and after a switch.
    @Published private(set) var daemonVersion: String?
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
    private let makeService: @MainActor (any LeoConfigClient, String) -> LeoServiceSettingsModel
    /// The selected machine's Service model: held here, not by a view, because
    /// a restart started from another tab's prompt outlives that tab.
    private var serviceModel: LeoServiceSettingsModel?

    /// `initialHost` is the selected agent's machine, if there is one.
    init(
        clients: any LeoMachineClientResolving, machines: @escaping () -> [LeoHostID],
        status: @escaping (LeoHostID) -> LeoMachineStatus?, statuses: AnyPublisher<[LeoHostID: LeoMachineStatus], Never>,
        reconnect: @escaping (LeoHostID) -> Void, initialHost: LeoHostID?,
        makeService: @escaping @MainActor (any LeoConfigClient, String) -> LeoServiceSettingsModel = { LeoServiceSettingsModel(client: $0, machine: $1) }
    ) {
        self.clients = clients
        self.makeService = makeService
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
        guard panes[tab]?.pane?.staysMountedWhileReconnecting == true else { return nil }
        return lastClient
    }

    func discardAllChanges() {
        panes.values.forEach { $0.pane?.discardChanges() }
    }

    // MARK: Service

    /// The selected machine's Service model, made on first use and registered
    /// for the reconnect hook (it picks up the new client after a restart).
    func service(using client: any LeoConfigClient) -> LeoServiceSettingsModel {
        if let serviceModel { return serviceModel }
        let model = makeService(client, SpawnMachineOption.title(for: selectedHost))
        serviceModel = model
        register(model, for: .service)
        return model
    }

    /// What the restart prompts on every pane run: through the Service model,
    /// against the connected machine. Each answers why it failed, or nil.
    var restartActions: LeoConfigRestartActions {
        LeoConfigRestartActions(
            restartService: { [weak self] in await self?.runRestart { await $0.restartDaemon() } },
            restartAgents: { [weak self] in await self?.runRestart { await $0.restartAllAgents() } },
            runningAgents: { [weak self] in await self?.runningAgentCount() }
        )
    }

    /// The running-agent count, read fresh from the connected machine; nil
    /// when there is none or it can't be read.
    private func runningAgentCount() async -> Int? {
        guard case .ready(let client) = availability else { return nil }
        let model = service(using: client)
        await model.refreshStatus()
        return model.status?.runningAgentCount
    }

    private func runRestart(_ action: (LeoServiceSettingsModel) async -> String?) async -> String? {
        guard case .ready(let client) = availability else {
            return "Not connected to \(SpawnMachineOption.title(for: selectedHost))."
        }
        return await action(service(using: client))
    }

    // MARK: Switching

    /// Moves to `host` (keeping the tab) unless a pane has unsaved edits; then
    /// it asks (`pendingChange`) and returns false.
    @discardableResult func requestSwitch(to host: LeoHostID) -> Bool {
        requestSelection(host: host, tab: selectedTab)
    }

    /// Moves to `tab` unless the tab being left has unsaved edits.
    @discardableResult func requestTab(_ tab: LeoSettingsTab) -> Bool {
        requestSelection(host: nil, tab: tab)
    }

    /// Moves the machine and the tab together, so one dirty check and one
    /// question cover both. A nil `host` keeps the current machine. Leaving
    /// the machine asks if any pane is dirty; staying on it asks only if the
    /// tab being left is. Returns false while the question is pending.
    @discardableResult func requestSelection(host: LeoHostID?, tab: LeoSettingsTab) -> Bool {
        let newHost = host.flatMap { $0 == selectedHost ? nil : $0 }
        guard newHost != nil || tab != selectedTab else { return true }
        let isDirty = newHost != nil ? hasUnsavedChanges : panes[selectedTab]?.pane?.hasUnsavedChanges == true
        guard !isDirty else {
            pendingChange = .selection(host, tab)
            return false
        }
        apply(host: newHost, tab: tab)
        return true
    }

    func confirmPendingChange() {
        guard let change = pendingChange else { return }
        pendingChange = nil
        switch change {
        case .selection(let host, let tab):
            let newHost = host.flatMap { $0 == selectedHost ? nil : $0 }
            if newHost != nil {
                discardAllChanges()
            } else {
                panes[selectedTab]?.pane?.discardChanges()
            }
            apply(host: newHost, tab: tab)
        }
    }

    func cancelPendingChange() {
        pendingChange = nil
    }

    private func apply(host: LeoHostID?, tab: LeoSettingsTab) {
        if let host { switchNow(to: host) }
        selectedTab = tab
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
            daemonVersion = info?.version
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
        daemonVersion = nil
        serviceModel?.stop()
        serviceModel = nil
        panes[.service] = nil
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
