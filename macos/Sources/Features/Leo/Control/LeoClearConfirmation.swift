import AppKit

/// The sheet that stands between Clear and the daemon (B-262): clearing
/// drops the agent's conversation, so Cancel is the default button.
@MainActor enum LeoClearConfirmation {
    static let cancelTitle = "Cancel"
    static let clearTitle = "Clear"

    static func makeAlert(agent: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear \(agent)’s conversation?"
        alert.informativeText = "This ends the current conversation and starts a fresh one. It can’t be undone."
        // The first button is the default (Return); Escape also picks Cancel.
        alert.addButton(withTitle: cancelTitle)
        let clear = alert.addButton(withTitle: clearTitle)
        clear.hasDestructiveAction = true
        return alert
    }

    /// True only when the user chose Clear. A sheet on `window`, or a modal
    /// alert when there is no window to hang it on.
    static func confirm(agent: String, in window: NSWindow?) async -> Bool {
        let alert = makeAlert(agent: agent)
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }
}
