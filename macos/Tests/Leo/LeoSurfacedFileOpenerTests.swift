import Darwin
import Foundation
import Testing

@testable import Ghostty

/// Security review #1 and #3: an automatic open first stats the file (on
/// its host, following symlinks) and opens only a regular file under the
/// auto-open cap -- anything else just stays badged; and each incarnation
/// has at most one automatic open in flight plus one waiting, latest wins.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LeoSurfacedFileOpenerTests {
    @Test func anAutomaticOpenOfASmallRegularFileOpensAtItsLineAndIsSeen() async {
        let harness = OpenerHarness(stats: ["/w/a.swift": stat(.file, size: 10)])
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", path: "a.swift", line: 7, absPath: "/w/a.swift"), host: .local, mode: .automatic, in: harness.target)
        #expect(harness.opened == ["/w/a.swift:7"])
        #expect(harness.seen == ["u-1"])
    }

    @Test(arguments: [LeoFileKind.directory, .other, .symlink])
    func anAutomaticOpenOfAnythingButARegularFileOnlyBadges(kind: LeoFileKind) async {
        let harness = OpenerHarness(stats: ["/dev/zero": stat(kind, size: 0)])
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/dev/zero"), host: .local, mode: .automatic, in: harness.target)
        #expect(harness.opened.isEmpty)
        #expect(harness.seen.isEmpty)
        #expect(harness.errors.isEmpty, "a skipped auto-open is quiet")
    }

    @Test func anAutomaticOpenOverTheCapOnlyBadges() async {
        let harness = OpenerHarness(stats: ["/w/big.log": stat(.file, size: LeoSurfacedFileOpener.defaultAutoOpenLimit + 1)])
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/big.log"), host: .local, mode: .automatic, in: harness.target)
        #expect(harness.opened.isEmpty)
        #expect(harness.seen.isEmpty)
    }

    @Test func anAutomaticOpenOfAMissingFileOnlyBadges() async {
        let harness = OpenerHarness(stats: [:])
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/gone"), host: .local, mode: .automatic, in: harness.target)
        #expect(harness.opened.isEmpty)
        #expect(harness.errors.isEmpty)
    }

    @Test func aManualOpenGoesStraightToTheEditorAndReportsItsError() async {
        let harness = OpenerHarness(stats: [:], openFails: true)
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/gone"), host: .local, mode: .manual, in: harness.target)
        #expect(harness.opened == ["/w/gone:-"])
        #expect(harness.errors.count == 1)
    }

    // MARK: Seen only on a successful open (re-review #2)

    @Test(arguments: [LeoSurfacedOpenMode.automatic, .manual])
    func aCancelledOpenKeepsTheBadge(mode: LeoSurfacedOpenMode) async {
        let harness = OpenerHarness(stats: ["/w/a": stat(.file, size: 1)], outcome: .cancelled)
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/a"), host: .local, mode: mode, in: harness.target)
        #expect(harness.opened == ["/w/a:-"])
        #expect(harness.seen.isEmpty)
    }

    @Test(arguments: [LeoEditorOpenOutcome.opened, .alreadyOpen])
    func aManualOpenThatShowsTheFileMarksItSeen(outcome: LeoEditorOpenOutcome) async {
        let harness = OpenerHarness(stats: [:], outcome: outcome)
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/a"), host: .local, mode: .manual, in: harness.target)
        #expect(harness.seen == ["u-1"])
    }

    /// Re-review #3: an automatic open whose read timed out (or failed any
    /// way) fails closed -- badge kept, no sheet.
    @Test func aFailedAutomaticOpenKeepsTheBadgeQuietly() async {
        let harness = OpenerHarness(stats: ["/w/a": stat(.file, size: 1)], openFails: true)
        await harness.opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: "/w/a"), host: .local, mode: .automatic, in: harness.target)
        #expect(harness.opened == ["/w/a:-"])
        #expect(harness.seen.isEmpty)
        #expect(harness.errors.isEmpty)
    }

    /// A real named pipe, through the real local file access: never opened
    /// (the read would block forever), only badged.
    @Test func aRealFIFOIsNeverAutoOpened() async throws {
        let sandbox = try LeoFileSandbox()
        defer { try? FileManager.default.removeItem(atPath: sandbox.root) }
        let fifo = sandbox.path("pipe")
        #expect(mkfifo(fifo, 0o600) == 0)
        var opened: [String] = []
        let target = LeoSurfacedFileOpener.Target(
            stat: { try await LeoFileAccessor.local().stat($0.path) },
            open: { id, _ in
                opened.append(id.path)
                return .opened
            },
            reportError: { _ in }
        )
        let opener = LeoSurfacedFileOpener { _, _ in }
        await opener.open(surfaced("u-1", agent: "alpha", startedAt: "s1", absPath: fifo), host: .local, mode: .automatic, in: target)
        #expect(opened.isEmpty)
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

    @Test func aFloodForOneIncarnationOpensTheFirstAndTheLatestOnly() async throws {
        let gate = StatGate()
        let harness = OpenerHarness(stats: [:], defaultStat: stat(.file, size: 1), gate: gate)
        let files = (1...5).map { surfaced("u-\($0)", agent: "alpha", startedAt: "s1", absPath: "/w/\($0)") }
        let first = Task { await harness.opener.open(files[0], host: .local, mode: .automatic, in: harness.target) }
        try await until { await MainActor.run { gate.waiting } == 1 }
        var rest: [Task<Void, Never>] = []
        for file in files.dropFirst() {
            rest.append(Task { await harness.opener.open(file, host: .local, mode: .automatic, in: harness.target) })
        }
        for task in rest { await task.value }
        #expect(gate.waiting == 1, "the rest wait behind the one in flight without stat-ing")
        // Another incarnation isn't held up by it.
        let other = surfaced("u-9", agent: "beta", startedAt: "s1", absPath: "/w/9")
        let otherTask = Task { await harness.opener.open(other, host: .local, mode: .automatic, in: harness.target) }
        try await until { await MainActor.run { gate.waiting } == 2 }
        gate.releaseAll()
        try await until { await MainActor.run { gate.waiting } == 1 }
        gate.releaseAll()
        await first.value
        await otherTask.value
        #expect(Set(harness.opened) == ["/w/1:-", "/w/5:-", "/w/9:-"])
        #expect(Set(harness.seen) == ["u-1", "u-5", "u-9"], "the skipped ones stay badged")
    }
}

