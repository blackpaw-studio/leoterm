import Foundation
import Testing

@testable import LeoKit

struct LeoAgentDirectorySnapshotTests {
    static let targets = [
        LeoAgentTarget(machineID: "d1", machineName: "Studio", agent: "zeus"),
        LeoAgentTarget(machineID: "d2", machineName: "Laptop", agent: "zeus"),
    ]

    static func store() -> LeoAgentDirectorySnapshotStore {
        LeoAgentDirectorySnapshotStore(url: FileManager.default.temporaryDirectory.appending(path: "leo-\(UUID().uuidString)/agent-directory.json"))
    }

    @Test func aWrittenSnapshotReadsBack() throws {
        let store = Self.store()
        try store.write(Self.targets)
        #expect(store.read() == Self.targets)
    }

    @Test func aMissingFileReadsAsNoAgents() {
        #expect(Self.store().read().isEmpty)
    }

    @Test func aCorruptFileReadsAsNoAgents() throws {
        let store = Self.store()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.read().isEmpty)
    }

    @Test func writingTheSameAgentsAgainLeavesTheFileUntouched() throws {
        let store = Self.store()
        try store.write(Self.targets)
        let before = try Data(contentsOf: store.url)
        try FileManager.default.removeItem(at: store.url)
        try before.write(to: store.url)
        let marker = try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
        try store.write(Self.targets)
        #expect(try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date == marker)
    }

    @Test func anEmptyListIsNotWrittenOverAGoodSnapshot() throws {
        let store = Self.store()
        try store.write(Self.targets)
        try store.write([])
        #expect(store.read() == Self.targets)
    }
}
