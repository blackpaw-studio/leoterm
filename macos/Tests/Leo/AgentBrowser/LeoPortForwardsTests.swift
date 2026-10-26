import Foundation
import Testing

@testable import Ghostty

/// A scripted forward runner: `busy` local ports refuse to open, `gated`
/// parks every open until `openGate()`, `gatedCloses` parks every close
/// until `openCloseGate()`.
final class FakeForwardRunner: LeoPortForwardRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var busy: Set<Int>
    private var dead: Set<Int> = []
    private var gated: Bool
    private var gatedCloses: Bool
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var parkedCloses: [CheckedContinuation<Void, Never>] = []
    private var openCalls: [(local: Int, remote: Int)] = []
    private var closeCalls: [(local: Int, remote: Int)] = []

    init(busy: Set<Int> = [], gated: Bool = false, gatedCloses: Bool = false) {
        self.busy = busy
        self.gated = gated
        self.gatedCloses = gatedCloses
    }

    var opens: [(local: Int, remote: Int)] { lock.withLock { openCalls } }
    var closes: [(local: Int, remote: Int)] { lock.withLock { closeCalls } }

    func markDead(_ local: Int) { lock.withLock { _ = dead.insert(local) } }

    func openGate() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            gated = false
            defer { parked = [] }
            return parked
        }
        waiting.forEach { $0.resume() }
    }

    func openCloseGate() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            gatedCloses = false
            defer { parkedCloses = [] }
            return parkedCloses
        }
        waiting.forEach { $0.resume() }
    }

    func open(local: Int, remotePort: Int) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldPark = lock.withLock { () -> Bool in
                openCalls.append((local, remotePort))
                if gated { parked.append(continuation) }
                return gated
            }
            if !shouldPark { continuation.resume() }
        }
        if lock.withLock({ busy.contains(local) }) { throw LeoPortForwardError.portBusy }
        lock.withLock { _ = dead.remove(local) }
    }

    func close(local: Int, remotePort: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldPark = lock.withLock { () -> Bool in
                closeCalls.append((local, remotePort))
                if gatedCloses { parkedCloses.append(continuation) }
                return gatedCloses
            }
            if !shouldPark { continuation.resume() }
        }
    }

    func isOpen(local: Int) -> Bool { lock.withLock { !dead.contains(local) } }
}

@MainActor
struct LeoPortForwardsTests {
    private func forwards(
        runner: FakeForwardRunner = FakeForwardRunner(),
        prober: FakePortProber = FakePortProber(),
        isRemote: Bool = true
    ) -> LeoPortForwards {
        LeoPortForwards(
            planner: LeoPortForwardPlanner(isRemote: isRemote, prober: prober),
            controlPath: "/tmp/cm",
            makeMux: { _ in runner },
            makeProcess: { FakeForwardRunner() }
        )
    }

    private func url(_ string: String) throws -> URL { try #require(URL(string: string)) }

    @Test func acquireOpensTheSamePortWhenFree() async throws {
        let runner = FakeForwardRunner()
        let result = try await forwards(runner: runner).acquire(url("http://localhost:5173/a?b=1"), browser: "alice")
        #expect(result.absoluteString == "http://localhost:5173/a?b=1")
        #expect(runner.opens.map(\.local) == [5173])
        #expect(runner.opens.map(\.remote) == [5173])
    }

    @Test func aBusyPortRetriesOnANewPortAndRewritesBothWays() async throws {
        let runner = FakeForwardRunner(busy: [5173])
        let manager = forwards(runner: runner, prober: FakePortProber(picks: [49_200]))
        let local = try await manager.acquire(url("http://localhost:5173/a#f"), browser: "alice")
        #expect(local.absoluteString == "http://localhost:49200/a#f")
        #expect(runner.opens.map(\.local) == [5173, 49_200])
        #expect(manager.toRemote(local).absoluteString == "http://localhost:5173/a#f")
        #expect(manager.toLocal(try url("http://localhost:5173/x")).absoluteString == "http://localhost:49200/x")
    }

    @Test func givesUpAfterEveryAttemptIsBusy() async throws {
        let target = try url("http://localhost:5173/")
        let runner = FakeForwardRunner(busy: [5173, 49_200, 49_201, 49_202])
        let manager = forwards(runner: runner, prober: FakePortProber(picks: [49_200, 49_201, 49_202, 49_203]))
        await #expect(throws: LeoPortForwardError.portBusy) {
            try await manager.acquire(target, browser: "alice")
        }
        #expect(manager.toLocal(target) == target)
    }

