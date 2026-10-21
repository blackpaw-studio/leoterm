import Foundation

/// Copies a tmux binary to `~/.leo/app/tmux/<version>/tmux`, where `<version>`
/// is exactly its `tmux -V` minus the `tmux ` prefix (contract C8). A version
/// dir a `-L leo` server could be using is never overwritten or deleted.
struct LeoTmuxInstaller: Sendable {
    let paths: LeoInstallPaths
    let fileSystem: any LeoFileSystem
    let runner: any LeoProcessRunning
    let makeToken: @Sendable () -> String

    static let versionPrefix = "tmux "
    static let binaryMode: mode_t = 0o755
    static let directoryMode: mode_t = 0o755
    static let versionTimeout: TimeInterval = 10

    func installBundled() async throws -> URL {
        let version = try await version(of: paths.bundledTmux.path)
        return try install(paths.bundledTmux, version: version)
    }

    /// `binary -V` minus the prefix, refused when it can't name a directory.
    func version(of binary: String) async throws -> String {
        let result: LeoProcessResult
        do {
            result = try await runner.run(executable: binary, arguments: ["-V"], timeout: Self.versionTimeout)
        } catch {
            throw LeoTmuxInstallError.versionQueryFailed("\(error)")
        }
        guard result.status == 0 else {
            let stderr = (String(bytes: result.stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw LeoTmuxInstallError.versionQueryFailed(stderr.isEmpty ? "exit \(result.status)" : stderr)
        }
        let output = (String(bytes: result.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.hasPrefix(Self.versionPrefix) else { throw LeoTmuxInstallError.unusableVersion(output) }
        let version = String(output.dropFirst(Self.versionPrefix.count))
        guard paths.tmuxURL(version: version) != nil else { throw LeoTmuxInstallError.unusableVersion(output) }
        return version
    }

    /// Copies `source` into its version dir unless a binary is already there:
    /// temp file beside it, hash check, 0755, then a rename that never replaces.
    func install(_ source: URL, version: String) throws -> URL {
        guard let destination = paths.tmuxURL(version: version) else { throw LeoTmuxInstallError.unusableVersion(version) }
        guard fileSystem.kind(at: destination) == .absent else { return destination }
        let directory = destination.deletingLastPathComponent()
        if fileSystem.kind(at: directory) == .absent {
            try fileSystem.createDirectory(at: directory, mode: Self.directoryMode)
        }
        let temporary = LeoDiskFileSystem.temporaryURL(for: destination, token: makeToken())
        try fileSystem.copyFile(from: source, to: temporary)
        do {
            guard try fileSystem.sha256(of: temporary) == fileSystem.sha256(of: source) else {
                throw LeoTmuxInstallError.hashMismatch(path: destination.path)
            }
            try fileSystem.setMode(Self.binaryMode, at: temporary)
            try fileSystem.moveWithoutReplacing(from: temporary, to: destination)
        } catch {
            try? fileSystem.remove(temporary)
            // Another copy of this version landed first: use it.
            if (error as? LeoFileSystemError)?.code == EEXIST { return destination }
            throw error
        }
        return destination
    }
}

enum LeoTmuxInstallError: Error, Equatable, CustomStringConvertible {
    case versionQueryFailed(String)
    case unusableVersion(String)
    case hashMismatch(path: String)

    var description: String {
        switch self {
        case .versionQueryFailed(let detail): "tmux -V failed: \(detail)"
        case .unusableVersion(let output): "tmux -V printed an unusable version: \(output)"
        case .hashMismatch(let path): "The copy at \(path) doesn't match its source"
        }
    }
}
