import AppKit
import OSLog

/// Backs Leo ▸ "Install ‘leo’ Command…": runs the installer and shows its
/// notices. Alert wiring only; the decisions and wording are
/// `LeoCommandInstaller`'s and `LeoCommandInstallerNotice`'s.
@MainActor final class LeoCommandInstallerController {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private let installer: LeoCommandInstaller
    /// The login shell's `PATH`; a GUI app's own never has `~/.local/bin`.
    private let loginPath: @Sendable () async -> String?
    private var isRunning = false

    init(
        installer: LeoCommandInstaller,
        loginPath: @escaping @Sendable () async -> String? = { await LeoLoginPathProbe.live(runner: LeoProcessRunner()).loginPath() }
    ) {
        self.installer = installer
        self.loginPath = loginPath
    }

    func install() {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            defer { isRunning = false }
            do {
                let outcome = try await installer.install(
                    confirmReplace: { @MainActor backup in Self.confirm(LeoCommandInstallerNotice.confirmReplace(backup: backup)) },
                    loginPath: loginPath
                )
                if let notice = LeoCommandInstallerNotice.notice(for: outcome) { Self.show(notice) }
            } catch {
                Self.logger.error("install ‘leo’ command failed: \(String(describing: error), privacy: .public)")
                Self.show(.failure(error))
            }
        }
    }

    private static func confirm(_ notice: LeoCommandInstallerNotice) -> Bool {
        let alert = makeAlert(notice)
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func show(_ notice: LeoCommandInstallerNotice) {
        let alert = makeAlert(notice)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func makeAlert(_ notice: LeoCommandInstallerNotice) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = notice.style == .warning ? .warning : .informational
        alert.messageText = notice.title
        alert.informativeText = notice.message
        return alert
    }
}
