import Combine
import Foundation
import LeoKit

/// What the model needs from the plugin manager. A protocol so tests drive it
/// without processes; `LeoPluginManager` conforms below.
@MainActor protocol LeoPluginsManaging: AnyObject {
    var plugins: [LeoPluginInfo] { get }
    var pluginsChanged: AnyPublisher<[LeoPluginInfo], Never> { get }
    func setEnabled(_ id: String, _ enabled: Bool) throws
    func approveCurrentPermissions(_ id: String) throws
    func setSection(_ id: String, section: String, hidden: Bool) throws
    func setPane(_ id: String, pane: String, hidden: Bool) throws
    func uninstall(_ id: String) throws
    func reload(restarting: Set<String>)
}

extension LeoPluginManager: LeoPluginsManaging {
    var pluginsChanged: AnyPublisher<[LeoPluginInfo], Never> { $plugins.eraseToAnyPublisher() }
}

/// The install flow's two steps, so the approval sheet can sit between them.
protocol LeoPluginInstalling: Sendable {
    func stage(url: String, ref: String) async throws -> LeoPluginPendingInstall
    func confirm(_ pending: LeoPluginPendingInstall) throws
    func cancel(_ pending: LeoPluginPendingInstall) throws
    func stageDev(folder: URL) throws -> LeoPluginPendingDev
    func confirmDev(_ pending: LeoPluginPendingDev) throws
}

extension LeoPluginInstallFlow: LeoPluginInstalling {}

protocol LeoPluginUpdating: Sendable {
    func check(id: String) async throws -> LeoPluginUpdateOutcome
    func approve(_ pending: LeoPluginPendingUpdate) throws
    func discard(_ pending: LeoPluginPendingUpdate)
}

extension LeoPluginUpdater: LeoPluginUpdating {}

/// The Settings ▸ Plugins pane. It is app-local, not per machine: nothing in it
/// reads or writes a daemon. Every path that adds or widens a plugin's
/// permissions goes through `approve` first, and applies exactly what that
/// sheet showed.
@MainActor final class LeoPluginsSettingsModel: ObservableObject {
    /// A line under the buttons: how the last action went.
    enum Message: Equatable {
        case notice(String)
        case failure(String)
    }

    @Published private(set) var rows: [LeoPluginRow] = []
    @Published private(set) var message: Message?
    /// An install, load or update check is in flight; the buttons wait.
    @Published private(set) var isBusy = false
    @Published private(set) var pendingUninstall: LeoPluginRow?
    @Published var isAskingInstallSource = false

    /// The built-in pane tabs' switches (the "Built-in" row above the plugins).
    let builtIn: LeoBuiltInPaneSettings
    private let manager: any LeoPluginsManaging
    private let installer: any LeoPluginInstalling
    private let updater: any LeoPluginUpdating
    /// Shows the approval sheet; true if the person approved.
    private let approve: @MainActor (LeoPluginApprovalRequest) async -> Bool
    private var subscription: AnyCancellable?
    private var builtInSubscription: AnyCancellable?

