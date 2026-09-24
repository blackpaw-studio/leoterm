import Foundation
import Testing

@testable import Ghostty

/// The browser under overlapping calls and untrusted servers: the last
/// open or close wins and every other file access is released, nested
/// expanded folders never stall on "Loading…", names a server shouldn't
/// send are dropped, and symlinks resolve concurrently but bounded.
@MainActor
struct LeoWorkspaceBrowserHardeningTests {
    private final class Made {
        var accesses: [LeoGatedCloseAccess] = []
    }

    private func agent(_ workspace: String) -> LeoEditorAgentContext {
        LeoEditorAgentContext(host: .local, name: "scratch", workspace: workspace)
    }

    private func gatedBrowser(_ gate: LeoCloseGate) -> (LeoWorkspaceBrowserModel, Made) {
        let made = Made()
        let browser = LeoWorkspaceBrowserModel(
            makeAccess: { _ in
                let access = LeoGatedCloseAccess(gate: gate)
                made.accesses.append(access)
                return access
            },
            openFile: { _ in .opened }
        )
        return (browser, made)
    }

    private func stubBrowser(_ access: any LeoFileAccess) -> LeoWorkspaceBrowserModel {
        LeoWorkspaceBrowserModel(makeAccess: { _ in access }, openFile: { _ in .opened })
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }

    private func names(_ items: [LeoWorkspaceItem]) -> [String] {
        items.map { item in
            switch item {
            case let .entry(entry): entry.name
            case .loading: "<loading>"
            case let .message(_, text): "<\(text)>"
            }
        }
    }

    // MARK: Overlapping opens and closes

    @Test(.timeLimit(.minutes(1)))
    func overlappingOpensEndOnTheLastAndReleaseEveryOtherAccess() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            for name in ["a", "b", "c"] {
                try sandbox.directory(name)
                try sandbox.file("\(name)/in-\(name).txt", "")
            }
            let gate = LeoCloseGate()
            let (browser, made) = gatedBrowser(gate)
            await browser.open(agent(sandbox.path("c")))

            let openA = Task { await browser.open(agent(sandbox.path("a"))) }
            try await eventually { await gate.waiting >= 1 }
            let openB = Task { await browser.open(agent(sandbox.path("b"))) }
            try await Task.sleep(for: .milliseconds(50))
            await gate.open()
            await openA.value
            await openB.value

