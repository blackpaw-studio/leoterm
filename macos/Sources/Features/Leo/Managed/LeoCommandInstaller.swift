import Foundation

/// Leo ▸ "Install ‘leo’ Command…": links `~/.local/bin/leo` at the stable
/// `~/.leo/app/bin/leo`. Never deletes anything: an existing file or foreign
/// symlink is moved to `leo.pre-leoapp` (after the user confirms) so Release
/// to CLI can put it back.
struct LeoCommandInstaller: Sendable {
    enum Plan: Equatable, Sendable {
        case create
        case alreadyInstalled
        case confirmReplace(backup: URL)
        case refuse(Refusal)
    }

    enum Refusal: Equatable, Sendable {
        case directory
        /// An earlier backup exists; moving another file onto it would lose that one.
        case backupExists
        /// `~/.leo/app/bin/leo` is absent, so the command would dangle.
        case helperLinkMissing
    }

    enum Outcome: Equatable, Sendable {
        case installed(pathHint: String?)
        case alreadyInstalled
        case declined
        case refused(Refusal)
    }

    static let directoryMode: mode_t = 0o755
    static let pathHint = "~/.local/bin is not on your PATH. Add it (for example, export PATH=\"$HOME/.local/bin:$PATH\" in ~/.zshrc) to run ‘leo’ in new shells."

    let paths: LeoInstallPaths
    let fileSystem: any LeoFileSystem

    func plan() -> Plan {
        let existing = fileSystem.kind(at: paths.localBinLeo)
        switch existing {
        case .directory:
            return .refuse(.directory)
        case .symlink(let target) where target == paths.selfLinkURL.path:
            return .alreadyInstalled
        default:
            break
        }
        guard fileSystem.kind(at: paths.selfLinkURL) != .absent else { return .refuse(.helperLinkMissing) }
        guard existing != .absent else { return .create }
        guard fileSystem.kind(at: paths.localBinLeoBackup) == .absent else { return .refuse(.backupExists) }
        return .confirmReplace(backup: paths.localBinLeoBackup)
    }

    /// `confirmReplace` is asked only when something already occupies the
    /// command path. `path` is the process `PATH`, for the hint.
    func install(confirmReplace: (_ backup: URL) async -> Bool, path: String?) async throws -> Outcome {
        let initial = plan()
        guard case let .confirmReplace(backup) = initial else {
            return try await apply(initial, path: path)
        }
        guard await confirmReplace(backup) else { return .declined }
        // The confirmation can stay open for a long time and overlap another
        // install; decide again on what is on disk now.
        return try await apply(plan(), path: path)
    }

    private func apply(_ plan: Plan, path: String?) async throws -> Outcome {
        switch plan {
        case .alreadyInstalled:
            return .alreadyInstalled
        case let .refuse(reason):
            return .refused(reason)
        case .create:
            try link()
        case let .confirmReplace(backup):
            try fileSystem.moveWithoutReplacing(from: paths.localBinLeo, to: backup)
            do {
                try link()
            } catch {
                try? fileSystem.moveWithoutReplacing(from: backup, to: paths.localBinLeo)
                throw error
            }
        }
        return .installed(pathHint: isOnPath(path) ? nil : Self.pathHint)
    }

    private func link() throws {
        if fileSystem.kind(at: paths.localBinDirectory) == .absent {
            try fileSystem.createDirectory(at: paths.localBinDirectory, mode: Self.directoryMode)
        }
        try fileSystem.symlink(at: paths.localBinLeo, to: paths.selfLinkURL.path)
    }

    private func isOnPath(_ path: String?) -> Bool {
        path?.split(separator: ":").contains { String($0) == paths.localBinDirectory.path } ?? false
    }
}
