import AppKit
import LeoKit
import OSLog

/// The harmless action effects (open a link, copy), and how a failed or
/// refused action reaches the person: a logged warning and a sheet on the key window.
@MainActor final class LeoPluginAppEffects: LeoPluginActionEffects {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo", category: "plugins")

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func report(plugin: LeoPluginIdentity, message: String) {
        Self.logger.warning("[\(plugin.id, privacy: .public)] \(message, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = plugin.name
        alert.informativeText = message
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
