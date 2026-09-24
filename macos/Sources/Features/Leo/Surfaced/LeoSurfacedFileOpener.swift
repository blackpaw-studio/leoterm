import Foundation
import OSLog

/// Who asked: the app on its own (a focused-tab arrival, focusing the tab,
/// clicking the row) or the user naming a file (a menu).
enum LeoSurfacedOpenMode: Equatable, Sendable { case automatic, manual }

/// Opens surfaced files in an editor pane (B-013). An automatic open first
/// stats the file on its host (following symlinks, so the target is what's
/// checked) and goes ahead only for a regular file under
/// `autoOpenLimit`: a directory, FIFO, device or socket -- which could hang
/// the read -- or a huge file only keeps its badge, quietly. It's marked
/// seen only once it passes. Each incarnation has at most one automatic
/// open in flight and one waiting; a newer arrival replaces the waiting
/// one, and the ones it replaced just stay badged. A manual open goes
/// straight to the editor, whose own checks and error sheet apply (the
/// file access refuses non-regular files and anything over its read cap).
@MainActor final class LeoSurfacedFileOpener {
    static let defaultAutoOpenLimit: UInt64 = LeoEditorContentPolicy.default.editableLimit
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// One window's editor: how to stat and open on a host, and where
    /// errors go.
    struct Target {
        let stat: @MainActor (LeoEditorFileID) async throws -> LeoFileStat
        let open: @MainActor (LeoEditorFileID, Int?) async throws -> Void
        let reportError: @MainActor (Error) -> Void
    }

    private struct Incarnation: Hashable {
        let host: LeoHostID
        let name: String
        let startedAt: String
    }

    private struct Request {
        let file: LeoSurfacedFile
        let host: LeoHostID
        let target: Target
    }

    private let autoOpenLimit: UInt64
    private let markSeen: (LeoSurfacedFile, LeoHostID) -> Void
    private var inFlight: Set<Incarnation> = []
    private var waiting: [Incarnation: Request] = [:]

    init(autoOpenLimit: UInt64 = LeoSurfacedFileOpener.defaultAutoOpenLimit, markSeen: @escaping (LeoSurfacedFile, LeoHostID) -> Void) {
        self.autoOpenLimit = autoOpenLimit
        self.markSeen = markSeen
    }

    func open(_ file: LeoSurfacedFile, host: LeoHostID, mode: LeoSurfacedOpenMode, in target: Target) async {
        let request = Request(file: file, host: host, target: target)
        guard mode == .automatic else {
            await openInEditor(request)
            return
        }
        let key = Incarnation(host: host, name: file.agent, startedAt: file.startedAt)
        guard !inFlight.contains(key) else {
            waiting[key] = request
            return
        }
        inFlight.insert(key)
        var next: Request? = request
        while let current = next {
            await openAutomatically(current)
            next = waiting.removeValue(forKey: key)
        }
        inFlight.remove(key)
    }

    private func openAutomatically(_ request: Request) async {
        let fileID = LeoEditorFileID(host: request.host, path: request.file.absPath)
        do {
            let stat = try await request.target.stat(fileID)
            guard stat.kind == .file, stat.size <= autoOpenLimit else {
                Self.logger.log("surfaced file \(request.file.id, privacy: .public) not auto-opened: not a regular file or too large")
                return
            }
        } catch {
            Self.logger.log("surfaced file \(request.file.id, privacy: .public) not auto-opened: \(error.localizedDescription, privacy: .public)")
            return
        }
        markSeen(request.file, request.host)
        await openInEditor(request)
    }

    private func openInEditor(_ request: Request) async {
        do {
            try await request.target.open(LeoEditorFileID(host: request.host, path: request.file.absPath), request.file.line)
        } catch {
            request.target.reportError(error)
        }
    }
}
