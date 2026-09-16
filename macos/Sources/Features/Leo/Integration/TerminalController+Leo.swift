import AppKit

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

    func validateLeoSidebarMenuItem(_ item: NSMenuItem) -> Bool {
        guard let leoSession else { item.state = .off; return false }
        item.state = leoSession.isSidebarVisible ? .on : .off
        return true
    }
}
