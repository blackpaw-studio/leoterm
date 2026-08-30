import Testing
import Foundation
@testable import Ghostty

struct LeoForwardTests {
    @Test func parsesSocketPathFromJSONLine() {
        let line = #"{"socket":"/Users/evan/.leo/state/remotes/dionysus.sock","host":"dionysus","pid":4321}"#
        #expect(LeoForwardManager.parseSocketPath(jsonLine: line) == "/Users/evan/.leo/state/remotes/dionysus.sock")
    }

    @Test func parseSocketPathReturnsNilForNonJSONLine() {
        #expect(LeoForwardManager.parseSocketPath(jsonLine: "starting forward to dionysus...") == nil)
    }

    @Test func parseSocketPathReturnsNilWhenSocketMissing() {
        #expect(LeoForwardManager.parseSocketPath(jsonLine: #"{"host":"dionysus","pid":0}"#) == nil)
    }

    @Test func forwardArgsIncludeHostAndJSON() {
        #expect(LeoForwardManager.forwardArgs(host: "dionysus") == ["host", "forward", "dionysus", "--json"])
    }

    @Test func stopArgsRequestTeardown() {
        #expect(LeoForwardManager.stopArgs(host: "dionysus") == ["host", "forward", "dionysus", "--stop"])
    }

    // MARK: - Lifecycle (with a fake launcher)

    @Test func startResolvesSocketPathFromFirstSocketLine() async throws {
        let socketLine = #"{"socket":"/tmp/dionysus.sock","host":"dionysus","pid":1}"#
        let launcher = FakeLauncher { _ in
            FakeHandle(lines: AsyncStream { cont in
                cont.yield("connecting to dionysus...")
                cont.yield(socketLine)
                // stream left open: the forward process stays alive
            })
        }
        let manager = LeoForwardManager(host: "dionysus", launcher: launcher)
        let path = try await manager.start()
        #expect(path == "/tmp/dionysus.sock")
    }

    @Test func startThrowsWhenProcessExitsBeforeSocketLine() async {
        let launcher = FakeLauncher { _ in
            FakeHandle(lines: AsyncStream { cont in
                cont.yield("error: unknown host")
                cont.finish() // process exited without ever printing a socket
            })
        }
        let manager = LeoForwardManager(host: "bad", launcher: launcher)
        await #expect(throws: LeoError.self) {
            _ = try await manager.start()
        }
    }

    // MARK: - Timeout, re-entry and health monitoring

    /// A forward that never prints a socket line (unreachable host, an ssh
    /// prompt) must not suspend `start()` forever: the wait is bounded and the
    /// process is torn down.
    @Test func startTimesOutWhenNoSocketLineEverArrives() async throws {
        let terminated = ForwardSignalGate()
        let launcher = FakeLauncher { _ in
            FakeHandle(
                lines: AsyncStream { _ in }, // open forever, never yields
                onTerminate: { Task { await terminated.signal() } })
        }
        let manager = LeoForwardManager(
            host: "unreachable", launcher: launcher, startTimeout: .milliseconds(50))

        await #expect(throws: LeoError.self) { _ = try await manager.start() }
        await terminated.wait() // the hung process was terminated
    }

    /// A second `start()` on a live forward must reuse it rather than spawning a
    /// second `leo host forward` and orphaning the first.
    @Test func secondStartReusesRunningForwardWithoutRelaunching() async throws {
        let launches = LaunchCounter()
        let launcher = FakeLauncher { _ in
            await launches.increment()
            return FakeHandle(lines: AsyncStream { cont in
                cont.yield(#"{"socket":"/tmp/dionysus.sock","host":"dionysus","pid":1}"#)
            })
        }
        let manager = LeoForwardManager(host: "dionysus", launcher: launcher)

        let first = try await manager.start()
        let second = try await manager.start()

        #expect(first == second)
        #expect(await launches.value == 1)
    }

    /// A healthy forward that later dies (ssh drop, remote reboot) must notify
    /// its owner so the cached socket path isn't served forever.
    @Test func terminationHandlerFiresWhenHealthyForwardDies() async throws {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let launcher = FakeLauncher { _ in FakeHandle(lines: lines) }
        let manager = LeoForwardManager(host: "dionysus", launcher: launcher)
        let died = HostRecorder()
        await manager.setTerminationHandler { host in Task { await died.add(host) } }

        continuation.yield(#"{"socket":"/tmp/dionysus.sock","host":"dionysus","pid":1}"#)
        _ = try await manager.start()
        continuation.finish() // the forward process exits underneath us

        try await pollUntilForward { await died.count("dionysus") == 1 }
    }

    /// A cancelled caller must fail fast rather than deadlocking: with the
    /// enclosing task cancelled `Task.sleep` returns immediately, so the timeout
    /// branch wins the start race before the socket branch can register.
    @Test func startFailsPromptlyWhenTheEnclosingTaskIsCancelled() async throws {
        let launcher = FakeLauncher { _ in
            FakeHandle(lines: AsyncStream { _ in }) // never yields, never ends
        }
        let manager = LeoForwardManager(
            host: "dionysus", launcher: launcher, startTimeout: .seconds(600))

        let task = Task { try await manager.start() }
        task.cancel()

        await #expect(throws: LeoError.self) { _ = try await task.value }
    }

    /// A deliberate `stop()` is not a failure: it must not report the forward as
    /// having died.
    @Test func terminationHandlerNotCalledOnDeliberateStop() async throws {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let launcher = FakeLauncher { _ in
            FakeHandle(lines: lines, onTerminate: { continuation.finish() })
        }
        let manager = LeoForwardManager(host: "dionysus", launcher: launcher)
        let died = HostRecorder()
        await manager.setTerminationHandler { host in Task { await died.add(host) } }

        continuation.yield(#"{"socket":"/tmp/dionysus.sock","host":"dionysus","pid":1}"#)
        _ = try await manager.start()
        await manager.stop()

        // The stream ends as a result of the stop; wait for the monitor to have
        // observed it rather than sleeping on a guess.
        try await pollUntilForward { await manager.isIdle }
        #expect(await died.isEmpty)
    }

    @Test func startPassesForwardArgsToLauncher() async throws {
        let recorder = ArgRecorder()
        let launcher = FakeLauncher { args in
            await recorder.record(args)
            return FakeHandle(lines: AsyncStream { cont in
                cont.yield(#"{"socket":"/tmp/x.sock","host":"dionysus","pid":1}"#)
            })
        }
        _ = try await LeoForwardManager(host: "dionysus", launcher: launcher).start()
        #expect(await recorder.args == ["host", "forward", "dionysus", "--json"])
    }
}

// MARK: - Test doubles

private actor ArgRecorder {
    private(set) var args: [String] = []
    func record(_ args: [String]) { self.args = args }
}

private struct FakeHandle: ForwardHandle {
    let lines: AsyncStream<String>
    let onTerminate: @Sendable () -> Void

    init(lines: AsyncStream<String>, onTerminate: @escaping @Sendable () -> Void = {}) {
        self.lines = lines
        self.onTerminate = onTerminate
    }

    func terminate() { onTerminate() }
}

private actor LaunchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Polls an async condition, failing the test if it never becomes true.
private func pollUntilForward(_ condition: () async -> Bool, attempts: Int = 200) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("pollUntilForward timed out after \(attempts) attempts")
}

private struct FakeLauncher: ForwardLauncher {
    let make: @Sendable ([String]) async -> ForwardHandle
    func launch(args: [String]) async -> ForwardHandle { await make(args) }
}
