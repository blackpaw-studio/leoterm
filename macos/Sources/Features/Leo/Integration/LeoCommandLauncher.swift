import GhosttyKit

enum LeoCommandLauncher {
    static func startDaemonCommand(executablePath: String) throws -> String {
        try "\(leoShellQuote(executablePath)) service start"
    }

    static func sshHintCommand(target: String) throws -> String {
        try "ssh \(leoShellQuote(target))"
    }

    static func configuration(command: String) -> Ghostty.SurfaceConfiguration {
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = command
        return configuration
    }

    static func didOpen(_ launch: () -> TerminalController?) -> Bool {
        launch() != nil
    }

    /// A one-off command (start the daemon, `ssh`, an agent's logs) in a
    /// window of its own: there are no tabs (D-098), and the content area
    /// belongs to the sidebar's rows.
    @MainActor static func openWindow(in controller: TerminalController, command: String) -> Bool {
        didOpen {
            TerminalController.newWindow(
                controller.ghostty,
                withBaseConfig: configuration(command: command),
                withParent: controller.window
            )
        }
    }
}
