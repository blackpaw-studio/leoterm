import Foundation

/// One process to run: `executable` with `arguments`, never through a
/// local shell.
struct LeoDispatchPaneFocusCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

enum LeoDispatchPaneFocusError: Error, Equatable, Sendable {
    case invalidPane
    case tmuxNotFound
    case hostNotConfigured(String)
    case failed(String)

    var message: String {
        switch self {
        case .invalidPane: "Couldn't show the dispatch: its pane id is not valid"
        case .tmuxNotFound: "Couldn't show the dispatch: tmux was not found"
        case .hostNotConfigured(let name): "Couldn't show the dispatch: host \(name) is not configured"
        case .failed(let detail): "Couldn't show the dispatch: \(detail)"
        }
    }

    /// The row error for any failure while focusing.
    static func message(for error: any Error) -> String {
        (error as? Self)?.message ?? "Couldn't show the dispatch: \(error.localizedDescription)"
    }
}

/// B-271: brings forward the window holding a dispatch viewer that the
/// daemon left in its caller's own tmux session (so it can't be attached
/// on its own). `select-window` makes that window current for every client
/// of the session, which is what showing it means; `select-pane` focuses
/// the viewer inside it.
enum LeoDispatchPaneFocus {
    /// Leo's tmux server socket name (leo `tmux.SocketName`).
    static let socketName = "leo"
    static let localTmuxCandidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// Runs on the remote host as `sh -c <script> leo-focus <pane>`. Fixed
    /// text: the daemon-supplied pane only ever arrives as `$1`. A
    /// non-interactive ssh shell's PATH often lacks Homebrew, so the usual
    /// places are tried first.
    static let remoteScript = """
        for t in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do \
        if [ -x "$t" ]; then exec "$t" -L leo select-window -t "$1" ';' select-pane -t "$1"; fi; done; \
        if command -v tmux >/dev/null 2>&1; then exec tmux -L leo select-window -t "$1" ';' select-pane -t "$1"; fi; \
        echo "tmux was not found" >&2; exit 127
        """

    /// The first executable tmux among the usual places, then `path`.
    static func resolveLocalTmux(path: String?, isExecutable: (String) -> Bool) -> String? {
        let onPath = (path ?? "").split(separator: ":").map { "\($0)/tmux" }
        return (localTmuxCandidates + onPath).first(where: isExecutable)
    }

    /// The command for `pane` on `host`: local tmux, or tmux over ssh with
    /// the configured host's settings.
    static func command(
        host: LeoHostID, pane: String, hosts: [LeoHostConfiguration], sshExecutable: String,
        localTmux: () -> String? = { resolveLocalTmux(path: ProcessInfo.processInfo.environment["PATH"], isExecutable: FileManager.default.isExecutableFile) }
    ) throws -> LeoDispatchPaneFocusCommand {
        switch host {
        case .local:
            guard let tmux = localTmux() else { throw LeoDispatchPaneFocusError.tmuxNotFound }
            return try local(tmux: tmux, pane: pane)
        case .remote(let name):
            guard let configuration = hosts.first(where: { $0.name == name }) else {
                throw LeoDispatchPaneFocusError.hostNotConfigured(name)
            }
            return try remote(ssh: LeoSSHCommand(configuration: configuration), sshExecutable: sshExecutable, pane: pane)
        }
    }

    static func local(tmux: String, pane: String) throws -> LeoDispatchPaneFocusCommand {
        LeoDispatchPaneFocusCommand(executable: tmux, arguments: try tmuxArguments(pane: pane))
    }

    static func remote(ssh: LeoSSHCommand, sshExecutable: String, pane: String) throws -> LeoDispatchPaneFocusCommand {
        guard LeoDispatch.isPaneID(pane) else { throw LeoDispatchPaneFocusError.invalidPane }
        let arguments = try ssh.execArguments(remoteCommand: ["/bin/sh", "-c", remoteScript, "leo-focus", pane])
        return LeoDispatchPaneFocusCommand(executable: sshExecutable, arguments: arguments)
    }

    private static func tmuxArguments(pane: String) throws -> [String] {
        guard LeoDispatch.isPaneID(pane) else { throw LeoDispatchPaneFocusError.invalidPane }
        return ["-L", socketName, "select-window", "-t", pane, ";", "select-pane", "-t", pane]
    }
}

/// Runs a focus command; a non-zero exit throws with its last stderr line.
struct LeoDispatchPaneFocuser: Sendable {
    static let timeout: TimeInterval = 10

    let runner: any LeoProcessRunning

    func focus(_ command: LeoDispatchPaneFocusCommand) async throws {
        let result = try await runner.run(executable: command.executable, arguments: command.arguments, timeout: Self.timeout)
        guard result.status != 0 else { return }
        let lastLine = (String(bytes: result.stderr, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0.prefix(200)) }
        throw LeoDispatchPaneFocusError.failed(lastLine ?? "exit \(result.status)")
    }
}
