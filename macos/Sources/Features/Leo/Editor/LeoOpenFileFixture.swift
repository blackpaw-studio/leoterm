#if DEBUG
import Foundation
import OSLog

/// DEBUG builds only: opens the local file named by `LEO_OPEN_FILE` (an
/// absolute path) in the first window's editor pane once that window is up,
/// so GUI checks of the editor needn't get past the Open File panel. The
/// path is taken literally (no `:line:column`) and read on this Mac
/// whatever host is selected. Relative, empty or missing paths are logged
/// and ignored.
@MainActor final class LeoOpenFileFixture {
    static let environmentKey = "LEO_OPEN_FILE"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    /// Cleared once the first window has opened it.
    private var pending: String?

    init(path: String? = LeoOpenFileFixture.path()) {
        pending = path
    }

    nonisolated static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isFile: (String) -> Bool = LeoOpenFileFixture.isRegularFile
    ) -> String? {
        guard let path = environment[environmentKey] else { return nil }
        guard path.hasPrefix("/") else {
            logger.error("\(environmentKey, privacy: .public) ignored: \"\(path, privacy: .public)\" is not an absolute path")
            return nil
        }
        guard isFile(path) else {
            logger.error("\(environmentKey, privacy: .public) ignored: \(path, privacy: .public) is not a file")
            return nil
        }
        return path
    }

    nonisolated static func isRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// A window's session is up: the first one hands the path to `open`.
    func windowCameUp(open: (String) -> Void) {
        guard let path = pending else { return }
        pending = nil
        open(path)
    }
}

extension LeoRuntime {
    /// Opens `path` in `session`'s editor with local file access, not the
    /// window's (which refuses local files while a remote host is selected).
    func openFixtureFile(_ path: String, in session: LeoWindowSession, reportError: (Error) -> Void) async {
        do {
            try await session.editor.open(
                LeoEditorFileID(host: .local, path: path),
                access: { _ in LeoSlowSaveFixture.wrapIfSet(LeoFileAccessor.local()) }
            )
        } catch {
            reportError(error)
        }
    }
}
#endif
