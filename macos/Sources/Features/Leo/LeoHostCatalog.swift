import Foundation

/// Lists the configured leo hosts by running `leo host list --json` and
/// decoding `[LeoHost]`. The synthesized `localhost` entry is always present;
/// the rest are SSH-reachable remotes from `client.hosts` in `leo.yaml`.
///
/// The CLI runner is injected so tests can supply canned stdout without
/// spawning a real process. The default runner invokes the real `leo` binary.
struct LeoHostCatalog: Sendable {
    /// Runs the given `leo` argument list and returns stdout, or throws a
    /// `LeoError` on launch failure / non-zero exit.
    typealias Runner = @Sendable (_ args: [String]) async throws(LeoError) -> Data

    private let runner: Runner

    init(leoExecutable: String = NSString(string: "~/.local/bin/leo").expandingTildeInPath) {
        self.runner = { args throws(LeoError) in
            try LeoHostCatalog.runCLI(executable: leoExecutable, args: args)
        }
    }

    /// Test seam: inject a runner that returns canned stdout `Data`.
    init(runner: @escaping Runner) {
        self.runner = runner
    }

    /// Fetch the configured hosts via `leo host list --json`.
    func listHosts() async throws(LeoError) -> [LeoHost] {
        let data = try await runner(["host", "list", "--json"])
        do {
            return try JSONDecoder().decode([LeoHost].self, from: data)
        } catch {
            throw LeoError.decode(detail: "host list: \(error)")
        }
    }

    /// Production runner: run the `leo` CLI and return stdout. Mirrors
    /// `LeoSocketClient.runCLI`'s `Process` conventions.
    private static func runCLI(executable: String, args: [String]) throws(LeoError) -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            throw LeoError.daemonUnreachable
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw LeoError.daemon(message: "leo \(args.joined(separator: " ")) exited \(proc.terminationStatus)")
        }
        return data
    }
}
