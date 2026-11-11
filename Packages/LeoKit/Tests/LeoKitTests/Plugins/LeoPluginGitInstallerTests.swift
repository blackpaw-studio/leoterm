import Foundation
import Testing

@testable import LeoKit

/// A scripted git: records every call and lets a test fake what the clone leaves on disk.
private final class FakeGit: LeoPluginCommandRunning, @unchecked Sendable {
    struct Call { let executable: String; let arguments: [String]; let environment: [String: String] }

    private let lock = NSLock()
    private var recorded: [Call] = []
    /// Called for each git subcommand; return nil to succeed with empty output.
    var handler: @Sendable (_ subcommand: String, _ arguments: [String]) throws -> LeoPluginCommandResult? = { _, _ in nil }

    var calls: [Call] { lock.withLock { recorded } }

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> LeoPluginCommandResult {
        lock.withLock { recorded.append(Call(executable: executable, arguments: arguments, environment: environment)) }
        let sub = Self.subcommand(arguments)
        return try handler(sub, arguments) ?? LeoPluginCommandResult(stdout: Data(), stderr: Data(), status: 0)
    }

    /// First argument that isn't a `-c k=v` or `-C dir` pair.
    static func subcommand(_ arguments: [String]) -> String {
        var index = 0
        while index < arguments.count, arguments[index] == "-c" || arguments[index] == "-C" { index += 2 }
        return index < arguments.count ? arguments[index] : ""
    }

    static func directory(_ arguments: [String]) -> URL? {
        arguments.firstIndex(of: "-C").map { URL(fileURLWithPath: arguments[$0 + 1]) }
    }
}

private let goodSHA = String(repeating: "a", count: 40)
private let manifestJSON = """
    {"id":"studio.blackpaw.demo","name":"Demo","version":"1.0.0","apiVersion":1,"main":"dist/main.js"}
    """

