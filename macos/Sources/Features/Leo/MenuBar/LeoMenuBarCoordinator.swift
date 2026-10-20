import AppKit
import LeoKit
import OSLog

/// Wires the menu bar extra to the app: the sidebar model's snapshot, server
/// mode, the daemon restarter and the window opener.
@MainActor final class LeoMenuBarCoordinator {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

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
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private var isRestarting = false
    private lazy var controller = LeoMenuBarController(
        inputs: { [unowned self] in menuInputs() },
        perform: { [unowned self] in perform($0) },
        attach: { [unowned self] in attach($0) }
    )

    init(
        model: LeoSidebarModel, serverMode: LeoServerMode, restarter: LeoDaemonRestarter, defaults: UserDefaults,
        windowID: @escaping () -> LeoWindowID?, openLeo: @escaping () -> Void,
        fileManager: FileManager = .default, workspace: NSWorkspace = .shared
    ) {
        self.model = model
        self.serverMode = serverMode
        self.restarter = restarter
        self.defaults = defaults
        self.windowID = windowID
        self.openLeo = openLeo
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
        LeoMenuBarInputs(
            snapshot: model.snapshot,
            // The hello version and the managed marker arrive with Phase B.
            version: nil, isManaged: false,
            serverOnly: serverMode.isServerOnly, isRestarting: isRestarting,
            hasLogFile: fileManager.fileExists(atPath: Self.logURL().path)
        )
    }

    private func perform(_ action: LeoMenuBarAction) {
        switch action {
        case .restartDaemon: restart()
        case .openLogs: workspace.open(Self.logURL())
        case .toggleServerOnly:
            serverMode.setServerOnly(!serverMode.isServerOnly)
            syncVisibility()
        case .openLeo: openLeo()
        case .quit: NSApp.terminate(nil)
        }
    }

    private func attach(_ id: LeoAgentRow.ID) {
        guard let row = model.snapshot.rows.first(where: { $0.id == id }), let origin = windowID() else { return }
        model.attachRequested(row, origin, .content)
    }

    private func restart() {
        guard !isRestarting else { return }
        isRestarting = true
        Task { @MainActor in
            defer { isRestarting = false }
            do {
                try await restarter.restart(isManaged: false)
            } catch {
                Self.logger.error("daemon restart failed: \(String(describing: error), privacy: .public)")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t restart the Leo daemon"
                alert.informativeText = Self.message(for: error)
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private static func message(for error: Error) -> String {
        if case LeoDaemonError.transport(let message) = error { return message }
        return error.localizedDescription
    }
}
