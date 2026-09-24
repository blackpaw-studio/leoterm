#if DEBUG
import Foundation
import OSLog

/// DEBUG builds only: `LEO_SURFACE_FIXTURE=<json file>` holds an array of
/// `file_surfaced` event objects (the daemon's shape, `type` optional),
/// injected into the feed as live events once the first agent list lands,
/// so the row indicator and menus can be seen before the
/// daemon emits them. Entries that don't decode are logged and skipped;
/// nothing is sent anywhere.
enum LeoSurfaceFixture {
    static let environmentKey = "LEO_SURFACE_FIXTURE"
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [LeoSurfacedFile]? {
        guard let path = environment[environmentKey] else { return nil }
        do {
            let files = try JSONDecoder().decode(LeoLenientSurfacedFiles.self, from: Data(contentsOf: URL(fileURLWithPath: path))).files
            logger.log("surface fixture \(path, privacy: .public): \(files.count) events")
            return files
        } catch {
            logger.error("surface fixture \(path, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Hands the fixture's events over once, on the first successful list.
@MainActor final class LeoSurfaceFixtureInjector {
    private var pending: [LeoSurfacedFile]?

    init(files: [LeoSurfacedFile]? = LeoSurfaceFixture.load()) {
        pending = files
    }

    func snapshotLanded(_ snapshot: LeoSidebarSnapshot, inject: ([LeoSurfacedFile]) -> Void) {
        guard snapshot.listRefreshSucceeded, let files = pending else { return }
        pending = nil
        inject(files)
    }
}
#endif