    @Test func nonLoopbackURLsOpenNothing() async throws {
        let runner = FakeForwardRunner()
        let target = try url("http://example.com:5173/")
        #expect(try await forwards(runner: runner).acquire(target, browser: "alice") == target)
        #expect(runner.opens.isEmpty)
    }

    @Test func theLocalMachineOpensNothing() async throws {
        let runner = FakeForwardRunner()
        let target = try url("http://localhost:5173/")
        #expect(try await forwards(runner: runner, isRemote: false).acquire(target, browser: "alice") == target)
        #expect(runner.opens.isEmpty)
    }

    @Test func browsersShareOneForwardAndTheLastReleaseCancelsIt() async throws {
        let runner = FakeForwardRunner()
        let manager = forwards(runner: runner)
        _ = try await manager.acquire(url("http://localhost:5173/"), browser: "alice")
        _ = try await manager.acquire(url("http://localhost:5173/other"), browser: "bob")
        #expect(runner.opens.count == 1)
        await manager.release(browser: "alice")
        #expect(runner.closes.isEmpty)
        await manager.release(browser: "bob")
        #expect(runner.closes.map(\.remote) == [5173])
    }

    @Test func closingABrowserCancelsOnlyItsForwards() async throws {
        let runner = FakeForwardRunner()
        let manager = forwards(runner: runner)
        _ = try await manager.acquire(url("http://localhost:5173/"), browser: "alice")
        _ = try await manager.acquire(url("http://localhost:3000/"), browser: "bob")
        await manager.release(browser: "alice")
        #expect(runner.closes.map(\.remote) == [5173])
        #expect(manager.toLocal(try url("http://localhost:3000/")).absoluteString == "http://localhost:3000/")
    }

    @Test func releasedForwardsNoLongerMap() async throws {
        let manager = forwards(prober: FakePortProber(busy: [5173], picks: [49_200]))
        _ = try await manager.acquire(url("http://localhost:5173/"), browser: "alice")
        await manager.release(browser: "alice")
        #expect(manager.toRemote(try url("http://localhost:49200/")).absoluteString == "http://localhost:49200/")
    }

    @Test func machineDisconnectDropsEveryForward() async throws {
        let runner = FakeForwardRunner()
        let manager = forwards(runner: runner)
        _ = try await manager.acquire(url("http://localhost:5173/"), browser: "alice")
        _ = try await manager.acquire(url("http://localhost:3000/"), browser: "bob")
        await manager.releaseAll().value
        #expect(Set(runner.closes.map(\.remote)) == [5173, 3000])
    }

    @Test func concurrentAcquiresOfOnePortOpenItOnce() async throws {
        let runner = FakeForwardRunner(gated: true)
        let manager = forwards(runner: runner)
        let target = try url("http://localhost:5173/")
        async let first = manager.acquire(target, browser: "alice")
        async let second = manager.acquire(target, browser: "bob")
        while runner.opens.isEmpty { await Task.yield() }
        runner.openGate()
        _ = try await (first, second)
        #expect(runner.opens.count == 1)
    }

    @Test func aForwardWhoseProcessDiedIsReopened() async throws {
        let runner = FakeForwardRunner()
        let manager = forwards(runner: runner)
        _ = try await manager.acquire(url("http://localhost:5173/"), browser: "alice")
        runner.markDead(5173)
        _ = try await manager.acquire(url("http://localhost:5173/"), browser: "alice")
        #expect(runner.opens.count == 2)
    }

    @Test func anOpenThatFinishesAfterDisconnectCleansUpAfterItself() async throws {
        let runner = FakeForwardRunner(gated: true)
        let manager = forwards(runner: runner)
        let target = try url("http://localhost:5173/")
        let pending = Task { try await manager.acquire(target, browser: "alice") }
        while runner.opens.isEmpty { await Task.yield() }
        await manager.releaseAll().value
        runner.openGate()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(runner.closes.map(\.remote) == [5173])
        #expect(manager.toLocal(target) == target)
    }

