import Foundation
import LeoKit

/// Adapts the app's `LeoProcessRunner` to the installer's runner. The child
/// gets exactly `environment` (`env -i`): `LeoProcessRunner` can't set one, and
/// git must not see the app's own variables (`GIT_DIR`, `GIT_SSH_COMMAND`, ...).
struct LeoPluginProcessRunner: LeoPluginCommandRunning {
    static let envPath = "/usr/bin/env"

    private let base: any LeoProcessRunning

    init(base: any LeoProcessRunning = LeoProcessRunner()) {
        self.base = base
    }

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> LeoPluginCommandResult {
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let result = try await base.run(
            executable: Self.envPath, arguments: ["-i"] + assignments + [executable] + arguments, timeout: timeout)
        return LeoPluginCommandResult(stdout: result.stdout, stderr: result.stderr, status: result.status)
    }
}
