import AppKit
import SwiftUI

enum LeoSidebarMenuState {
    static func state(isSidebarVisible: Bool) -> NSControl.StateValue {
        isSidebarVisible ? .on : .off
    }

    static func canCreateAgent(hasLeoSession: Bool) -> Bool { hasLeoSession }
}

extension TerminalController {
    @IBAction func toggleLeoSidebar(_ sender: Any?) {
        guard let leoSession else { return }
        leoSession.setSidebarVisible(!leoSession.isSidebarVisible)
    }

    @IBAction func startLeoDaemon(_ sender: Any?) {
        do {
            let path = try (NSApp.delegate as? AppDelegate)?.leoRuntime.resolveExecutablePath()
            guard let path else { return }
            let command = try LeoCommandLauncher.startDaemonCommand(executablePath: path)
            LeoCommandLauncher.openTab(in: self, command: command)
        } catch {
            NSSound.beep()
        }
    }

    @IBAction func newLeoAgent(_ sender: Any?) {
        guard leoSession != nil, let runtime = (NSApp.delegate as? AppDelegate)?.leoRuntime else { return }
        let sheet = NSHostingController(rootView: SpawnAgentSheet(model: runtime.model, actions: runtime.actions) { row, disposition in
            guard let id = self.leoSession?.id else { return }
            runtime.model.attachRequested(row, id, disposition)
        })
        window?.contentViewController?.presentAsSheet(sheet)
    }

    func validateLeoSidebarMenuItem(_ item: NSMenuItem) -> Bool {
        guard let leoSession else { item.state = .off; return false }
        item.state = LeoSidebarMenuState.state(isSidebarVisible: leoSession.isSidebarVisible)
        return true
    }

    func validateNewLeoAgentMenuItem(_ item: NSMenuItem) -> Bool {
        LeoSidebarMenuState.canCreateAgent(hasLeoSession: leoSession != nil)
    }
}
