#if DEBUG
import Foundation
import OSLog

/// DEBUG builds only: opens the local file named by `LEO_OPEN_FILE` (an
/// absolute path) in the first window's editor pane once that window is up,
/// as Agents ▸ Open File in Editor… would after the path is typed -- so GUI
/// checks of the editor needn't get past the Open File panel. Relative,
/// empty or missing paths are logged and ignored.
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

    /// A window's session is up: the first one hands the path to `open`,
    /// as a local file.
    func windowCameUp(open: (String, LeoEditorAgentContext) -> Void) {
        guard let path = pending else { return }
        pending = nil
        open(path, LeoEditorAgentContext(host: .local, name: nil, workspace: nil))
    }
}
#endif
