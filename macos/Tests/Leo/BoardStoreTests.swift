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
}
