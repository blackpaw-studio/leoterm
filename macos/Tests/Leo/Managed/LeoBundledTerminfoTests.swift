import Foundation
import Testing

/// The bundled tmux defaults to `TERM=tmux-256color`, and macOS before 14
/// has no such terminfo entry. Leo.app ships it in its own terminfo dir,
/// which the managed daemon's `TERMINFO_DIRS` points at.
struct LeoBundledTerminfoTests {
    private static func entry() throws -> URL {
        let resources = try #require(Bundle.main.resourceURL)
        return resources.appendingPathComponent("terminfo/74/tmux-256color")
    }

    @Test func tmux256ColorEntryIsBundled() throws {
        let path = try Self.entry().path
        #expect(FileManager.default.fileExists(atPath: path), "missing \(path)")
    }

    /// 0432 (bytes 1a 01) is the format macOS's ncurses 6.0 reads; a newer
    /// tic writes 01036 (1e 02), which the system library rejects.
    @Test func tmux256ColorEntryUsesTheLegacyFormat() throws {
        let data = try Data(contentsOf: Self.entry())
        #expect(Array(data.prefix(2)) == [0x1A, 0x01])
    }
}
