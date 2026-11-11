import Foundation
import Testing

@testable import LeoKit

/// Runs the real `/usr/bin/git` with exactly the environment the installer asks for.
private struct ProcessRunner: LeoPluginCommandRunning {
    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> LeoPluginCommandResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return LeoPluginCommandResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
        }.value
    }
}

private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A bare repo with one commit on `main` (a plugin) and an annotated tag `v1`.
private func makeRemote(in base: URL, symlinkedMain: Bool = false) throws -> (url: String, sha: String) {
    let work = base.appendingPathComponent("work")
    let bare = base.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: work.appendingPathComponent("dist"), withIntermediateDirectories: true)
    _ = try git(["init", "--quiet", "-b", "main"], in: work)
    try Data(#"{"id":"studio.blackpaw.real","name":"Real","version":"1.0.0","apiVersion":1,"main":"dist/main.js"}"#.utf8)
        .write(to: work.appendingPathComponent("leo-plugin.json"))
    if symlinkedMain {
        try FileManager.default.createSymbolicLink(
            atPath: work.appendingPathComponent("dist/main.js").path, withDestinationPath: "../../../../../../etc/hosts")
    } else {
        try Data("leo.on('activate',()=>{})".utf8).write(to: work.appendingPathComponent("dist/main.js"))
    }
    _ = try git(["add", "-A"], in: work)
    _ = try git(["commit", "--quiet", "-m", "init"], in: work)
    _ = try git(["tag", "-a", "v1", "-m", "v1"], in: work)
    let sha = try git(["rev-parse", "HEAD"], in: work)
    _ = try git(["clone", "--quiet", "--bare", work.path, bare.path], in: base)
    return ("file://" + bare.path, sha)
}

struct LeoPluginGitInstallerRealGitTests {
    private func installer(root: URL) -> LeoPluginGitInstaller {
        LeoPluginGitInstaller(root: root, runner: ProcessRunner(), allowedSchemes: ["file"], inheritedEnvironment: [:])
    }

    @Test func clonesATaggedCommitFromALocalBareRepo() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("leo-realgit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = try makeRemote(in: base)
        let root = base.appendingPathComponent("plugins")

        let installer = installer(root: root)
        let result = try await installer.install(url: remote.url, ref: "v1")

        #expect(result.sha == remote.sha)
        #expect(result.manifest.id == "studio.blackpaw.real")
        #expect(FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("dist/main.js").path))
        #expect(!FileManager.default.fileExists(atPath: result.directory.appendingPathComponent(".git").path))
        #expect(try await installer.resolve(url: remote.url, ref: "main") == remote.sha)
        #expect(try await installer.resolve(url: remote.url, ref: remote.sha) == remote.sha)
    }

    @Test func aRepoWhoseMainIsASymlinkOutOfTheCloneIsRefusedAndNothingIsLeftBehind() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("leo-realgit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = try makeRemote(in: base, symlinkedMain: true)
        let root = base.appendingPathComponent("plugins")

        await #expect(throws: LeoPluginInstallError.self) {
            try await installer(root: root).install(url: remote.url, ref: "main")
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path))?.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("studio.blackpaw.real").path))
    }

    @Test func refusesAFileUrlUnderTheDefaultHttpsOnlyPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leo-realgit-\(UUID().uuidString)")
        let strict = LeoPluginGitInstaller(root: root, runner: ProcessRunner(), inheritedEnvironment: [:])
        await #expect(throws: LeoPluginInstallError.self) {
            try await strict.install(url: "file:///tmp/whatever.git", ref: "main")
        }
    }
}
