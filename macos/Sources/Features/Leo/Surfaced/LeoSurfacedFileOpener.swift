import Foundation

/// Opens a surfaced file the user asked for (B-013; never on its own,
/// D-088). It first stats the file on its host (following symlinks, so the
/// target is what's checked) and goes ahead only for a regular file: a
/// directory, FIFO, device or socket -- which could hang the read -- gets
/// an error sheet instead. The open re-checks `isStillWanted` after the
/// stat (the agent may have restarted meanwhile), and its first read is
/// bounded (`LeoReadDeadline`); the editor's own read cap bounds its size.
/// The file is marked seen only once the pane shows it.
@MainActor final class LeoSurfacedFileOpener {
    /// One window's editor: how to stat and open on a host, and where
    /// errors go.
    struct Target {
        let stat: @MainActor (LeoEditorFileID) async throws -> LeoFileStat
        let open: @MainActor (LeoEditorFileID, Int?, @escaping @MainActor () -> Bool) async throws -> LeoEditorOpenOutcome
        let reportError: @MainActor (Error) -> Void
        /// Re-checked after the stat, and by the pane before it commits.
        var isStillWanted: @MainActor () -> Bool = { true }
    }

    private let markSeen: (LeoSurfacedFile, LeoHostID) -> Void

    init(markSeen: @escaping (LeoSurfacedFile, LeoHostID) -> Void) {
        self.markSeen = markSeen
    }

    func open(_ file: LeoSurfacedFile, host: LeoHostID, in target: Target) async {
        let fileID = LeoEditorFileID(host: host, path: file.absPath)
        do {
            let stat = try await target.stat(fileID)
            guard stat.kind == .file else {
                throw LeoFileAccessError.failed(path: file.absPath, reason: "it isn’t a regular file")
            }
            // The agent may have restarted while the stat was out.
            guard target.isStillWanted() else { return }
            // Re-checked again where the pane commits the document: the
            // open can wait in the pane's queue, and on its prompt.
            let outcome = try await target.open(fileID, file.line, target.isStillWanted)
            // Not seen when the user cancelled its unsaved-changes prompt,
            // or the agent restarted meanwhile.
            guard outcome != .cancelled else { return }
            markSeen(file, host)
        } catch {
            target.reportError(error)
        }
    }
}
