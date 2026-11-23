import AppKit
import OSLog

extension LeoPluginInstallLinkRouter {
    /// The app's router: opens Settings ▸ Plugins on `runtime` and reports a
    /// bad link in an alert.
    static func live(for runtime: LeoRuntime) -> LeoPluginInstallLinkRouter {
        LeoPluginInstallLinkRouter(
            openPluginsSettings: { [weak runtime] in runtime?.settingsWindow.show(.plugins) },
            showError: { reason in
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Can’t open plugin link"
                alert.informativeText = reason
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            },
            logger: Logger(subsystem: "studio.blackpaw.leo.macos", category: "plugin-links"))
    }
}
