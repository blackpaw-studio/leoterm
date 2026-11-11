import Foundation

public struct LeoPluginCommandResult: Equatable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32

    public init(stdout: Data, stderr: Data, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

/// Runs a process. The Mac app adapts its `LeoProcessRunner`. `environment`
/// is the complete environment of the child: nothing is inherited.
public protocol LeoPluginCommandRunning: Sendable {
    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> LeoPluginCommandResult
}
