import Foundation
@testable import Ghostty

// Shared forward-launcher test doubles used by LeoHostRegistryTests and
// LeoSidebarModelTests. Both suites need a fake `ForwardHandle` that can yield a
// canned socket line (keeping its stream open so the forward "stays alive") and
// signal teardown via `onTerminate`, plus a `ForwardLauncher` that builds one.
// Keeping a single non-private definition avoids the two suites drifting apart.

/// A fake `ForwardHandle` whose `lines` stream is supplied by the test and whose
/// `terminate()` invokes an optional `onTerminate` callback so tests can observe
/// teardown.
struct FakeForwardHandle: ForwardHandle {
    let lines: AsyncStream<String>
    let onTerminate: @Sendable () -> Void

    init(lines: AsyncStream<String>, onTerminate: @escaping @Sendable () -> Void = {}) {
        self.lines = lines
        self.onTerminate = onTerminate
    }

    func terminate() { onTerminate() }
}

/// A fake `ForwardLauncher` that defers to a closure to build each handle.
struct FakeForwardLauncher: ForwardLauncher {
    let make: @Sendable ([String]) async -> ForwardHandle
    func launch(args: [String]) async -> ForwardHandle { await make(args) }
}

/// A one-shot async gate shared by the forward suites: `wait()` suspends until
/// `signal()` fires, after which it never blocks again. Lets a test hold a fake
/// forward in "connecting" state and release it at a chosen point.
actor ForwardSignalGate {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Records host names (terminations, invalidations) across isolation domains.
actor HostRecorder {
    private(set) var hosts: [String] = []
    func add(_ host: String) { hosts.append(host) }
    func count(_ host: String) -> Int { hosts.filter { $0 == host }.count }
    var isEmpty: Bool { hosts.isEmpty }
}

/// Hands out and closes the fake forwards' stdout streams so a test can kill a
/// live forward on demand. One stream per launch.
actor ForwardStreamBroker {
    private var continuations: [AsyncStream<String>.Continuation] = []

    /// Build a handle whose stream stays open after yielding `socketLine`.
    func makeHandle(socketLine: String) -> FakeForwardHandle {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        continuations.append(continuation)
        continuation.yield(socketLine)
        return FakeForwardHandle(lines: lines)
    }

    /// End every live stream: the forwards "died".
    func finishAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.finish() }
    }
}
