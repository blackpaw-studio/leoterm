import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-013: an index's files attach to a sidebar row only through the row's
/// own incarnation (`started_at`, D-074/D-075).
struct LeoSurfacedFileIndexRowTests {
    @Test func aFileAttachesOnlyToItsOwnIncarnation() {
        let index = LeoSurfacedFileIndex.empty.inserting(surfaced("u-1", agent: "alpha", startedAt: "s1")).index
        let rows = index.attach(to: [row("alpha", "s1"), row("beta", "s1")])
        #expect(rows[0].surfacedFiles.map(\.id) == ["u-1"])
        #expect(rows[1].surfacedFiles.isEmpty)
    }

    @Test func aRecreatedNamesakeNeverInheritsTheOldIncarnationsFiles() {
        let index = LeoSurfacedFileIndex.empty.inserting(surfaced("u-1", agent: "alpha", startedAt: "s1")).index
        #expect(index.attach(to: [row("alpha", "s2")])[0].surfacedFiles.isEmpty)
        #expect(index.attach(to: [row("alpha", nil)])[0].surfacedFiles.isEmpty, "never keyed by name alone")
    }

    @Test func aFileThatArrivesBeforeItsRowAttachesOnceTheRowLands() {
        let index = LeoSurfacedFileIndex.empty.inserting(surfaced("u-1", agent: "alpha", startedAt: "s2")).index
        #expect(index.attach(to: [row("alpha", "s1")])[0].surfacedFiles.isEmpty)
        #expect(index.attach(to: [row("alpha", "s2")])[0].surfacedFiles.map(\.id) == ["u-1"])
    }
}

func surfaced(
    _ id: String, agent: String, startedAt: String, path: String = "src/file.swift", line: Int? = nil, reason: String? = nil,
    at: String? = nil
) -> LeoSurfacedFile {
    LeoSurfacedFile(id: id, agent: agent, startedAt: startedAt, path: path, absPath: "/w/\(agent)/\(path)", line: line, reason: reason, at: at)
}

private func row(_ name: String, _ startedAt: String?, host: LeoHostID = .local) -> LeoAgentRow {
    LeoAgentRow(host: host, name: name, template: nil, status: .running, activity: .unknown, actionDetail: nil, startedAt: startedAt)
}
