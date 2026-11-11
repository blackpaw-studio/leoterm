import Foundation

public struct LeoPluginInstallResult: Equatable, Sendable {
    public let manifest: LeoPluginManifest
    public let sha: String
    public let url: String
    public let ref: String
    /// `<root>/<id>/<sha>/`, `.git` removed. Nothing in it is enabled yet.
    public let directory: URL
}

/// Installs a plugin from an https git URL pinned to a commit SHA. The clone is
/// untrusted input: no hooks, no submodules, no credential helpers, no prompts,
/// https only, and the commit, manifest and `main` are checked before anything
/// lands in `<root>/<id>/<sha>/`. Staging is removed on every failure.
public struct LeoPluginGitInstaller: Sendable {
    public static let maxMainBytes = 10 * 1024 * 1024
    public static let manifestFileName = "leo-plugin.json"
    static let fetchTimeout: TimeInterval = 120
    static let quickTimeout: TimeInterval = 30
    /// Only network settings survive into git's otherwise empty environment.
    static let inheritedVariables = [
        "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR",
    ]

    private let root: URL
    private let runner: any LeoPluginCommandRunning
    private let gitPath: String
    private let allowedSchemes: Set<String>
    private let inheritedEnvironment: [String: String]
    private let gitIsAvailable: @Sendable (String) -> Bool

    /// `allowedSchemes` is https in the app; tests with a local repo add `file`.
    public init(
        root: URL, runner: any LeoPluginCommandRunning, gitPath: String = "/usr/bin/git",
        allowedSchemes: Set<String> = ["https"],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        gitIsAvailable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.root = root
        self.runner = runner
        self.gitPath = gitPath
        self.allowedSchemes = allowedSchemes
        self.inheritedEnvironment = inheritedEnvironment
        self.gitIsAvailable = gitIsAvailable
    }

    // MARK: - Resolve

    /// The commit `ref` (a branch, tag, or 40-hex SHA; empty means HEAD) points at.
    public func resolve(url: String, ref: String) async throws -> String {
        let source = try Self.unwrap(LeoPluginGitSource.validatedURL(url, allowedSchemes: allowedSchemes))
        let name = try Self.unwrap(LeoPluginGitSource.validatedRef(ref))
        if let sha = LeoPluginGitSource.normalizedSHA(name) { return sha }
        // The second pattern lists an annotated tag's peeled commit, which a bare name doesn't match.
        let output = try await git(["ls-remote", "--", source.absoluteString, name, "\(name)^{}"], timeout: Self.quickTimeout)
        guard let sha = LeoPluginGitSource.resolve(ref: name, lsRemote: String(decoding: output, as: UTF8.self)) else {
            throw LeoPluginInstallError.refNotFound(name)
        }
        return sha
    }

    // MARK: - Install

