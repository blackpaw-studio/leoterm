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

    // MARK: - Cancellation, deferred release and forward death

    /// Build a registry whose forward only yields its socket after `gate`
    /// fires, so the test controls exactly when the acquisition lands.
    private func makeGatedRegistry(
        gate: ForwardSignalGate,
        launched: ForwardSignalGate,
        terminated: HostRecorder
    ) -> LeoHostRegistry {
        LeoHostRegistry(
            forwardManagerFactory: { host in
                LeoForwardManager(host: host, launcher: FakeForwardLauncher { _ in
                    FakeForwardHandle(
                        lines: AsyncStream { cont in
                            Task {
                                await launched.signal()
                                await gate.wait()
                                cont.yield(#"{"socket":"/tmp/\#(host).sock","host":"\#(host)","pid":1}"#)
                            }
                        },
                        onTerminate: { Task { await terminated.add(host) } })
                })
            },
            storeFactory: { _, _ in LeoAgentStore(daemon: MockLeoDaemon()) })
    }

    /// The sole acquirer being cancelled mid-acquire must not leave a live
    /// forward behind with a refCount-0 connection nobody will ever release.
    @Test func cancelledAcquirerTearsDownTheConnectionItNeverClaimed() async throws {
        let gate = ForwardSignalGate()
        let launched = ForwardSignalGate()
        let terminated = HostRecorder()
        let registry = makeGatedRegistry(gate: gate, launched: launched, terminated: terminated)

        let acquire = Task { @MainActor in try? await registry.store(for: "dionysus") }
        await launched.wait()
        acquire.cancel()
        await gate.signal()
        _ = await acquire.value

        try await pollUntil { await terminated.count("dionysus") == 1 }
        #expect(registry.hasConnection("dionysus") == false)
    }

    /// A release that arrives while the acquisition is still in flight must not
    /// be lost: it applies once the connection lands, tearing it down.
    @Test func releaseDuringInFlightAcquireAppliesWhenItLands() async throws {
        let gate = ForwardSignalGate()
        let launched = ForwardSignalGate()
        let terminated = HostRecorder()
        let registry = makeGatedRegistry(gate: gate, launched: launched, terminated: terminated)

        async let acquired = registry.store(for: "dionysus")
        await launched.wait()
        registry.release("dionysus") // the holder went away mid-acquire
        await gate.signal()
        _ = try await acquired

        try await pollUntil { await terminated.count("dionysus") == 1 }
        #expect(registry.hasConnection("dionysus") == false)
    }

    /// A forward that dies on its own invalidates the cached connection so the
    /// next acquire rebuilds it instead of serving a dead socket path.
    @Test func forwardDeathInvalidatesCachedConnection() async throws {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let storeCalls = CountBox()
        let registry = LeoHostRegistry(
            forwardManagerFactory: { host in
                LeoForwardManager(host: host, launcher: FakeForwardLauncher { _ in
                    FakeForwardHandle(lines: lines)
                })
            },
            storeFactory: { _, _ in
                MainActor.assumeIsolated { storeCalls.increment() }
                return LeoAgentStore(daemon: MockLeoDaemon())
            })

        continuation.yield(#"{"socket":"/tmp/dionysus.sock","host":"dionysus","pid":1}"#)
        _ = try await registry.store(for: "dionysus")
        #expect(registry.hasConnection("dionysus") == true)

        continuation.finish() // ssh dropped

        try await pollUntil { registry.hasConnection("dionysus") == false }
        #expect(storeCalls.value == 1)
    }

    /// Regression: after a forward dies, the stale holder's late `release` must
    /// be absorbed rather than decrementing the replacement connection (which
    /// would tear down a forward somebody else is using).
    @Test func staleReleaseAfterInvalidationDoesNotTouchTheReplacement() async throws {
        let streams = ForwardStreamBroker()
        let registry = LeoHostRegistry(
            forwardManagerFactory: { host in
                LeoForwardManager(host: host, launcher: FakeForwardLauncher { _ in
                    await streams.makeHandle(
                        socketLine: #"{"socket":"/tmp/\#(host).sock","host":"\#(host)","pid":1}"#)
                })
            },
            storeFactory: { _, _ in LeoAgentStore(daemon: MockLeoDaemon()) })

        let first = try await registry.store(for: "dionysus")
        await streams.finishAll() // the forward dies under the holder
        try await pollUntil { registry.hasConnection("dionysus") == false }

        let second = try await registry.store(for: "dionysus")
        #expect(first !== second)

        // The stale holder finally lets go: the replacement must survive.
        registry.release("dionysus")
        #expect(registry.hasConnection("dionysus") == true)

        // The live holder's release still tears the replacement down.
        registry.release("dionysus")
        #expect(registry.hasConnection("dionysus") == false)
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
