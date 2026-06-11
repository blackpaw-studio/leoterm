import Foundation

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

    /// Write boards atomically, creating the parent directory if needed.
    func save(_ boards: [Board]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(boards).write(to: fileURL, options: .atomic)
    }
}
