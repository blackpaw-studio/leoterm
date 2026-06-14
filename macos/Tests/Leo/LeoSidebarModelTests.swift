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

private struct FakeForwardHandle: ForwardHandle {
    let lines: AsyncStream<String>
    let onTerminate: @Sendable () -> Void
    init(lines: AsyncStream<String>, onTerminate: @escaping @Sendable () -> Void = {}) {
        self.lines = lines
        self.onTerminate = onTerminate
    }
    func terminate() { onTerminate() }
}

private struct FakeForwardLauncher: ForwardLauncher {
    let make: @Sendable ([String]) async -> ForwardHandle
    func launch(args: [String]) async -> ForwardHandle { await make(args) }
}
