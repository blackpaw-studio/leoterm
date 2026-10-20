import Foundation
import LeoKit

/// Restarts the daemon from the menu bar (A11). Always `--graceful`: that
/// drains without prompting, which bare `restart` may do. A managed daemon
/// is restarted by the bundled binary by explicit path (D6) so the restart
/// targets the app's label; leo routes it from the marker.
struct LeoDaemonRestarter: Sendable {
    static let arguments = ["service", "restart", "--graceful"]
    /// The graceful drain waits up to 10 minutes before leo forces it.
    static let timeout: TimeInterval = 11 * 60

    let cli: LeoCLI
    let bundledExecutable: String

    func restart(isManaged: Bool) async throws {
        let executable = isManaged ? bundledExecutable : try cli.resolveExecutable()
        let result = try await cli.runner.run(executable: executable, arguments: Self.arguments, timeout: Self.timeout)
        guard result.status == 0 else {
            let message = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LeoDaemonError.transport(message.flatMap { $0.isEmpty ? nil : $0 } ?? "leo exited \(result.status)")
        }
    }
}
