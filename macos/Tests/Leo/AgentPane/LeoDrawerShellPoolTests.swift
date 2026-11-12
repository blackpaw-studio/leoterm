import Combine
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor
struct LeoDrawerShellPoolTests {
    final class FakeSurface {
        let launch: LeoDrawerShellLaunch
        init(_ launch: LeoDrawerShellLaunch) { self.launch = launch }
    }

    struct Boom: Error {}

    /// A pool whose factory and closer record what happened.
    @MainActor private final class Harness {
        var made: [FakeSurface] = []
        var closed: [FakeSurface] = []
        var failNext = false
        lazy var pool = LeoDrawerShellPool<FakeSurface>(
            make: { [unowned self] launch in
                if failNext { throw Boom() }
                let surface = FakeSurface(launch)
                made.append(surface)
                return surface
            },
            close: { [unowned self] in closed.append($0) })
    }

    private let a = LeoAgentID(host: .local, name: "a")
    private let b = LeoAgentID(host: .local, name: "b")
    private let shell = LeoDrawerShellLaunch.local(workingDirectory: "/w")

    private func running(_ pool: LeoDrawerShellPool<FakeSurface>, _ key: LeoAgentID) -> FakeSurface? {
        if case .running(let surface) = pool.state(for: key) { return surface }
        return nil
    }

    @Test func nothingIsMadeBeforeOpen() {
        let h = Harness()
        _ = h.pool
        #expect(h.made.isEmpty)
        if case .notStarted = h.pool.state(for: a) {} else { Issue.record("expected notStarted") }
    }

    @Test func aSecondOpenReusesTheRunningShell() throws {
        let h = Harness()
        h.pool.open(a, launch: shell)
        let first = try #require(running(h.pool, a))
        h.pool.open(a, launch: shell)
        #expect(h.made.count == 1)
        #expect(running(h.pool, a) === first)
    }

    @Test func switchingAgentsKeepsBothShellsAlive() throws {
        let h = Harness()
        h.pool.open(a, launch: shell)
        h.pool.open(b, launch: shell)
        h.pool.open(a, launch: shell)
        #expect(h.made.count == 2)
        #expect(h.closed.isEmpty)
        #expect(running(h.pool, a) !== running(h.pool, b))
    }

    @Test func closeClosesTheSurfaceOnceAndForgetsTheAgent() throws {
        let h = Harness()
        h.pool.open(a, launch: shell)
        let surface = try #require(running(h.pool, a))
        h.pool.close(a)
        h.pool.close(a)
        #expect(h.closed.count == 1 && h.closed[0] === surface)
        if case .notStarted = h.pool.state(for: a) {} else { Issue.record("expected notStarted") }
    }

    @Test func retainClosesAMovedOrUnlistedAgentOnThatHostOnly() {
        let h = Harness()
        let remote = LeoAgentID(host: .remote("Build"), name: "a")
        h.pool.open(a, launch: shell)
        h.pool.open(b, launch: shell)
        h.pool.open(remote, launch: .remote(command: "ssh"))
        h.pool.retain(on: .local) { $0 == "b" }
        #expect(h.closed.count == 1)
        #expect(running(h.pool, a) == nil)
        #expect(running(h.pool, b) != nil)
        #expect(running(h.pool, remote) != nil)
    }

    @Test func closeAllClosesEveryShellExactlyOnce() {
        let h = Harness()
        h.pool.open(a, launch: shell)
        h.pool.open(b, launch: shell)
        h.pool.closeAll()
        h.pool.closeAll()
        #expect(h.closed.count == 2)
        #expect(running(h.pool, a) == nil && running(h.pool, b) == nil)
    }

    @Test func closeAllOnAHostClosesOnlyItsShells() {
        let h = Harness()
        let remote = LeoAgentID(host: .remote("Build"), name: "r")
        h.pool.open(a, launch: shell)
        h.pool.open(remote, launch: .remote(command: "ssh"))
        h.pool.closeAll(on: .remote("Build"))
        #expect(h.closed.count == 1)
        #expect(running(h.pool, a) != nil)
    }

    @Test func anExitClosesTheSurfaceAndWaitsForARestartThatMakesANewOne() throws {
        let h = Harness()
        h.pool.open(a, launch: shell)
        let first = try #require(running(h.pool, a))
        h.pool.markExited(surface: first, status: 3)
        #expect(h.closed.count == 1)
        guard case .exited(let status) = h.pool.state(for: a) else { Issue.record("expected exited"); return }
        #expect(status == 3)
        h.pool.open(a, launch: shell)
        #expect(h.made.count == 1, "an exited shell waits for Restart")
        h.pool.restart(a, launch: shell)
        let second = try #require(running(h.pool, a))
        #expect(second !== first)
        #expect(h.closed.count == 1, "the exited surface isn't closed twice")
    }

    @Test func anExitWithAnUnknownStatusKeepsNoStatus() throws {
        let h = Harness()
        h.pool.open(a, launch: shell)
        h.pool.markExited(a, status: nil)
        guard case .exited(let status) = h.pool.state(for: a) else { Issue.record("expected exited"); return }
        #expect(status == nil)
    }

    @Test func aSurfaceThatIsNotOursIsIgnored() {
        let h = Harness()
        h.pool.open(a, launch: shell)
        h.pool.markExited(surface: FakeSurface(shell), status: 0)
        #expect(running(h.pool, a) != nil)
    }

    @Test func anUnavailableLaunchMakesNothingAndIsDecidedAgainOnTheNextOpen() {
        let h = Harness()
        h.pool.open(a, launch: .unavailable("old leo"))
        #expect(h.made.isEmpty)
        guard case .unavailable(let message) = h.pool.state(for: a) else { Issue.record("expected unavailable"); return }
        #expect(message == "old leo")
        h.pool.open(a, launch: shell)
        #expect(running(h.pool, a) != nil)
    }

    @Test func aFactoryThrowIsAFailureNotACrashAndRestartRetries() {
        let h = Harness()
        h.failNext = true
        h.pool.open(a, launch: shell)
        guard case .failed = h.pool.state(for: a) else { Issue.record("expected failed"); return }
        h.failNext = false
        h.pool.restart(a, launch: shell)
        #expect(running(h.pool, a) != nil)
    }

    @Test func everyStateChangePublishes() {
        let h = Harness()
        var count = 0
        let token = h.pool.changes.sink { count += 1 }
        h.pool.open(a, launch: shell)
        h.pool.markExited(a, status: 0)
        h.pool.close(a)
        #expect(count == 3)
        token.cancel()
    }

    // MARK: Retention

    private func row(movedTo: String? = nil) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: "a", template: nil, status: .running, activity: .idle, actionDetail: nil, movedTo: movedTo)
    }

    @Test func aListedUnmovedRowKeepsItsShellAMovedOrMissingOneDoesNot() {
        #expect(LeoDrawerShellRetention.keep(row: row()))
        #expect(!LeoDrawerShellRetention.keep(row: row(movedTo: "Build")))
        #expect(!LeoDrawerShellRetention.keep(row: nil))
    }
}
