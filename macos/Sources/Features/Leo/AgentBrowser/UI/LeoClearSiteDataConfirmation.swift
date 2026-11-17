import AppKit

/// The sheets behind the browser pane's Clear Site Data for This Agent… and
/// Open in Default Browser (B-409). Clearing can't be undone, so Cancel is
/// the default button.
@MainActor enum LeoClearSiteDataConfirmation {
    static let cancelTitle = "Cancel"
    static let clearTitle = "Clear Site Data"

    /// Names the agent, and its machine when it isn't this Mac: the same
    /// agent name on another machine has a store of its own.
    static func makeAlert(agent key: LeoAgentBrowserKey) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let machine = key.host == .local ? "" : " on \(key.host.displayName)"
        alert.messageText = "Clear site data for “\(key.agent)”\(machine)?"
        alert.informativeText = "Removes cookies, caches and website storage from this agent’s browser. "
            + "Other agents keep theirs. Open pages stay as they are until they reload."
        // The first button is the default (Return); Escape also picks Cancel.
        alert.addButton(withTitle: cancelTitle)
        let clear = alert.addButton(withTitle: clearTitle)
        clear.hasDestructiveAction = true
        return alert
    }

    /// True only when the user chose Clear Site Data. A sheet on `window`, or
    /// a modal alert when there is no window to hang it on.
    static func confirm(agent key: LeoAgentBrowserKey, in window: NSWindow?) async -> Bool {
        let alert = makeAlert(agent: key)
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }

    /// Why Open in Default Browser opened nothing: `reason` says which
    /// machine and port couldn't be reached.
    static func makeUnavailableAlert(reason: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Can’t open this page in your default browser"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        return alert
    }

    static func explain(_ reason: String, in window: NSWindow?) {
        let alert = makeUnavailableAlert(reason: reason)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