private func ok(_ text: String) -> LeoPluginCommandResult {
    LeoPluginCommandResult(stdout: Data(text.utf8), stderr: Data(), status: 0)
}

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("leo-installer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Makes the fake's `checkout` write a plugin tree into the staging dir.
private func populate(
    _ git: FakeGit, head: String = goodSHA, manifest: String = manifestJSON,
    files: @escaping @Sendable (URL) throws -> Void = { dir in
        let dist = dir.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try Data("leo.render('a',{})".utf8).write(to: dist.appendingPathComponent("main.js"))
    }
) {
    git.handler = { sub, args in
        switch sub {
        case "init", "fetch": return nil
        case "checkout":
            let dir = FakeGit.directory(args)!
            try Data(manifest.utf8).write(to: dir.appendingPathComponent("leo-plugin.json"))
            try files(dir)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
            return nil
        case "rev-parse": return ok(head + "\n")
        default: return nil
        }
    }
}

private func makeInstaller(_ git: FakeGit, root: URL, gitExists: Bool = true) -> LeoPluginGitInstaller {
    LeoPluginGitInstaller(
        root: root, runner: git, gitPath: "/usr/bin/git", inheritedEnvironment: [:],
        gitIsAvailable: { _ in gitExists })
}

struct LeoPluginGitInstallerTests {
    @Test func installsAPinnedShaAndMovesItIntoPlace() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        populate(git)

        let result = try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)

        #expect(result.manifest.id == "studio.blackpaw.demo")
        #expect(result.sha == goodSHA)
        let dest = root.appendingPathComponent("studio.blackpaw.demo/\(goodSHA)")
        #expect(result.directory.standardizedFileURL == dest.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("dist/main.js").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path))
        let staging = root.appendingPathComponent(".staging")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: staging.path))?.isEmpty ?? true)
    }

    @Test func everyGitCallIsLockedDownToHttpsWithNoHooksOrPrompts() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        populate(git)
        _ = try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)

        let subs = git.calls.map { FakeGit.subcommand($0.arguments) }
        #expect(subs == ["init", "fetch", "checkout", "rev-parse"])
        for call in git.calls {
            #expect(call.executable == "/usr/bin/git")
            #expect(call.arguments.contains("core.hooksPath=/dev/null"))
            #expect(call.arguments.contains("protocol.allow=never"))
            #expect(call.arguments.contains("protocol.https.allow=always"))
            #expect(call.arguments.contains("credential.helper="))
            #expect(!call.arguments.contains("protocol.file.allow=always"))
            #expect(call.environment["GIT_TERMINAL_PROMPT"] == "0")
            #expect(call.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        }
        let fetch = try #require(git.calls.first { FakeGit.subcommand($0.arguments) == "fetch" }).arguments
        #expect(fetch.contains("--depth"))
        #expect(fetch.contains("--no-recurse-submodules"))
        // The URL and sha come after `--` so neither can be read as an option.
        let dashes = try #require(fetch.firstIndex(of: "--"))
        #expect(Array(fetch[(dashes + 1)...]) == ["https://github.com/x/demo", goodSHA])
    }

    @Test func proxyVariablesAreInheritedButNothingElse() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        populate(git)
        let installer = LeoPluginGitInstaller(
            root: root, runner: git, gitPath: "/usr/bin/git",
            inheritedEnvironment: ["HTTPS_PROXY": "http://p:1", "GIT_DIR": "/evil", "GIT_SSH_COMMAND": "x"],
            gitIsAvailable: { _ in true })
        _ = try await installer.install(url: "https://github.com/x/demo", ref: goodSHA)
        let env = try #require(git.calls.first).environment
        #expect(env["HTTPS_PROXY"] == "http://p:1")
        #expect(env["GIT_DIR"] == nil)
        #expect(env["GIT_SSH_COMMAND"] == nil)
    }

    @Test(arguments: [
        "http://github.com/x/demo", "ssh://git@github.com/x/demo", "git@github.com:x/demo.git", "file:///tmp/repo",
        "/tmp/repo", "--upload-pack=touch /tmp/pwn", "https://user:pw@github.com/x/demo", "https://", "ext::sh -c id",
        "https://github.com/x y",
    ])
    func refusesAnythingButPlainHttps(url: String) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        await #expect(throws: LeoPluginInstallError.self) {
            try await makeInstaller(git, root: root).install(url: url, ref: goodSHA)
        }
        #expect(git.calls.isEmpty)
    }

    @Test(arguments: ["--upload-pack=x", "-x", "a b", "a..b", "ref;rm", "a\nb"])
    func refusesUnsafeRefs(ref: String) async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        await #expect(throws: LeoPluginInstallError.invalidRef(ref)) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: ref)
        }
        #expect(git.calls.isEmpty)
    }

    @Test func resolvesATagToItsPeeledCommitWithLsRemote() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tagObject = String(repeating: "b", count: 40)
        let git = FakeGit()
        git.handler = { sub, _ in
            sub == "ls-remote" ? ok("\(tagObject)\trefs/tags/v1\n\(goodSHA)\trefs/tags/v1^{}\n") : nil
        }
        let sha = try await makeInstaller(git, root: root).resolve(url: "https://github.com/x/demo", ref: "v1")
        #expect(sha == goodSHA)
        let args = try #require(git.calls.first).arguments
        #expect(args.contains("ls-remote"))
        #expect(Array(args[(args.firstIndex(of: "--")! + 1)...]) == ["https://github.com/x/demo", "v1", "v1^{}"])
    }

    @Test func reportsAnUnknownRef() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        await #expect(throws: LeoPluginInstallError.refNotFound("nope")) {
            try await makeInstaller(git, root: root).resolve(url: "https://github.com/x/demo", ref: "nope")
        }
    }

    @Test func aFortyHexRefIsUsedAsIsWithoutLsRemote() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        let sha = try await makeInstaller(git, root: root).resolve(
            url: "https://github.com/x/demo", ref: goodSHA.uppercased())
        #expect(sha == goodSHA)
        #expect(git.calls.isEmpty)
    }

    @Test func aHeadThatIsNotTheRequestedShaIsRefusedAndStagingIsCleaned() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        populate(git, head: String(repeating: "c", count: 40))
        await #expect(throws: LeoPluginInstallError.shaMismatch(expected: goodSHA, actual: String(repeating: "c", count: 40))) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path))?.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("studio.blackpaw.demo").path))
    }

    @Test func aSymlinkedMainThatEscapesTheFolderIsRefused() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("secret.txt")
        try Data("top secret".utf8).write(to: outside)
        let git = FakeGit()
        populate(git) { dir in
            let dist = dir.appendingPathComponent("dist")
            try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: dist.appendingPathComponent("main.js"), withDestinationURL: outside)
        }
        await #expect(throws: LeoPluginInstallError.self) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path))?.isEmpty ?? true)
    }

    @Test func aSymlinkedDirectoryComponentThatEscapesIsRefused() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideDir = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outsideDir.appendingPathComponent("main.js"))
        let git = FakeGit()
        populate(git) { dir in
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("dist"), withDestinationURL: outsideDir)
        }
        await #expect(throws: LeoPluginInstallError.self) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
    }

    @Test func aSymlinkedManifestIsRefused() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("elsewhere.json")
        try Data(manifestJSON.utf8).write(to: outside)
        let git = FakeGit()
        git.handler = { sub, args in
            switch sub {
            case "checkout":
                let dir = FakeGit.directory(args)!
                try FileManager.default.createSymbolicLink(
                    at: dir.appendingPathComponent("leo-plugin.json"), withDestinationURL: outside)
                return nil
            case "rev-parse": return ok(goodSHA)
            default: return nil
            }
        }
        await #expect(throws: LeoPluginInstallError.self) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
    }

    @Test func aMainOverTenMegabytesIsRefused() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        populate(git) { dir in
            let dist = dir.appendingPathComponent("dist")
            try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
            let handle = try {
                FileManager.default.createFile(atPath: dist.appendingPathComponent("main.js").path, contents: nil)
                return try FileHandle(forWritingTo: dist.appendingPathComponent("main.js"))
            }()
            // Sparse: set the size without writing 10 MB.
            try handle.truncate(atOffset: UInt64(LeoPluginGitInstaller.maxMainBytes + 1))
            try handle.close()
        }
        await #expect(throws: LeoPluginInstallError.self) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
    }

    @Test func aMissingMainIsRefused() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        populate(git) { _ in }
        await #expect(throws: LeoPluginInstallError.self) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
    }

    @Test func aRefusedManifestSurfacesItsReasonAndCleansUp() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        populate(git, manifest: #"{"id":"x"}"#)
        do {
            _ = try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
            Issue.record("expected a refusal")
        } catch LeoPluginInstallError.manifestRefused {
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path))?.isEmpty ?? true)
    }

    @Test func aFailingGitCommandCleansUpStaging() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        git.handler = { sub, _ in
            sub == "fetch" ? LeoPluginCommandResult(stdout: Data(), stderr: Data("fatal: repository not found".utf8), status: 128) : nil
        }
        await #expect(throws: LeoPluginInstallError.gitFailed(command: "fetch", detail: "fatal: repository not found")) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path))?.isEmpty ?? true)
    }

    @Test func aMissingGitBinaryIsAClearError() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        await #expect(throws: LeoPluginInstallError.gitUnavailable) {
            try await makeInstaller(git, root: root, gitExists: false).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
        #expect(git.calls.isEmpty)
    }

    @Test func theCommandLineToolsStubCountsAsMissingGit() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        git.handler = { _, _ in
            LeoPluginCommandResult(
                stdout: Data(), stderr: Data("xcode-select: note: No developer tools were found".utf8), status: 1)
        }
        await #expect(throws: LeoPluginInstallError.gitUnavailable) {
            try await makeInstaller(git, root: root).install(url: "https://github.com/x/demo", ref: goodSHA)
        }
    }

    @Test func reinstallingTheSameShaReplacesTheFolder() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit()
        populate(git)
        let installer = makeInstaller(git, root: root)
        _ = try await installer.install(url: "https://github.com/x/demo", ref: goodSHA)
        let result = try await installer.install(url: "https://github.com/x/demo", ref: goodSHA)
        #expect(FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("dist/main.js").path))
    }
}
