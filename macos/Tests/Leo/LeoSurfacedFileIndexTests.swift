import Foundation
import Testing

@testable import Ghostty

/// B-013: surfaced files attach to a row only through the row's own
/// incarnation (`started_at`, D-074/D-075), are deduped by `id`, and are
/// bounded.
struct LeoSurfacedFileIndexTests {
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

    @Test func duplicatesByIdAreDropped() {
        let first = LeoSurfacedFileIndex.empty.inserting(surfaced("u-1", agent: "alpha", startedAt: "s1"))
        #expect(first.isNew)
        let second = first.index.inserting(surfaced("u-1", agent: "alpha", startedAt: "s1", reason: "again"))
        #expect(!second.isNew)
        #expect(second.index == first.index)
    }

    @Test func eachIncarnationKeepsItsNewestTwenty() {
        let index = (1...25).reduce(LeoSurfacedFileIndex.empty) { index, n in
            index.inserting(surfaced("u-\(n)", agent: "alpha", startedAt: "s1")).index
        }
        let files = index.files(name: "alpha", startedAt: "s1")
        #expect(files.count == LeoSurfacedFileIndex.perIncarnationLimit)
        #expect(files.first?.id == "u-6")
        #expect(files.last?.id == "u-25")
    }

    @Test func theIndexForgetsTheLeastRecentIncarnationsPastItsBound() {
        let limit = LeoSurfacedFileIndex.incarnationLimit
        let index = (0...limit).reduce(LeoSurfacedFileIndex.empty) { index, n in
            index.inserting(surfaced("u-\(n)", agent: "agent-\(n)", startedAt: "s")).index
        }
        #expect(index.files(name: "agent-0", startedAt: "s").isEmpty)
        #expect(index.files(name: "agent-\(limit)", startedAt: "s").count == 1)
    }

    /// Recovery: `/state`'s list (newest last) is authoritative for order;
    /// files only an event reported (newer than the fetch) stay after it.
    @Test func mergingStateUnionsByIdKeepingStateOrder() {
        let live = LeoSurfacedFileIndex.empty
            .inserting(surfaced("u-3", agent: "alpha", startedAt: "s1")).index
            .inserting(surfaced("u-2", agent: "alpha", startedAt: "s1")).index
        let state = [LeoObservedAgent(
            name: "alpha", status: .running, activity: nil, currentAction: nil, lastActivityAt: nil, startedAt: "s1",
            surfacedFiles: [surfaced("u-1", agent: "alpha", startedAt: "s1"), surfaced("u-2", agent: "alpha", startedAt: "s1")]
        )]
        #expect(live.merging(state: state).files(name: "alpha", startedAt: "s1").map(\.id) == ["u-1", "u-2", "u-3"])
    }

    @Test func anOldDaemonsStateChangesNothing() {
        let state = [LeoObservedAgent(name: "alpha", status: .running, activity: nil, currentAction: nil, lastActivityAt: nil, startedAt: "s1")]
        #expect(LeoSurfacedFileIndex.empty.merging(state: state) == .empty)
    }
}

func surfaced(
    _ id: String, agent: String, startedAt: String, path: String = "src/file.swift", line: Int? = nil, reason: String? = nil
) -> LeoSurfacedFile {
    LeoSurfacedFile(id: id, agent: agent, startedAt: startedAt, path: path, absPath: "/w/\(agent)/\(path)", line: line, reason: reason)
}

private func row(_ name: String, _ startedAt: String?, host: LeoHostID = .local) -> LeoAgentRow {
    LeoAgentRow(host: host, name: name, template: nil, status: .running, activity: .unknown, actionDetail: nil, startedAt: startedAt)
}
