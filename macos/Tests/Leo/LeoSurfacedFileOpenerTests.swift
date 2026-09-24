import Darwin
import Foundation
import Testing

@testable import Ghostty

/// A user-initiated surfaced-file open (D-088: there is no other kind)
/// first stats the file on its host, following symlinks, and opens only a
/// regular file -- anything else, or a failure, gets the error sheet; it
/// re-checks the file's incarnation after the stat, and marks the file
/// seen only once the pane shows it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LeoSurfacedFileOpenerTests {
    @Test func aRegularFileOpensAtItsLineAndIsSeen() async {
        let harness = OpenerHarness(stats: ["/w/a.swift": stat(.file, size: 10)])
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", path: "a.swift", line: 7, absPath: "/w/a.swift"), host: .local, in: harness.target)
        #expect(harness.opened == ["/w/a.swift:7"])
        #expect(harness.seen == ["u-1"])
        #expect(harness.errors.isEmpty)
    }

    @Test(arguments: [LeoFileKind.directory, .other, .symlink])
    func anythingButARegularFileIsRefusedWithASheet(kind: LeoFileKind) async {
        let harness = OpenerHarness(stats: ["/dev/zero": stat(kind, size: 0)])
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/dev/zero"), host: .local, in: harness.target)
        #expect(harness.opened.isEmpty)
        #expect(harness.seen.isEmpty)
        #expect(harness.errors.count == 1)
    }

    @Test func aMissingFileGetsASheetAndKeepsItsBadge() async {
        let harness = OpenerHarness(stats: [:])
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/gone"), host: .local, in: harness.target)
        #expect(harness.opened.isEmpty)
        #expect(harness.seen.isEmpty)
        #expect(harness.errors.count == 1)
    }

    @Test func aFailedOpenGetsASheetAndKeepsItsBadge() async {
        let harness = OpenerHarness(stats: ["/w/a": stat(.file, size: 1)], openFails: true)
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/a"), host: .local, in: harness.target)
        #expect(harness.opened == ["/w/a:-"])
        #expect(harness.seen.isEmpty)
        #expect(harness.errors.count == 1)
    }

    @Test func aCancelledOpenKeepsTheBadge() async {
        let harness = OpenerHarness(stats: ["/w/a": stat(.file, size: 1)], outcome: .cancelled)
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/a"), host: .local, in: harness.target)
        #expect(harness.opened == ["/w/a:-"])
        #expect(harness.seen.isEmpty)
    }

    @Test func anAlreadyOpenFileIsSeen() async {
        let harness = OpenerHarness(stats: ["/w/a": stat(.file, size: 1)], outcome: .alreadyOpen)
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/a"), host: .local, in: harness.target)
        #expect(harness.seen == ["u-1"])
    }

    /// The agent restarted under the same name while the stat was out:
    /// the old incarnation's file doesn't open.
    @Test func anOpenNoLongerWantedAfterItsStatIsDropped() async {
        let harness = OpenerHarness(stats: ["/w/a": stat(.file, size: 1)], stillWanted: false)
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/a"), host: .local, in: harness.target)
        #expect(harness.opened.isEmpty)
        #expect(harness.seen.isEmpty)
    }

    /// A real named pipe, through the real local file access: never opened
    /// (the read would block forever).
    @Test func aRealFIFOIsNeverOpened() async throws {
        let sandbox = try LeoFileSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox.root) }
        let fifo = sandbox.path("pipe")
        #expect(mkfifo(fifo, 0o600) == 0)
        var opened: [String] = []
        var errors = 0
        let target = LeoSurfacedFileOpener.Target(
            stat: { try await LeoFileAccessor.local().stat($0.path) },
            open: { id, _ in
                opened.append(id.path)
                return .opened
            },
            reportError: { _ in errors += 1 }
        )
        let opener = LeoSurfacedFileOpener { _, _ in }
        await opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: fifo), host: .local, in: target)
        #expect(opened.isEmpty)
        #expect(errors == 1)
    }

    /// Even if a FIFO replaces the file between the stat and the read,
    /// the read fails instead of hanging.
    @Test func readingAFIFODirectlyFailsInsteadOfBlocking() async throws {
        let sandbox = try LeoFileSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox.root) }
        let fifo = sandbox.path("pipe")
        #expect(mkfifo(fifo, 0o600) == 0)
        await #expect(throws: LeoFileAccessError.self) {
            _ = try await LeoLocalFileBackend().contents(of: fifo, limit: 1024)
        }
    }
}

private func stat(_ kind: LeoFileKind, size: UInt64) -> LeoFileStat {
    LeoFileStat(kind: kind, size: size, modified: Date(timeIntervalSince1970: 0), permissions: 0o644)
}

private func surfaced(_ id: String, agent: String, startedAt: String, path: String = "f", line: Int? = nil, absPath: String) -> LeoSurfacedFile {
    LeoSurfacedFile(id: id, agent: agent, startedAt: startedAt, path: path, absPath: absPath, line: line)
}

@MainActor private final class OpenerHarness {
    private(set) var opened: [String] = []
    private(set) var seen: [String] = []
    private(set) var errors: [Error] = []
    private(set) var opener: LeoSurfacedFileOpener!
    private(set) var target: LeoSurfacedFileOpener.Target!

    init(
        stats: [String: LeoFileStat], openFails: Bool = false,
        outcome: LeoEditorOpenOutcome = .opened, stillWanted: Bool = true
    ) {
        opener = LeoSurfacedFileOpener { [unowned self] file, _ in seen.append(file.id) }
        target = LeoSurfacedFileOpener.Target(
            stat: { id in
                guard let stat = stats[id.path] else { throw LeoFileAccessError.notFound(path: id.path) }
                return stat
            },
            open: { [unowned self] id, line in
                opened.append("\(id.path):\(line.map(String.init) ?? "-")")
                if openFails { throw LeoFileAccessError.notFound(path: id.path) }
                return outcome
            },
            reportError: { [unowned self] in errors.append($0) },
            isStillWanted: { stillWanted }
        )
    }
}