    public func install(url: String, ref: String) async throws -> LeoPluginInstallResult {
        let source = try Self.unwrap(LeoPluginGitSource.validatedURL(url, allowedSchemes: allowedSchemes))
        let name = try Self.unwrap(LeoPluginGitSource.validatedRef(ref))
        let sha = try await resolve(url: url, ref: ref)

        let staging = root.appendingPathComponent(".staging").appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try await clone(url: source, sha: sha, into: staging)
            let manifest = try Self.validatedManifest(in: staging)
            try Self.checkMain(manifest.main, in: staging)
            let directory = try place(staging: staging, id: manifest.id, sha: sha)
            return LeoPluginInstallResult(manifest: manifest, sha: sha, url: source.absoluteString, ref: name, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Clone

    private func clone(url: URL, sha: String, into staging: URL) async throws {
        let dir = staging.path
        _ = try await git(["-C", dir, "init", "--quiet"], timeout: Self.quickTimeout)
        _ = try await git(
            ["-C", dir, "fetch", "--quiet", "--depth", "1", "--no-tags", "--no-recurse-submodules", "--", url.absoluteString, sha],
            timeout: Self.fetchTimeout)
        _ = try await git(["-C", dir, "checkout", "--quiet", "--detach", "--no-recurse-submodules", sha], timeout: Self.quickTimeout)
        let head = String(decoding: try await git(["-C", dir, "rev-parse", "HEAD"], timeout: Self.quickTimeout), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard head == sha else { throw LeoPluginInstallError.shaMismatch(expected: sha, actual: head) }
    }

    /// Runs git with the hardened configuration; returns stdout.
    /// `-C <dir>` goes first so it stays ahead of the subcommand.
    private func git(_ arguments: [String], timeout: TimeInterval) async throws -> Data {
        guard gitIsAvailable(gitPath) else { throw LeoPluginInstallError.gitUnavailable }
        var prefix: [String] = []
        if arguments.first == "-C" { prefix = Array(arguments.prefix(2)) }
        let command = Array(arguments.dropFirst(prefix.count))
        let result = try await runner.run(
            executable: gitPath, arguments: prefix + hardenedConfig + command, environment: environment, timeout: timeout)
        guard result.status == 0 else {
            let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("xcode-select") || detail.contains("developer tools") { throw LeoPluginInstallError.gitUnavailable }
            throw LeoPluginInstallError.gitFailed(command: command.first ?? "", detail: detail)
        }
        return result.stdout
    }

    private var hardenedConfig: [String] {
        let protocols = allowedSchemes.sorted().flatMap { ["-c", "protocol.\($0).allow=always"] }
        return ["-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never"] + protocols
            + ["-c", "credential.helper=", "-c", "submodule.recurse=false", "-c", "core.fsmonitor=false"]
    }

    private var environment: [String: String] {
        var env = inheritedEnvironment.filter { Self.inheritedVariables.contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = root.appendingPathComponent(".staging").path
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_ATTR_NOSYSTEM"] = "1"
        env["GIT_LFS_SKIP_SMUDGE"] = "1"
        return env
    }

    // MARK: - Validate

    private static func validatedManifest(in staging: URL) throws -> LeoPluginManifest {
        let file = staging.appendingPathComponent(manifestFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw LeoPluginInstallError.manifestMissing }
        let data: Data
        do {
            data = try readRegularFile(file, within: staging, maxBytes: LeoPluginManifestValidator.maxManifestBytes)
        } catch let reason as FileRefusal {
            throw LeoPluginInstallError.manifestRefused(reason.message)
        }
        switch LeoPluginManifestValidator.validate(data) {
        case .valid(let manifest): return manifest
        case .refused(let reason): throw LeoPluginInstallError.manifestRefused(reason)
        }
    }

    private static func checkMain(_ main: String, in staging: URL) throws {
        do {
            _ = try regularFile(staging.appendingPathComponent(main), within: staging, maxBytes: maxMainBytes)
        } catch let reason as FileRefusal {
            throw LeoPluginInstallError.mainUnusable(reason.message)
        }
    }

    private struct FileRefusal: Error { let message: String }

    /// Resolves symlinks, then requires a regular file strictly inside `folder`
    /// no larger than `maxBytes`.
    private static func regularFile(_ file: URL, within folder: URL, maxBytes: Int) throws -> URL {
        let resolved = file.resolvingSymlinksInPath()
        guard LeoPluginPathContainment.isContained(resolved: resolved, in: folder.resolvingSymlinksInPath()) else {
            throw FileRefusal(message: "it resolves outside the plugin folder")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { throw FileRefusal(message: "it is not a regular file") }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= maxBytes else { throw FileRefusal(message: "it is larger than \(maxBytes / 1024 / 1024) MB") }
        return resolved
    }

    private static func readRegularFile(_ file: URL, within folder: URL, maxBytes: Int) throws -> Data {
        let resolved = try regularFile(file, within: folder, maxBytes: maxBytes)
        guard let data = try? Data(contentsOf: resolved) else { throw FileRefusal(message: "it can't be read") }
        return data
    }

    // MARK: - Place

    /// Drops `.git` and moves the staged tree to `<root>/<id>/<sha>/`, replacing
    /// a previous copy of the same commit. `id` and `sha` are validated as
    /// lowercase DNS labels and hex, so neither can add path components.
    private func place(staging: URL, id: String, sha: String) throws -> URL {
        let fileManager = FileManager.default
        let idFolder = root.appendingPathComponent(id)
        let destination = idFolder.appendingPathComponent(sha)
        do {
            try? fileManager.removeItem(at: staging.appendingPathComponent(".git"))
            try fileManager.createDirectory(at: idFolder, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw LeoPluginInstallError.installFailed(error.localizedDescription)
        }
        return destination
    }

    private static func unwrap<T>(_ result: Result<T, LeoPluginInstallError>) throws -> T { try result.get() }
}
