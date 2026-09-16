import GhosttyKit

enum LeoCommandLauncher {
    static func startDaemonCommand(executablePath: String) throws -> String {
        try "\(leoShellQuote(executablePath)) service start"
    }

    static func configuration(command: String) -> Ghostty.SurfaceConfiguration {
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = command
        return configuration
    }

    static func didOpenTab(_ launch: () -> TerminalController?) -> Bool {
        launch() != nil
    }

    @MainActor static func openTab(in controller: TerminalController, command: String) -> Bool {
        didOpenTab {
            TerminalController.newTab(
            controller.ghostty,
            from: controller.window,
            withBaseConfig: configuration(command: command)
            )
        }
    }
}