private func stat(_ kind: LeoFileKind, size: UInt64) -> LeoFileStat {
    LeoFileStat(kind: kind, size: size, modified: Date(timeIntervalSince1970: 0), permissions: 0o644)
}

private func surfaced(_ id: String, agent: String, startedAt: String, path: String = "f", line: Int? = nil, absPath: String) -> LeoSurfacedFile {
    LeoSurfacedFile(id: id, agent: agent, startedAt: startedAt, path: path, absPath: absPath, line: line)
}

@MainActor private final class StatGate {
    private var held: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { held.count }
    func pass() async { await withCheckedContinuation { held.append($0) } }
    func releaseAll() {
        let pending = held
        held = []
        pending.forEach { $0.resume() }
    }
}

@MainActor private final class OpenerHarness {
    private(set) var opened: [String] = []
    private(set) var seen: [String] = []
    private(set) var errors: [Error] = []
    private(set) var opener: LeoSurfacedFileOpener!
    private(set) var target: LeoSurfacedFileOpener.Target!

    init(
        stats: [String: LeoFileStat], defaultStat: LeoFileStat? = nil, gate: StatGate? = nil, openFails: Bool = false,
        outcome: LeoEditorOpenOutcome = .opened
    ) {
        opener = LeoSurfacedFileOpener { [unowned self] file, _ in seen.append(file.id) }
        target = LeoSurfacedFileOpener.Target(
            stat: { id in
                await gate?.pass()
                guard let stat = stats[id.path] ?? defaultStat else { throw LeoFileAccessError.notFound(path: id.path) }
                return stat
            },
            open: { [unowned self] id, line in
                opened.append("\(id.path):\(line.map(String.init) ?? "-")")
                if openFails { throw LeoFileAccessError.notFound(path: id.path) }
                return outcome
            },
            reportError: { [unowned self] in errors.append($0) }
        )
    }
}
