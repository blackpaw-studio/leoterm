import Foundation

/// Shared `Process` runner for the leo CLI fallbacks. Launches `executable`
/// with `args`, reads stdout to EOF, waits for exit, and maps failures to
/// `LeoError`. Callers that need to stay off a cooperative thread should hop
/// to a background queue themselves (see `LeoHostCatalog`).
enum LeoProcessRunner {
    /// Run `executable args…` and return stdout. Throws `LeoError.daemonUnreachable`
    /// if the process can't launch, or `LeoError.daemon` on a non-zero exit.
    static func run(executable: String, args: [String]) throws(LeoError) -> Data {
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
