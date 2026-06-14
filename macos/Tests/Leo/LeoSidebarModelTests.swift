import Testing
import Foundation
@testable import Ghostty

@MainActor
struct LeoSidebarModelTests {
    /// A launcher that yields one canned socket line, mirroring LeoHostRegistryTests.
    nonisolated private static func socketLauncher(_ socketPath: String) -> FakeForwardLauncher {
        FakeForwardLauncher { _ in
            FakeForwardHandle(lines: AsyncStream { cont in
                cont.yield(#"{"socket":"\#(socketPath)","host":"h","pid":1}"#)
                // stream left open: the forward process stays alive
            })
        }
    }

    /// A launcher whose stream ends with no socket line, so `start()` throws and
    /// the acquire fails.
    nonisolated private static func failingLauncher() -> FakeForwardLauncher {
        FakeForwardLauncher { _ in
            FakeForwardHandle(lines: AsyncStream { cont in cont.finish() })
        }
    }

    /// Build a registry whose store factory records the acquired socket/host and
    /// returns a fresh, identity-distinguishable store each call.
    private func makeRegistry(
        socketPath: String = "/tmp/forwarded.sock",
        capture: ModelStoreCapture,
        launcher: @escaping @Sendable () -> FakeForwardLauncher
    ) -> LeoHostRegistry {
        LeoHostRegistry(
            forwardManagerFactory: { host in
                LeoForwardManager(host: host, launcher: launcher())
            },
            storeFactory: { socketPath, host in
                let store = LeoAgentStore(daemon: MockLeoDaemon())
                capture.record(socketPath: socketPath, host: host, store: store)
                return store
            }
        )
    }

    @Test func setActiveHostSwapsStoreAndTracksActiveHost() async throws {
        let capture = ModelStoreCapture()
        let registry = makeRegistry(
            socketPath: "/tmp/dionysus.sock",
            capture: capture,
            launcher: { Self.socketLauncher("/tmp/dionysus.sock") })
        let model = LeoSidebarModel(registry: registry)

        await model.setActiveHost("dionysus")

        #expect(model.activeHost == "dionysus")
        #expect(capture.calls.count == 1)
        #expect(capture.calls.first?.host == "dionysus")
        #expect(model.store === capture.calls.first?.store)
        #expect(model.activationError == nil)
    }

    @Test func setActiveHostToSameHostDoesNotReAcquire() async throws {
        let capture = ModelStoreCapture()
        let registry = makeRegistry(
            capture: capture,
            launcher: { Self.socketLauncher("/tmp/dionysus.sock") })
        let model = LeoSidebarModel(registry: registry)

        await model.setActiveHost("dionysus")
        let firstStore = model.store
        await model.setActiveHost("dionysus")

        #expect(capture.calls.count == 1)
        #expect(model.activeHost == "dionysus")
        // Re-selecting the same host must not swap the store instance.
        #expect(model.store === firstStore)
    }

    @Test func switchingBetweenRemoteHostsReleasesTheFirst() async throws {
        let capture = ModelStoreCapture()
        let terminated = ForwardTerminatedFlag()
        let registry = LeoHostRegistry(
            forwardManagerFactory: { host in
                LeoForwardManager(host: host, launcher: FakeForwardLauncher { _ in
                    FakeForwardHandle(
                        lines: AsyncStream { cont in
                            cont.yield(#"{"socket":"/tmp/\#(host).sock","host":"\#(host)","pid":1}"#)
                        },
                        onTerminate: { Task { await terminated.add(host) } })
                })
            },
            storeFactory: { socketPath, host in
                let store = LeoAgentStore(daemon: MockLeoDaemon())
                capture.record(socketPath: socketPath, host: host, store: store)
                return store
            })
        let model = LeoSidebarModel(registry: registry)

        await model.setActiveHost("dionysus")
        await model.setActiveHost("helios")

        #expect(model.activeHost == "helios")
        #expect(model.store === capture.calls.last?.store)
        // The first host's forward was released and torn down.
        try await pollUntilModel { await terminated.contains("dionysus") }
        #expect(await terminated.contains("dionysus") == true)
        #expect(await terminated.contains("helios") == false)
    }

    @Test func refreshHostsPopulatesFromCatalog() async throws {
        let json = Data("""
        [{"name":"localhost","default":false,"local":true},
         {"name":"dionysus","ssh":"leo@10.0.2.10","default":true,"local":false}]
        """.utf8)
        let capture = ModelStoreCapture()
        let registry = makeRegistry(capture: capture, launcher: { Self.socketLauncher("/tmp/x.sock") })
        let model = LeoSidebarModel(
            registry: registry,
            catalog: LeoHostCatalog(runner: { _ in json }))

        await model.refreshHosts()

        #expect(model.hosts.count == 2)
        #expect(model.hosts.map(\.name) == ["localhost", "dionysus"])
        #expect(model.hosts[1].isRemote == true)
    }

    @Test func refreshHostsFallsBackToLocalhostWhenCatalogFails() async throws {
        let capture = ModelStoreCapture()
        let registry = makeRegistry(capture: capture, launcher: { Self.socketLauncher("/tmp/x.sock") })
        let model = LeoSidebarModel(
            registry: registry,
            catalog: LeoHostCatalog(runner: { _ throws(LeoError) in throw LeoError.daemonUnreachable }))

        await model.refreshHosts()

        // Old leo binary lacks `host list`: the sidebar must keep a localhost entry.
        #expect(model.hosts.contains(where: { $0.name == LeoHost.localhostName }))
    }

    @Test func hostsStartWithLocalhostEntry() async throws {
        let capture = ModelStoreCapture()
        let registry = makeRegistry(capture: capture, launcher: { Self.socketLauncher("/tmp/x.sock") })
        let model = LeoSidebarModel(registry: registry)

        #expect(model.hosts.map(\.name) == [LeoHost.localhostName])
    }

    @Test func failingAcquireLeavesStoreUnchangedAndSetsActivationError() async throws {
        let capture = ModelStoreCapture()
        let registry = makeRegistry(
            capture: capture,
            launcher: { Self.failingLauncher() })
        let model = LeoSidebarModel(registry: registry)
        let placeholder = model.store

        await model.setActiveHost("dionysus")

        #expect(model.activeHost == LeoHost.localhostName)
        #expect(model.store === placeholder)
        #expect(model.activationError != nil)
    }

    /// Regression: two overlapping retargets where the FIRST-started host ("slow")
    /// resolves its forward LATER than the second ("fast"). The slow acquire is
    /// still suspended in `start()` when the fast acquire completes and becomes
    /// active. The slow acquire must NOT clobber the fast active host; instead it
    /// must release the hold it just acquired so the refcount doesn't leak. Final
    /// state: active host is "fast", the fast store is showing, the slow host's
    /// hold was released exactly once, and the fast hold is still alive (acquired
    /// exactly once, never released).
    @Test func overlappingRetargetsKeepLaterWinnerAndReleaseStaleAcquire() async throws {
        let capture = ModelStoreCapture()
        let terminations = ForwardTerminationCounter()
        // Two gates enforce a deterministic interleaving:
        //  - `slowStarted` fires once the "slow" forward begins, so we only launch
        //    the "fast" retarget after "slow" has registered generation N.
        //  - `fastResolved` fires once the "fast" forward yields its socket, so the
        //    "slow" acquire stays suspended until "fast" has won and become active.
        let slowStarted = SignalGate()
        let fastResolved = SignalGate()
        let registry = LeoHostRegistry(
            forwardManagerFactory: { host in
                let isSlow = host == "slow"
                return LeoForwardManager(host: host, launcher: FakeForwardLauncher { _ in
                    FakeForwardHandle(
                        lines: AsyncStream { cont in
                            Task {
                                if isSlow {
                                    await slowStarted.signal()
                                    // Resolve only AFTER "fast" has fully completed,
                                    // so this acquire resumes behind a newer retarget.
                                    await fastResolved.wait()
                                    cont.yield(#"{"socket":"/tmp/slow.sock","host":"slow","pid":1}"#)
                                } else {
                                    cont.yield(#"{"socket":"/tmp/fast.sock","host":"fast","pid":1}"#)
                                }
                            }
                        },
                        onTerminate: { Task { await terminations.add(host) } })
                })
            },
            storeFactory: { socketPath, host in
                let store = LeoAgentStore(daemon: MockLeoDaemon())
                capture.record(socketPath: socketPath, host: host, store: store)
                return store
            })
        let model = LeoSidebarModel(registry: registry)

        // Call 1 (slow) registers generation N and suspends in `start()`.
        let slow = Task { await model.setActiveHost("slow") }
        await slowStarted.wait()

        // Call 2 (fast) registers generation N+1 and runs to completion, becoming
        // the active host while "slow" is still suspended.
        _ = await model.setActiveHost("fast")
        #expect(model.activeHost == "fast")

        // Release "slow" from its wait; it resumes as a stale winner.
        await fastResolved.signal()
        _ = await slow.value

        // The later winner stands: sidebar still shows "fast", unclobbered.
        #expect(model.activeHost == "fast")
        #expect(model.store === capture.calls.last(where: { $0.host == "fast" })?.store)
        #expect(model.activationError == nil)

        // The stale "slow" acquire released the hold it grabbed — exactly once.
        try await pollUntilModel { await terminations.count("slow") == 1 }
        #expect(await terminations.count("slow") == 1)
        // The fast hold stays alive — acquired once, never released.
        #expect(await terminations.count("fast") == 0)
    }
}

// MARK: - Test doubles

@MainActor
private func pollUntilModel(_ condition: @MainActor () async -> Bool, attempts: Int = 100) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("pollUntilModel timed out after \(attempts) attempts")
}

/// Captures store-factory invocations and the store returned, so tests can
/// assert the model swapped to the right instance.
@MainActor
private final class ModelStoreCapture {
    struct Call { let socketPath: String?; let host: String?; let store: LeoAgentStore }
    private(set) var calls: [Call] = []
    func record(socketPath: String?, host: String?, store: LeoAgentStore) {
        calls.append(.init(socketPath: socketPath, host: host, store: store))
    }
}

/// Records which hosts' forwards have been torn down.
private actor ForwardTerminatedFlag {
    private(set) var hosts: Set<String> = []
    func add(_ host: String) { hosts.insert(host) }
    func contains(_ host: String) -> Bool { hosts.contains(host) }
}

/// Counts forward terminations per host so tests can assert a host's hold was
/// released exactly once (no double-release).
private actor ForwardTerminationCounter {
    private(set) var counts: [String: Int] = [:]
    func add(_ host: String) { counts[host, default: 0] += 1 }
    func count(_ host: String) -> Int { counts[host] ?? 0 }
}

/// A one-shot async gate. `wait()` suspends until `signal()` is called; once
/// signaled it never blocks again. Lets a test impose a deterministic ordering
/// on otherwise-concurrent acquires.
private actor SignalGate {
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
