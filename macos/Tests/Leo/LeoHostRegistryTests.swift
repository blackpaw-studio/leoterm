import Testing
import Foundation
@testable import Ghostty

@MainActor
struct LeoHostRegistryTests {
    /// A launcher that yields one canned socket line, mirroring LeoForwardTests.
    nonisolated private static func socketLauncher(_ socketPath: String) -> FakeForwardLauncher {
        FakeForwardLauncher { _ in
            FakeForwardHandle(lines: AsyncStream { cont in
                cont.yield(#"{"socket":"\#(socketPath)","host":"h","pid":1}"#)
                // stream left open: the forward process stays alive
            })
        }
    }

    /// Build a registry whose seams capture what stores would be created.
    private func makeRegistry(
        socketPath: String = "/tmp/forwarded.sock",
        capture: StoreCapture
    ) -> LeoHostRegistry {
        LeoHostRegistry(
            forwardManagerFactory: { host in
                LeoForwardManager(host: host, launcher: Self.socketLauncher(socketPath))
            },
            storeFactory: { socketPath, host in
                capture.record(socketPath: socketPath, host: host)
                return LeoAgentStore(daemon: MockLeoDaemon())
            }
        )
    }

    @Test func acquiringRemoteStartsForwardAndBuildsStoreWithForwardedSocket() async throws {
        let capture = StoreCapture()
        let registry = makeRegistry(socketPath: "/tmp/dionysus.sock", capture: capture)

        _ = try await registry.store(for: "dionysus")

        #expect(capture.calls.count == 1)
        #expect(capture.calls.first?.socketPath == "/tmp/dionysus.sock")
        #expect(capture.calls.first?.host == "dionysus")
    }

    @Test func acquiringLocalhostBuildsStoreWithNoHostAndNoForward() async throws {
        let capture = StoreCapture()
        let forwardStarted = ForwardFlag()
        let registry = LeoHostRegistry(
            forwardManagerFactory: { host in
                Task { await forwardStarted.set() }
                return LeoForwardManager(host: host, launcher: Self.socketLauncher("/tmp/x.sock"))
            },
            storeFactory: { socketPath, host in
                capture.record(socketPath: socketPath, host: host)
                return LeoAgentStore(daemon: MockLeoDaemon())
            }
        )

        _ = try await registry.store(for: LeoHost.localhostName)

        #expect(await forwardStarted.wasSet == false)
        #expect(capture.calls.count == 1)
        #expect(capture.calls.first?.socketPath == nil)
        #expect(capture.calls.first?.host == nil)
    }

    @Test func acquiringSameRemoteTwiceStartsForwardOnceAndSharesStore() async throws {
        let capture = StoreCapture()
        let registry = makeRegistry(capture: capture)

        let first = try await registry.store(for: "dionysus")
        let second = try await registry.store(for: "dionysus")

        #expect(capture.calls.count == 1)
        #expect(first === second)
    }

    /// Two concurrent acquisitions of the same NEW remote host must coalesce:
    /// the forward-manager factory and the store factory each run exactly once,
    /// both callers receive the same `LeoAgentStore`, and the refcount reflects
    /// both holders (so the forward survives one release and stops on the
    /// second). Uses a deferred socket line so the first acquire is still
    /// suspended in `start()` when the second arrives.
    @Test func concurrentAcquireOfSameRemoteCoalescesOntoOneForwardAndStore() async throws {
        let capture = StoreCapture()
        let factoryCalls = CountBox()
        let terminated = ForwardFlag()
        let registry = LeoHostRegistry(
            forwardManagerFactory: { host in
                // The registry invokes the factory synchronously on the MainActor,
                // so counting here is deterministic (no Task hop to race with).
                MainActor.assumeIsolated { factoryCalls.increment() }
                return LeoForwardManager(host: host, launcher: FakeForwardLauncher { _ in
                    FakeForwardHandle(
                        lines: AsyncStream { cont in
                            Task {
                                await Task.yield()
                                cont.yield(#"{"socket":"/tmp/dionysus.sock","host":"dionysus","pid":1}"#)
                            }
                        },
                        onTerminate: { Task { await terminated.set() } }
                    )
                })
            },
            storeFactory: { socketPath, host in
                capture.record(socketPath: socketPath, host: host)
                return LeoAgentStore(daemon: MockLeoDaemon())
            }
        )

        async let firstStore = registry.store(for: "dionysus")
        async let secondStore = registry.store(for: "dionysus")
        let first = try await firstStore
        let second = try await secondStore

        // Forward + store each built exactly once; both callers share the store.
        #expect(factoryCalls.value == 1)
        #expect(capture.calls.count == 1)
        #expect(first === second)

        // Two holders: releasing once keeps the forward alive.
        registry.release("dionysus")
        await Task.yield()
        #expect(await terminated.wasSet == false)

        // Releasing the second (last) holder tears the forward down.
        registry.release("dionysus")
        try await pollUntil { await terminated.wasSet }
        #expect(await terminated.wasSet == true)
    }

    @Test func releaseAtZeroStopsForwardButNotWhileOtherHolderRemains() async throws {
        let capture = StoreCapture()
        let terminated = ForwardFlag()
        let registry = LeoHostRegistry(
            forwardManagerFactory: { host in
                LeoForwardManager(host: host, launcher: FakeForwardLauncher { _ in
                    FakeForwardHandle(
                        lines: AsyncStream { cont in
                            cont.yield(#"{"socket":"/tmp/dionysus.sock","host":"dionysus","pid":1}"#)
                        },
                        onTerminate: { Task { await terminated.set() } }
                    )
                })
            },
            storeFactory: { socketPath, host in
                capture.record(socketPath: socketPath, host: host)
                return LeoAgentStore(daemon: MockLeoDaemon())
            }
        )

        _ = try await registry.store(for: "dionysus")
        _ = try await registry.store(for: "dionysus")

        // Two holders; releasing one must keep the forward alive.
        registry.release("dionysus")
        await Task.yield()
        #expect(await terminated.wasSet == false)

        // Last holder released -> forward torn down.
        registry.release("dionysus")
        try await pollUntil { await terminated.wasSet }
        #expect(await terminated.wasSet == true)
    }
}

// MARK: - Test doubles

/// Polls an async condition across a few yields so the async teardown Task can
/// run. Records an explicit failure if the condition never becomes true.
@MainActor
private func pollUntil(_ condition: @MainActor () async -> Bool, attempts: Int = 100) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("pollUntil timed out after \(attempts) attempts")
}

/// Captures store-factory invocations. Only ever touched from `@MainActor`
/// `storeFactory` closures, so `@MainActor` isolation suffices.
@MainActor
private final class StoreCapture {
    struct Call { let socketPath: String?; let host: String? }
    private(set) var calls: [Call] = []
    func record(socketPath: String?, host: String?) {
        calls.append(.init(socketPath: socketPath, host: host))
    }
}

/// A boolean flag mutated across isolation boundaries (e.g. set from inside a
/// `ForwardHandle.terminate()` running in actor context). An `actor` keeps it
/// `Sendable` and data-race-free.
private actor ForwardFlag {
    private(set) var wasSet = false
    func set() { wasSet = true }
}

/// A counter incremented from the `@Sendable` forward-manager factory, which
/// the registry invokes synchronously on the MainActor. `@MainActor` isolation
/// makes both the increment (via `assumeIsolated`) and the assertion read
/// deterministic and data-race-free.
@MainActor
private final class CountBox {
    private(set) var value = 0
    func increment() { value += 1 }
}
