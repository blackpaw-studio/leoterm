import Foundation
import Testing

/// B-220: Ghostty's shell integration (zsh, bash, fish, elvish, nushell) wraps
/// `ssh` as `"$GHOSTTY_BIN_DIR/ghostty" +ssh …`, and `src/termio/Exec.zig` sets
/// `GHOSTTY_BIN_DIR` to the running executable's directory. Leo's executable is
/// `Leo`, so the bundle must also answer to `Contents/MacOS/ghostty`, or every
/// `ssh` typed in a Leo terminal fails with "no such file or directory".
struct LeoBundledGhosttyCLITests {
    /// The name every upstream shell-integration script invokes.
    private static let cliName = "ghostty"

    /// What `Exec.zig` exports as `GHOSTTY_BIN_DIR` for this app.
    private static func binDir() throws -> URL {
        let executable = try #require(Bundle.main.executableURL)
        return executable.deletingLastPathComponent()
    }

    @Test func ghosttyCLIExistsBesideTheAppExecutable() throws {
        let cli = try Self.binDir().appendingPathComponent(Self.cliName).path
        #expect(FileManager.default.isExecutableFile(atPath: cli), "missing \(cli)")
    }

    @Test func ghosttyCLIIsTheAppExecutable() throws {
        let executable = try #require(Bundle.main.executableURL)
        let cli = try Self.binDir().appendingPathComponent(Self.cliName)
        #expect(cli.resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path)

        // A relative link survives moving or copying the bundle.
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: cli.path)
        #expect(target == executable.lastPathComponent)
    }

    /// The CLI action path runs before the single-instance check and the GUI,
    /// so invoking the wrapper's binary exits cleanly instead of opening Leo.
    @Test(.timeLimit(.minutes(1)))
    func ghosttyCLIRunsACLIActionAndExits() throws {
        let cli = try Self.binDir().appendingPathComponent(Self.cliName)
        let process = Process()
        process.executableURL = cli
        process.arguments = ["+version"]
        // A clean environment: the test host's XCTest injection variables
        // must not leak into the child.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(bytes: data, encoding: .utf8)?.contains("Build Config") == true)
    }
}
