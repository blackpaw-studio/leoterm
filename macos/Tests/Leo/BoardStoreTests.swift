import Testing
import Foundation
@testable import Ghostty

struct BoardStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("boards-\(UUID()).json")
    }

    @Test func savesAndLoadsRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BoardStore(fileURL: url)
        let boards = [Board(name: "work", cells: [BoardCell(source: .agent(name: "a"))])]
        try store.save(boards)
        #expect(try store.load() == boards)
    }

    @Test func loadReturnsEmptyWhenFileMissing() throws {
        let store = BoardStore(fileURL: tempURL())
        #expect(try store.load().isEmpty)
    }

    @Test func loadThrowsOnCorruptFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { _ = try BoardStore(fileURL: url).load() }
    }

    @Test func loadOrQuarantineMovesCorruptFileAsideAndReturnsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let store = BoardStore(fileURL: url)
        let at = Date(timeIntervalSince1970: 0)

        #expect(store.loadOrQuarantine(now: at).isEmpty)

        let quarantined = BoardStore.quarantineURL(for: url, at: at)
        defer { try? FileManager.default.removeItem(at: quarantined) }
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(quarantined.lastPathComponent.hasPrefix("\(url.lastPathComponent).corrupt-"))
    }

    @Test func loadOrQuarantineReturnsBoardsWhenFileIsValid() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BoardStore(fileURL: url)
        let boards = [Board(name: "work", cells: [BoardCell(source: .pty)])]
        try store.save(boards)
        #expect(store.loadOrQuarantine() == boards)
    }

    @Test func loadOrQuarantineReturnsEmptyWhenFileIsMissing() {
        let url = tempURL()
        #expect(BoardStore(fileURL: url).loadOrQuarantine().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func quarantineNameUsesAnISOTimestamp() {
        let url = URL(fileURLWithPath: "/tmp/boards.json")
        let name = BoardStore.quarantineURL(for: url, at: Date(timeIntervalSince1970: 0)).lastPathComponent
        #expect(name == "boards.json.corrupt-1970-01-01T00:00:00Z")
    }
}
