import Foundation

/// Keeps `~/.leo/app/bin/leo` pointing at the helper inside the current
/// bundle. That link is the marker's `self_path`: persisted unresolved in
/// plists and agent hooks, so it stays valid when the app updates or moves.
struct LeoSelfLink: Sendable {
    enum Outcome: Equatable, Sendable {
        case linked
        case alreadyCorrect
        case skipped(SkipReason)
    }

    enum SkipReason: Equatable, Sendable {
        case notInApplications
        case helperMissing
        /// A real file or directory sits at the link path; never replaced.
        case occupied
    }

    static let binDirectoryMode: mode_t = 0o755

    let paths: LeoInstallPaths
    let fileSystem: any LeoFileSystem

    // TODO(B5): call on every launch from LeoRuntime.start once the location decision exists.
    func refresh(isInApplications: Bool) throws -> Outcome {
        guard isInApplications else { return .skipped(.notInApplications) }
        guard fileSystem.kind(at: paths.bundledLeo) == .file else { return .skipped(.helperMissing) }

        let helper = paths.bundledLeo.path
        switch fileSystem.kind(at: paths.selfLinkURL) {
        case .symlink(let target) where target == helper:
            return .alreadyCorrect
        case .file, .directory:
            return .skipped(.occupied)
        case .absent:
            try ensureBinDirectory()
            fallthrough
        case .symlink:
            try fileSystem.replaceSymlinkAtomically(at: paths.selfLinkURL, to: helper)
            return .linked
        }
    }

    private func ensureBinDirectory() throws {
        guard fileSystem.kind(at: paths.binDirectory) == .absent else { return }
        try fileSystem.createDirectory(at: paths.binDirectory, mode: Self.binDirectoryMode)
    }
}