    init(
        manager: any LeoPluginsManaging, installer: any LeoPluginInstalling, updater: any LeoPluginUpdating,
        builtIn: LeoBuiltInPaneSettings,
        approve: @escaping @MainActor (LeoPluginApprovalRequest) async -> Bool
    ) {
        self.builtIn = builtIn
        self.manager = manager
        self.installer = installer
        self.updater = updater
        self.approve = approve
        rows = manager.plugins.map(LeoPluginRow.init)
        subscription = manager.pluginsChanged
            .dropFirst()
            .sink { [weak self] in self?.rows = $0.map(LeoPluginRow.init) }
        // The switches live in the shared settings object; the view redraws through this model.
        builtInSubscription = builtIn.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: Built-in

    /// Settings' "Show Terminal tab" switch (on by default).
    var showsTerminalTab: Bool { builtIn.showsTerminalTab }
    func setShowsTerminalTab(_ shown: Bool) { builtIn.setShowsTerminalTab(shown) }

    // MARK: Per-plugin

    func setEnabled(_ id: String, _ enabled: Bool) {
        attempt { try manager.setEnabled(id, enabled) }
    }

    /// A crash-disabled plugin back on: the manager clears the crash record and the supervisor's history.
    func reenable(_ id: String) {
        attempt { try manager.setEnabled(id, true) }
    }

    func showSection(_ id: String, section: String) {
        attempt { try manager.setSection(id, section: section, hidden: false) }
    }

    /// Settings' "Show agent pane" switch for a plugin's pane.
    func setPaneShown(_ id: String, pane: String, shown: Bool) {
        attempt { try manager.setPane(id, pane: pane, hidden: !shown) }
    }

    /// Opens the approval sheet for a plugin that asks for more than was
    /// approved. Approves only if it still asks for exactly what the sheet showed.
    func reviewApproval(_ id: String) async {
        guard !isBusy, let info = manager.plugins.first(where: { $0.id == id }),
            case .needsApproval(let shown) = info.state, let request = LeoPluginApprovalRequest(reviewing: info)
        else { return }
        await run {
            guard await approve(request) else { return }
            guard manager.plugins.first(where: { $0.id == id })?.state == .needsApproval(shown) else {
                message = .failure("“\(info.name)” changed while the sheet was open. Review it again.")
                return
            }
            attempt { try manager.approveCurrentPermissions(id) }
        }
    }

    // MARK: Uninstall

    func requestUninstall(_ id: String) {
        pendingUninstall = rows.first { $0.id == id && $0.canUninstall }
    }

    func cancelUninstall() { pendingUninstall = nil }

    func confirmUninstall() {
        guard let row = pendingUninstall else { return }
        pendingUninstall = nil
        attempt {
            try manager.uninstall(row.id)
            message = .notice("Removed “\(row.name)”.")
        }
    }

    // MARK: Install and update

    func install(url: String, ref: String) async {
        await run {
            let pending: LeoPluginPendingInstall
            do { pending = try await installer.stage(url: url, ref: ref) } catch { return fail(error) }
            guard await approve(pending.request) else {
                try? installer.cancel(pending)
                return
            }
            do {
                try installer.confirm(pending)
            } catch {
                try? installer.cancel(pending)
                return fail(error)
            }
            manager.reload(restarting: [pending.request.id])
            message = .notice("Installed “\(pending.request.name)”.")
        }
    }

    func loadLocalFolder(_ folder: URL) async {
        await run {
            let pending: LeoPluginPendingDev
            do { pending = try installer.stageDev(folder: folder) } catch { return fail(error) }
            guard await approve(pending.request) else { return }
            do { try installer.confirmDev(pending) } catch { return fail(error) }
            manager.reload(restarting: [pending.request.id])
            message = .notice("Loaded “\(pending.request.name)” from \(folder.lastPathComponent).")
        }
    }

    /// Checks every git-installed plugin. One that asks for nothing new is
    /// swapped in; one that asks for more waits behind the approval sheet.
    func checkForUpdates() async {
        await run {
            var updated: [String] = []
            var failures: [String] = []
            for row in rows where !row.isBundled && !row.isDev {
                do {
                    switch try await updater.check(id: row.id) {
                    case .upToDate: break
                    case .updated: updated.append(row.id)
                    case .needsApproval(let pending):
                        if await approve(pending.request) {
                            try updater.approve(pending)
                            updated.append(row.id)
                        } else {
                            updater.discard(pending)
                        }
                    }
                } catch {
                    failures.append("\(row.name): \(error.localizedDescription)")
                }
            }
            if !updated.isEmpty { manager.reload(restarting: Set(updated)) }
            if !failures.isEmpty {
                message = .failure(failures.joined(separator: "\n"))
            } else {
                message = .notice(updated.isEmpty ? "Everything is up to date." : "\(updated.count) plugin\(updated.count == 1 ? "" : "s") updated.")
            }
        }
    }

    // MARK: Private

    /// Runs one long action with the buttons held and the last message cleared.
    private func run(_ body: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        await body()
        isBusy = false
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        message = .failure(error.localizedDescription)
    }
}
