import Foundation
import OSLog

/// Persists boards (view state only) to JSON. Default location:
/// `~/Library/Application Support/Leo/boards.json`.
struct BoardStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("Leo/boards.json")
        }
    }

    /// Load saved boards. Returns `[]` when the file does not exist yet.
    /// Throws on a corrupt/unreadable file (caller decides whether to reset).
    func load() throws -> [Board] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Board].self, from: data)
    }

    /// Load saved boards, quarantining a corrupt file instead of losing it.
    ///
    /// A board file we cannot decode would otherwise be silently overwritten by
    /// the next save. Move it aside to `<name>.corrupt-<ISO timestamp>` so the
    /// user (or a support session) can recover it, then start from empty.
    func loadOrQuarantine(now: Date = Date()) -> [Board] {
        do {
            return try load()
        } catch {
            Self.logger.error("board file unreadable: \(error, privacy: .public)")
            quarantine(at: now, reason: error)
            return []
        }
    }

    /// The path a corrupt board file is moved to. Deterministic in `at` so the
    /// naming is testable.
    static func quarantineURL(for fileURL: URL, at date: Date) -> URL {
        let stamp = ISO8601DateFormatter().string(from: date)
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "board-store")

    private func quarantine(at date: Date, reason: any Error) {
        let destination = Self.quarantineURL(for: fileURL, at: date)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            Self.logger.error("moved corrupt board file to \(destination.path, privacy: .public)")
        } catch {
            // Leaving the corrupt file in place is safer than deleting it, but
            // it means the next save will overwrite it. Nothing else to do.
            Self.logger.error("failed to quarantine corrupt board file: \(error, privacy: .public)")
        }
    }

    /// Write boards atomically, creating the parent directory if needed.
    func save(_ boards: [Board]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(boards).write(to: fileURL, options: .atomic)
    }
}
