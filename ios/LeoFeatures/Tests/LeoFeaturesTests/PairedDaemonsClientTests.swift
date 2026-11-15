import Foundation
import Testing

@testable import LeoFeatures

struct PairedDaemonsClientTests {
    /// iOS keeps the file under "Application Support": a space in the path
    /// must not hide what was saved.
    @Test func savedDaemonsLoadBackFromAPathWithASpace() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Leo Tests \(UUID().uuidString)/Application Support")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let client = PairedDaemonsClient.live(directory: directory)

        #expect(try client.load() == [])
        try client.save([.dionysus, .hestia])
        #expect(try client.load() == [.dionysus, .hestia])
    }
}
