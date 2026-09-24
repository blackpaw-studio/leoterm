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

    /// Review #2: identity is (incarnation, id). A new incarnation reusing
    /// an id is a different file.
    @Test func aNewIncarnationReusingAnIdIsANewFile() {
        let first = LeoSurfacedFileIndex.empty.inserting(surfaced("u-1", agent: "alpha", startedAt: "s1")).index
        let second = first.inserting(surfaced("u-1", agent: "alpha", startedAt: "s2"))
        #expect(second.isNew)
        #expect(second.index.files(name: "alpha", startedAt: "s2").map(\.id) == ["u-1"])

        let state = [observed("alpha", "s2", files: [surfaced("u-1", agent: "alpha", startedAt: "s2")])]
        #expect(first.merging(state: state).files(name: "alpha", startedAt: "s2").map(\.id) == ["u-1"])
    }

    /// Review #3: a full baseline (the daemon's newest 20) can't say
    /// whether an event-only file is newer or fell out of its window; one
    /// without a later `at` is dropped, never promoted to newest.
    @Test func aFullBaselineDropsAnEventOnlyFileItCantPlaceAsNewer() {
        let cap = LeoSurfacedFileIndex.perIncarnationLimit
        let baseline = (1...cap).map { surfaced("u-\($0)", agent: "alpha", startedAt: "s1", at: at($0)) }
        let live = LeoSurfacedFileIndex.empty
            .inserting(surfaced("old", agent: "alpha", startedAt: "s1", at: at(0))).index
            .inserting(surfaced("undated", agent: "alpha", startedAt: "s1")).index
            .inserting(surfaced("new", agent: "alpha", startedAt: "s1", at: at(cap + 1))).index
        let merged = live.merging(state: [observed("alpha", "s1", files: baseline)]).files(name: "alpha", startedAt: "s1")
        #expect(merged.map(\.id) == Array(baseline.map(\.id).dropFirst()) + ["new"])
    }

    /// Below the cap the baseline holds everything the daemon had, so an
    /// event-only file came after the fetch: kept as newest.
    @Test func aPartialBaselineKeepsEventOnlyFilesAsNewest() {
        let live = LeoSurfacedFileIndex.empty.inserting(surfaced("undated", agent: "alpha", startedAt: "s1")).index
        let merged = live.merging(state: [observed("alpha", "s1", files: [surfaced("u-1", agent: "alpha", startedAt: "s1")])])
        #expect(merged.files(name: "alpha", startedAt: "s1").map(\.id) == ["u-1", "undated"])
    }

    /// Re-review #1: a live event with `at` is placed by it, so a delayed
    /// one never lands as newest; older than everything in a full index,
    /// it's dropped rather than evicting a newer file.
    @Test func aLiveEventIsPlacedByItsTimestamp() {
        let partial = [1, 3].reduce(LeoSurfacedFileIndex.empty) { $0.inserting(surfaced("u-\($1)", agent: "alpha", startedAt: "s1", at: at($1))).index }
        let placed = partial.inserting(surfaced("u-2", agent: "alpha", startedAt: "s1", at: at(2)))
        #expect(placed.isNew)
        #expect(placed.index.files(name: "alpha", startedAt: "s1").map(\.id) == ["u-1", "u-2", "u-3"])

        let cap = LeoSurfacedFileIndex.perIncarnationLimit
        let full = (1...cap).reduce(LeoSurfacedFileIndex.empty) { $0.inserting(surfaced("u-\($1)", agent: "alpha", startedAt: "s1", at: at($1 * 2))).index }
        let stale = full.inserting(surfaced("stale", agent: "alpha", startedAt: "s1", at: at(1)))
        #expect(!stale.isNew)
        #expect(stale.index.files(name: "alpha", startedAt: "s1") == full.files(name: "alpha", startedAt: "s1"))

        let between = full.inserting(surfaced("mid", agent: "alpha", startedAt: "s1", at: at(5))).index.files(name: "alpha", startedAt: "s1")
        #expect(between.map(\.id).prefix(3) == ["u-2", "mid", "u-3"], "the oldest is evicted, not a newer one")
        #expect(between.last?.id == "u-\(cap)")
    }

    /// Re-review #2: fullness is the count the daemon sent, before a
    /// malformed or duplicate entry is filtered out.
    @Test func aFullBaselineWithAMalformedEntryIsStillFull() throws {
        let cap = LeoSurfacedFileIndex.perIncarnationLimit
        let entries = (1..<cap).map {
            #"{"agent":"alpha","started_at":"s1","id":"u-\#($0)","path":"f","abs_path":"/w/f\#($0)","at":"\#(at($0))"}"#
        } + [#"{"agent":"alpha"}"#]
        let json = #"{"name":"alpha","started_at":"s1","surfaced_files":[\#(entries.joined(separator: ","))]}"#
        let agent = try JSONDecoder().decode(LeoObservedAgent.self, from: Data(json.utf8))
        #expect(agent.surfacedFiles.count == cap - 1)
        let live = LeoSurfacedFileIndex.empty.inserting(surfaced("undated", agent: "alpha", startedAt: "s1")).index
        #expect(!live.merging(state: [agent]).files(name: "alpha", startedAt: "s1").map(\.id).contains("undated"))
    }

    @Test func anOldDaemonsStateChangesNothing() {
        let state = [LeoObservedAgent(name: "alpha", status: .running, activity: nil, currentAction: nil, lastActivityAt: nil, startedAt: "s1")]
        #expect(LeoSurfacedFileIndex.empty.merging(state: state) == .empty)
    }
}

func surfaced(
    _ id: String, agent: String, startedAt: String, path: String = "src/file.swift", line: Int? = nil, reason: String? = nil,
    at: String? = nil
) -> LeoSurfacedFile {
    LeoSurfacedFile(id: id, agent: agent, startedAt: startedAt, path: path, absPath: "/w/\(agent)/\(path)", line: line, reason: reason, at: at)
}

private func at(_ minute: Int) -> String { String(format: "2026-09-24T15:%02d:00Z", minute) }

private func observed(_ name: String, _ startedAt: String, files: [LeoSurfacedFile]) -> LeoObservedAgent {
    LeoObservedAgent(
        name: name, status: .running, activity: nil, currentAction: nil, lastActivityAt: nil, startedAt: startedAt, surfacedFiles: files
    )
}

private func row(_ name: String, _ startedAt: String?, host: LeoHostID = .local) -> LeoAgentRow {
    LeoAgentRow(host: host, name: name, template: nil, status: .running, activity: .unknown, actionDetail: nil, startedAt: startedAt)
}
