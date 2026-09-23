import AppKit

/// The editor's standard Mac sheets.
@MainActor enum LeoEditorAlerts {
    /// The standard "Do you want to save the changes…?" sheet: Save (default,
    /// Return), Cancel (Escape), Don't Save (⌘D).
    static func confirmUnsavedChanges(to name: String, on window: NSWindow) async -> LeoUnsavedChangesChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to “\(LeoSFTPServerText.sanitized(name))”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        switch await present(alert, on: window) {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Asks for a path to open. Relative paths resolve against `agent`'s
    /// workspace. nil when cancelled.
    static func askForPath(for agent: LeoEditorAgentContext, on window: NSWindow) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Open File in Editor"
        alert.informativeText = pathPromptDetail(for: agent)
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        field.placeholderString = agent.workspace == nil ? "/path/to/file" : "src/main.swift:12 or /path/to/file"
        field.lineBreakMode = .byTruncatingHead
        field.setAccessibilityLabel("Path")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard await present(alert, on: window) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// An editor is waiting on its disk or connection (a save or read that
    /// hasn't come back) and the user asked to close or quit again: Keep
    /// Waiting (default), or Close / Quit Anyway, losing its unsaved edits.
    static func offerToLeave(_ entry: LeoUnsavedEditorsGate.Entry, leaving: LeoUnsavedEditorsGate.Leaving) async -> Bool {
        entry.bringForward()
        let alert = NSAlert()
        alert.alertStyle = .warning
        let fileID = entry.editor.document?.fileID
        let name = fileID.map { LeoSFTPServerText.sanitized($0.name) } ?? "The file"
        alert.messageText = "“\(name)” is still being saved or read."
        let host = fileID?.host.displayName ?? "its disk"
        let verb = leaving == .quit ? "quit" : "close it"
        alert.informativeText = "Leo is waiting for \(host) to answer. If you \(verb) now, your unsaved changes to it will be lost."
        alert.addButton(withTitle: "Keep Waiting")
        let leave = alert.addButton(withTitle: leaving == .quit ? "Quit Anyway" : "Close Anyway")
        leave.hasDestructiveAction = true
        guard let window = NSApp.keyWindow else { return alert.runModal() == .alertSecondButtonReturn }
        return await present(alert, on: window) == .alertSecondButtonReturn
    }

    static func presentError(_ error: Error, on window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.localizedDescription
        alert.informativeText = (error as? LocalizedError)?.recoverySuggestion ?? ""
        alert.addButton(withTitle: "OK")
        guard let window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }

    private static func pathPromptDetail(for agent: LeoEditorAgentContext) -> String {
        guard let name = agent.name.map(LeoSFTPServerText.sanitized) else {
            return "Enter an absolute path on \(agent.host.displayName)."
        }
        guard let workspace = agent.workspace else {
            return "\(name) has no workspace, so enter an absolute path on \(agent.host.displayName)."
        }
        return "Relative paths open in \(name)’s workspace, \(LeoSFTPServerText.sanitized(workspace)), on \(agent.host.displayName)."
    }

    private static func present(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
