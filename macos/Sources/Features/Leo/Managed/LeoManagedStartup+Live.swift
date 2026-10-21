import AppKit
import Foundation
import LeoKit

extension LeoManagedDependencies {
    static let labelInfoKey = "LeoDaemonLabel"

    /// The real seams, or nil when the bundle has no daemon label (a build
    /// that predates A4): such a bundle manages nothing.
    static func live(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard let label = bundle.object(forInfoDictionaryKey: labelInfoKey) as? String,
              !label.isEmpty, !label.contains("$("),
              let bundleID = bundle.bundleIdentifier else { return nil }
        let paths = LeoInstallPaths.live(bundle: bundle)
        let runner = LeoProcessRunner()
        let buildKind = LeoBuildKind.current
        return Self(
            paths: paths,
            fileSystem: LeoDiskFileSystem(),
            runner: runner,
            agent: LeoSMAppLaunchAgentService(
                label: label, isManagementEnabled: LeoFirstRun.isManagementEnabled(buildKind: buildKind, environment: environment)
            ),
            probe: LeoDaemonProbe(
                socketPath: paths.stateDirectory.appendingPathComponent("leo.sock").path, transport: LeoUnixSocketTransport()
            ),
            signaller: LeoPOSIXSignaller(),
            clock: LeoRealClock(),
            loginPath: { await LeoLoginPathProbe.live(runner: runner).loginPath() },
            makeToken: { UUID().uuidString },
            bundleID: bundleID,
            label: label,
            buildKind: buildKind,
            environment: environment
        )
    }
}

/// The managed flow's alerts. Styling is a TDD exception.
@MainActor final class LeoManagedAlerts: LeoManagedPresenting {
    func confirmReleaseToCLI() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Hand the daemon back to the CLI?"
        alert.informativeText = "Leo stops running the leo daemon and your command-line install takes over again. Your agents keep running."
        alert.addButton(withTitle: "Release to CLI")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmStopDaemon(pid: Int32) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop the leo daemon (pid \(pid))?"
        alert.informativeText = "It isn’t running under Leo, so Leo can’t restart or update it. It shuts down cleanly and your agents’ tmux sessions keep running; Leo then starts its own daemon."
        alert.addButton(withTitle: "Stop Daemon")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showMoveBackAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move Leo back to Applications"
        alert.informativeText = "Leo runs your daemon from /Applications/Leo.app. The daemon keeps running, but Leo can’t update or restart it until the app is back in Applications."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