    @Test func theMuxRunnerIsChosenWithAControlPathAndTheProcessRunnerWithout() async throws {
        let mux = FakeForwardRunner()
        let process = FakeForwardRunner()
        let planner = LeoPortForwardPlanner(isRemote: true, prober: FakePortProber())
        let withMaster = LeoPortForwards(planner: planner, controlPath: "/tmp/cm", makeMux: { _ in mux }, makeProcess: { process })
        let withoutMaster = LeoPortForwards(planner: planner, controlPath: nil, makeMux: { _ in mux }, makeProcess: { process })
        _ = try await withMaster.acquire(url("http://localhost:5173/"), browser: "alice")
        #expect(mux.opens.count == 1 && process.opens.isEmpty)
        _ = try await withoutMaster.acquire(url("http://localhost:3000/"), browser: "alice")
        #expect(mux.opens.count == 1 && process.opens.count == 1)
    }

    // MARK: - Ownership across suspension points

    @Test func releasingABrowserDuringItsPendingOpenCancelsThatAcquire() async throws {
        let runner = FakeForwardRunner(gated: true)
        let manager = forwards(runner: runner)
        let target = try url("http://localhost:5173/")
        let pending = Task { try await manager.acquire(target, browser: "alice") }
        while runner.opens.isEmpty { await Task.yield() }
        await manager.release(browser: "alice")
        runner.openGate()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(runner.closes.map(\.remote) == [5173], "nobody holds the forward, so it must not leak")
        #expect(manager.toLocal(target) == target)
    }

    @Test func releasingOneOfTwoPendingBrowsersKeepsTheForwardForTheOther() async throws {
        let runner = FakeForwardRunner(gated: true)
        let manager = forwards(runner: runner)
        let target = try url("http://localhost:5173/")
        let alice = Task { try await manager.acquire(target, browser: "alice") }
        while runner.opens.isEmpty { await Task.yield() }
        let bob = Task { try await manager.acquire(target, browser: "bob") }
        await Task.yield()
        await manager.release(browser: "alice")
        runner.openGate()
        await #expect(throws: CancellationError.self) { try await alice.value }
        #expect(try await bob.value == target)
        #expect(runner.closes.isEmpty)
        await manager.release(browser: "bob")
        #expect(runner.closes.map(\.remote) == [5173])
    }

    @Test func aForwardAcquiredWhileAnotherBrowsersReleaseIsClosingSurvivesIt() async throws {
        let runner = FakeForwardRunner(gatedCloses: true)
        let manager = forwards(runner: runner)
        _ = try await manager.acquire(url("http://localhost:5173/"), browser: "alice")
        _ = try await manager.acquire(url("http://localhost:3000/"), browser: "alice")
        let releasing = Task { await manager.release(browser: "alice") }
        while runner.closes.isEmpty { await Task.yield() }
        // The release is parked in its first close; its second forward is
        // already out of state, so Bob opens a fresh one rather than joining it.
        let bobURL = try await manager.acquire(url("http://localhost:3000/"), browser: "bob")
        runner.openCloseGate()
        await releasing.value
        #expect(Set(runner.closes.map(\.remote)) == [5173, 3000], "each of alice's forwards closed once")
        #expect(runner.closes.count == 2)
        let bobLocal = try #require(bobURL.port)
        #expect(!runner.closes.map(\.local).contains(bobLocal), "bob's forward was not torn down")
        #expect(manager.toLocal(try url("http://localhost:3000/")) == bobURL)
        #expect(manager.toRemote(bobURL).absoluteString == "http://localhost:3000/")
    }

    @Test func reopeningADeadForwardKeepsItsOtherOwners() async throws {
        let runner = FakeForwardRunner()
        let manager = forwards(runner: runner)
        let target = try url("http://localhost:5173/")
        _ = try await manager.acquire(target, browser: "alice")
        _ = try await manager.acquire(target, browser: "bob")
        runner.markDead(5173)
        _ = try await manager.acquire(target, browser: "bob")
        let closesAfterReopen = runner.closes.count
        await manager.release(browser: "bob")
        #expect(runner.closes.count == closesAfterReopen, "alice still holds the reopened forward")
        #expect(manager.toLocal(target) == target)
        await manager.release(browser: "alice")
        #expect(runner.closes.count == closesAfterReopen + 1)
    }
}
