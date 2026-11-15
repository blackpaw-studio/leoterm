import AppKit
import LeoKit

/// Wires the menu bar extra to the app: the sidebar model's snapshot, server
/// mode, the daemon restarter and the window opener.
@MainActor final class LeoMenuBarCoordinator {
    /// The daemon's own log, rotated in-process (contract C4).
    static func logURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".leo/state/service.log")
    }

    /// The helper `Contents/Helpers/leo` in this bundle (D1).
    static func bundledExecutable(bundleURL: URL = Bundle.main.bundleURL) -> String {
        bundleURL.appendingPathComponent("Contents/Helpers/leo").path
    }

    private let model: LeoSidebarModel
    private let serverMode: LeoServerMode
    private let restarter: LeoDaemonRestarter
    private let defaults: UserDefaults
    private let windowID: () -> LeoWindowID?
    private let openLeo: () -> Void
    /// The managed daemon's state (B5): whether the app owns it, and the
    /// version its hello reported.
    private let managed: () -> (isManaged: Bool, isOutsideDaemon: Bool, version: String?)
    private let releaseToCLI: () -> Void
    /// The app restarted the daemon and the new one answers: reconnect to it.
    private let daemonChanged: () -> Void
    /// Restart Daemon found the app's job not loaded: B10's outside-daemon flow.
    private let restartFoundNoJob: () -> Void
    /// The menu's "Stop It…" for a daemon outside the app's job (B10).
    private let stopOutsideDaemon: () -> Void
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private var isRestarting = false
    /// Pairs through the same `leo` the restarter resolves.
    private lazy var pairPanel = LeoPairDevicePanelController(
        makeModel: { [restarter, daemonChanged] in
            LeoPairingModel(service: LeoPairingService(cli: restarter.cli), onDaemonRestarted: daemonChanged)
        }
    )
    private lazy var controller = LeoMenuBarController(
        inputs: { [unowned self] in menuInputs() },
        perform: { [unowned self] in perform($0) },
        attach: { [unowned self] in attach($0) }
    )

    init(
        model: LeoSidebarModel, serverMode: LeoServerMode, restarter: LeoDaemonRestarter, defaults: UserDefaults,
        windowID: @escaping () -> LeoWindowID?, openLeo: @escaping () -> Void,
        managed: @escaping () -> (isManaged: Bool, isOutsideDaemon: Bool, version: String?) = { (false, false, nil) },
        releaseToCLI: @escaping () -> Void = {},
        daemonChanged: @escaping () -> Void = {},
        restartFoundNoJob: @escaping () -> Void = {},
        stopOutsideDaemon: @escaping () -> Void = {},
        fileManager: FileManager = .default, workspace: NSWorkspace = .shared
    ) {
        self.model = model
        self.serverMode = serverMode
        self.restarter = restarter
        self.defaults = defaults
        self.windowID = windowID
        self.openLeo = openLeo
        self.managed = managed
        self.releaseToCLI = releaseToCLI
        self.daemonChanged = daemonChanged
        self.restartFoundNoJob = restartFoundNoJob
        self.stopOutsideDaemon = stopOutsideDaemon
        self.fileManager = fileManager
        self.workspace = workspace
    }

    /// Shows or hides the extra for the current preference and server mode.
    func syncVisibility() {
        controller.setVisible(LeoMenuBarModel.isVisible(
            preference: LeoMenuBarModel.preference(in: defaults), serverOnly: serverMode.isServerOnly
        ))
    }

    private func menuInputs() -> LeoMenuBarInputs {
        let managed = managed()
        return LeoMenuBarInputs(
            // Q5: the status item reports on This Mac's daemon only.
            snapshot: model.snapshot(for: .local) ?? LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 0),
            version: managed.version, isManaged: managed.isManaged, isOutsideDaemon: managed.isOutsideDaemon,
            serverOnly: serverMode.isServerOnly, isRestarting: isRestarting,
            hasLogFile: fileManager.fileExists(atPath: Self.logURL().path)
        )
    }

    private func perform(_ action: LeoMenuBarAction) {
        switch action {
        case .pairDevice: pairPanel.show()
        case .restartDaemon: restart()
        case .releaseToCLI: releaseToCLI()
        case .stopOutsideDaemon: stopOutsideDaemon()
        case .openLogs: workspace.open(Self.logURL())
        case .toggleServerOnly:
            serverMode.setServerOnly(!serverMode.isServerOnly)
            syncVisibility()
        case .openLeo: openLeo()
        case .quit: NSApp.terminate(nil)
        }
    }

    private func attach(_ id: LeoAgentRow.ID) {
        guard let row = model.snapshot(for: .local)?.rows.first(where: { $0.id == id }), let origin = windowID() else { return }
        model.attachRequested(row, origin, .content)
    }

    private func restart() {
        guard !isRestarting else { return }
        isRestarting = true
        Task { @MainActor in
            defer { isRestarting = false }
            switch await restarter.restart(isManaged: managed().isManaged) {
            case .restarted:
                daemonChanged()
            case .notRegistered:
                openLeo()
                restartFoundNoJob()
            case .failed(let message):
                showRestartFailure(message)
            }
        }
    }

    private func showRestartFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t restart the Leo daemon"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