            #expect(browser.root?.path == sandbox.path("b"))
            #expect(names(browser.rootItems) == ["in-b.txt"])
            // Replaced accesses close alongside the new listing.
            try await eventually { made.accesses.filter { !$0.isClosed }.count == 1 }
            await browser.close()
            try await eventually { made.accesses.allSatisfy(\.isClosed) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func closingDuringAnOpenLeavesTheBrowserClosed() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            try sandbox.directory("a")
            try sandbox.directory("c")
            let gate = LeoCloseGate()
            let (browser, made) = gatedBrowser(gate)
            await browser.open(agent(sandbox.path("c")))

            let opening = Task { await browser.open(agent(sandbox.path("a"))) }
            try await eventually { await gate.waiting >= 1 }
            let closing = Task { await browser.close() }
            try await Task.sleep(for: .milliseconds(50))
            await gate.open()
            await opening.value
            await closing.value

            #expect(!browser.isOpen)
            #expect(browser.folders.isEmpty)
            try await eventually { made.accesses.allSatisfy(\.isClosed) }
        }
    }

    /// Re-rooting lists the new workspace at once: the old access closes
    /// alongside, and is still released once its close gets through.
    @Test(.timeLimit(.minutes(1)))
    func aNewRootIsListedWithoutWaitingForTheOldAccessToClose() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            for name in ["a", "c"] {
                try sandbox.directory(name)
                try sandbox.file("\(name)/in-\(name).txt", "")
            }
            let gate = LeoCloseGate()
            let (browser, made) = gatedBrowser(gate)
            await browser.open(agent(sandbox.path("c")))

            let opening = Task { await browser.open(agent(sandbox.path("a"))) }
            try await eventually { names(browser.rootItems) == ["in-a.txt"] }

            #expect(await gate.waiting == 1, "the old access is still closing")
            #expect(!made.accesses[0].isClosed)
            await gate.open()
            await opening.value
            try await eventually { made.accesses[0].isClosed }
            #expect(!made.accesses[1].isClosed)
            await browser.close()
        }
    }

    /// A replaced root's access closes at once, its listing still in
    /// flight; the listing is cancelled and starts nothing more on it. The
    /// new root's listing doesn't wait for either.
    @Test(.timeLimit(.minutes(1)))
    func aReplacedRootsAccessClosesAtOnceAndItsListingStops() async throws {
        let gate = LeoCloseGate()
        let old = LeoGatedStatAccess(gate: gate, links: 2 * LeoWorkspaceBrowserModel.symlinkStatLimit)
        let queue = LeoAccessQueue([old, LeoStubListAccess(entries: [LeoStubListAccess.entry("b.txt", kind: .file)])])
        let browser = LeoWorkspaceBrowserModel(makeAccess: { _ in queue.next() }, openFile: { _ in .opened })
        let first = Task { await browser.open(agent("/a")) }
        try await eventually { await gate.waiting >= 1 }

        await browser.open(agent("/b"))

        #expect(names(browser.rootItems) == ["b.txt"])
        try await eventually { old.isClosed }
        await gate.open()
        await first.value
        #expect(old.callsAfterClose == 0)
    }

    /// Over SFTP, a server that never answers the old root's listing
    /// doesn't keep its connection open: re-rooting closes it at once, the
    /// listing fails, and nothing reconnects.
    @Test(.timeLimit(.minutes(1)))
    func aHungSFTPListingDoesNotKeepTheOldConnectionOpen() async throws {
        let script = "head -c 9 >/dev/null; \(LeoSFTPTestServer.versionReply); exec sleep 30"
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script(script))
        let hung = LeoCloseProbe(LeoFileAccessor.sftp(launcher: launcher))
        let queue = LeoAccessQueue([hung, LeoStubListAccess(entries: [LeoStubListAccess.entry("b.txt", kind: .file)])])
        let browser = LeoWorkspaceBrowserModel(makeAccess: { _ in queue.next() }, openFile: { _ in .opened })
        let first = Task { await browser.open(agent("/a")) }
        try await eventually { launcher.launches == 1 }
        try await Task.sleep(for: .milliseconds(100))

        await browser.open(agent("/b"))

        try await eventually { hung.hasClosed }
        await first.value
        #expect(launcher.launches == 1)
        await browser.close()
    }

    // MARK: Nested expanded folders after a reload

    @Test(arguments: [LeoFileBackendKind.local, .sftp])
    func nestedExpandedFoldersAreListedAgainAfterAReload(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.directory("src/deep/deeper")
            try sandbox.file("src/deep/deeper/x.txt", "")
            let browser = LeoWorkspaceBrowserModel(makeAccess: { _ in kind.makeAccess() }, openFile: { _ in .opened })
            await browser.open(agent(sandbox.root))
            await browser.expand(sandbox.path("src"))
            await browser.expand(sandbox.path("src/deep"))
            await browser.expand(sandbox.path("src/deep/deeper"))
            browser.collapse(sandbox.path("src"))

            await browser.reload()
            await browser.expand(sandbox.path("src"))

            #expect(names(browser.items(in: sandbox.path("src/deep"))) == ["deeper"])
            #expect(names(browser.items(in: sandbox.path("src/deep/deeper"))) == ["x.txt"])
            await browser.close()
        }
    }

    @Test
    func anExpandedDotfolderIsListedAgainWhenHiddenFilesAreShown() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            try sandbox.directory(".git")
            try sandbox.file(".git/HEAD", "")
            let browser = LeoWorkspaceBrowserModel(makeAccess: { _ in LeoFileAccessor.local() }, openFile: { _ in .opened })
            await browser.open(agent(sandbox.root))
            await browser.toggleHiddenFiles()
            await browser.expand(sandbox.path(".git"))
            await browser.toggleHiddenFiles()
            await browser.reload()

            await browser.toggleHiddenFiles()

            #expect(names(browser.items(in: sandbox.path(".git"))) == ["HEAD"])
            await browser.close()
        }
    }

    // MARK: Untrusted names and errors

    @Test
    func namesAServerShouldNeverSendAreDropped() async {
        let names = [".", "..", "a/b", "/", "", "nul\0byte", "ok.txt"]
        let access = LeoStubListAccess(entries: names.map { LeoStubListAccess.entry($0, kind: .file) })
        let browser = stubBrowser(access)

        await browser.open(agent("/w"))

        #expect(self.names(browser.rootItems) == ["ok.txt"])
        await browser.close()
    }

    @Test
    func anotherErrorsCurlyQuotesAreStraightened() async {
        struct Refused: LocalizedError {
            var errorDescription: String? { "Refused “evil”\nline" }
        }
        let browser = LeoWorkspaceBrowserModel(makeAccess: { _ in LeoFileAccessor.local() }, openFile: { _ in throw Refused() })
        await browser.open(agent("/tmp"))

        await browser.openFile("/tmp/x")

        #expect(browser.openError == "\u{2068}Refused \"evil\" line\u{2069}")
        await browser.close()
    }

    // MARK: Symlinks

    @Test
    func symlinksResolveConcurrentlyButBounded() async {
        let links = (0..<40).map { LeoStubListAccess.entry(String(format: "link%02d", $0), kind: .symlink) }
        let access = LeoStubListAccess(entries: links, statDelay: .milliseconds(20)) { path in
            path.hasSuffix("0") ? .directory : .file
        }
        let browser = stubBrowser(access)

        await browser.open(agent("/w"))

        #expect(access.maxStatsInFlight > 1)
        #expect(access.maxStatsInFlight <= LeoWorkspaceBrowserModel.symlinkStatLimit)
        let folders = browser.rootItems.compactMap { item -> String? in
            if case let .entry(entry) = item, entry.isFolder { entry.name } else { nil }
        }
        #expect(folders == ["link00", "link10", "link20", "link30"])
        await browser.close()
    }
}

