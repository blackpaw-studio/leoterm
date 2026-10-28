import Foundation
import os

/// Leo's own defaults for Ghostty config keys.
///
/// They are loaded as the first config file, before the user's files and CLI
/// arguments, so anything the user sets still wins, even a value that equals
/// upstream Ghostty's default. Upstream's defaults stay as they are in Zig.
enum LeoConfigDefaults {
    /// How long Close Terminal (and the other undo actions that hold a pty)
    /// can be undone. Upstream's 5 s is too short to reach Edit ▸ Undo from
    /// the menu (B-174).
    static let undoTimeout: Duration = .seconds(30)

    /// The defaults in config-file syntax.
    static var text: String {
        "undo-timeout = \(undoTimeout.components.seconds)s\n"
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "studio.blackpaw.leo.macos",
        category: "config"
    )

    /// Writes `text` to a stable per-user temp path and returns it, or nil if
    /// the write failed (upstream defaults then apply).
    static func writeFile(
        in directory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        let url = directory.appendingPathComponent("leo-config-defaults.ghostty")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path()
        } catch {
            logger.warning("could not write leo config defaults: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
