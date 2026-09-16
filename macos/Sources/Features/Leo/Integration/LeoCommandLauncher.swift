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

    @MainActor static func openTab(in controller: TerminalController, command: String) {
        _ = TerminalController.newTab(
            controller.ghostty,
            from: controller.window,
            withBaseConfig: configuration(command: command)
        )
    }
}