/// Lets `close()` calls through only once opened.
actor LeoCloseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = 0

    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Local file access whose `close()` waits on a gate.
final class LeoGatedCloseAccess: LeoFileAccess, @unchecked Sendable {
    private let base = LeoFileAccessor.local()
    private let gate: LeoCloseGate
    private let lock = NSLock()
    private var closed = false

    init(gate: LeoCloseGate) {
        self.gate = gate
    }

    var isClosed: Bool { lock.withLock { closed } }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }

    func close() async {
        await gate.wait()
        lock.withLock { closed = true }
        await base.close()
    }
}

/// A server that lists whatever it's given and stats slowly, counting how
/// many stats run at once.
final class LeoStubListAccess: LeoFileAccess, @unchecked Sendable {
    private let entries: [LeoFileEntry]
    private let statDelay: Duration
    private let kindOf: @Sendable (String) -> LeoFileKind
    private let lock = NSLock()
    private var inFlight = 0
    private var maxInFlight = 0

    init(entries: [LeoFileEntry], statDelay: Duration = .zero, kindOf: @escaping @Sendable (String) -> LeoFileKind = { _ in .file }) {
        self.entries = entries
        self.statDelay = statDelay
        self.kindOf = kindOf
    }

    static func entry(_ name: String, kind: LeoFileKind) -> LeoFileEntry {
        LeoFileEntry(name: name, kind: kind, size: 0, modified: .distantPast)
    }

    var maxStatsInFlight: Int { lock.withLock { maxInFlight } }

    func list(_ path: String) async throws -> [LeoFileEntry] { entries }

    func stat(_ path: String) async throws -> LeoFileStat {
        lock.withLock {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        try? await Task.sleep(for: statDelay)
        lock.withLock { inFlight -= 1 }
        return LeoFileStat(kind: kindOf(path), size: 0, modified: .distantPast, permissions: 0o755)
    }

    func homeDirectory() async throws -> String { "/" }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { throw LeoFileAccessError.notFound(path: path) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        throw LeoFileAccessError.notFound(path: path)
    }
    func close() async {}
}

/// Hands out the accesses given, in order.
@MainActor final class LeoAccessQueue {
    private var accesses: [any LeoFileAccess]

    init(_ accesses: [any LeoFileAccess]) {
        self.accesses = accesses
    }

    func next() -> any LeoFileAccess { accesses.removeFirst() }
}

/// Lists `links` symlinks whose stats wait on a gate, and records any call
/// started once it's closed.
final class LeoGatedStatAccess: LeoFileAccess, @unchecked Sendable {
    private let gate: LeoCloseGate
    private let links: Int
    private let lock = NSLock()
    private var inFlight = 0
    private var closed = false
    private var afterClose = 0

    init(gate: LeoCloseGate, links: Int) {
        self.gate = gate
        self.links = links
    }

    var isClosed: Bool { lock.withLock { closed } }
    var callsAfterClose: Int { lock.withLock { afterClose } }

    func list(_ path: String) async throws -> [LeoFileEntry] {
        begin()
        defer { end() }
        return (0..<links).map { LeoStubListAccess.entry("link\($0)", kind: .symlink) }
    }

    func stat(_ path: String) async throws -> LeoFileStat {
        begin()
        defer { end() }
        await gate.wait()
        return LeoFileStat(kind: .directory, size: 0, modified: .distantPast, permissions: 0o755)
    }

    func homeDirectory() async throws -> String { "/" }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { throw LeoFileAccessError.notFound(path: path) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        throw LeoFileAccessError.notFound(path: path)
    }

    func close() async {
        lock.withLock {
            closed = true
        }
    }

    private func begin() {
        lock.withLock {
            inFlight += 1
            if closed { afterClose += 1 }
        }
    }

    private func end() {
        lock.withLock { inFlight -= 1 }
    }
}

/// Delegates to `base`, noting when `close()` has returned.
final class LeoCloseProbe: LeoFileAccess, @unchecked Sendable {
    private let base: any LeoFileAccess
    private let lock = NSLock()
    private var closed = false

    init(_ base: any LeoFileAccess) {
        self.base = base
    }

    var hasClosed: Bool { lock.withLock { closed } }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }

    func close() async {
        await base.close()
        lock.withLock { closed = true }
    }
}
