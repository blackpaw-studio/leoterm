import Testing
import Foundation
@testable import Ghostty

@MainActor
struct LeoHostRegistryTests {
    /// A launcher that yields one canned socket line, mirroring LeoForwardTests.
    nonisolated private static func socketLauncher(_ socketPath: String) -> FakeLauncher {
        FakeLauncher { _ in
            FakeHandle(lines: AsyncStream { cont in
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
                forwardStarted.set()
                return LeoForwardManager(host: host, launcher: Self.socketLauncher("/tmp/x.sock"))
            },
            storeFactory: { socketPath, host in
                capture.record(socketPath: socketPath, host: host)
                return LeoAgentStore(daemon: MockLeoDaemon())
            }
        )

        _ = try await registry.store(for: LeoHost.localhostName)

        #expect(forwardStarted.wasSet == false)
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

    @Test func releaseAtZeroStopsForwardButNotWhileOtherHolderRemains() async throws {
        let capture = StoreCapture()
        let terminated = ForwardFlag()
        let registry = LeoHostRegistry(
            forwardManagerFactory: { host in
                LeoForwardManager(host: host, launcher: FakeLauncher { _ in
                    FakeHandle(
                        lines: AsyncStream { cont in
                            cont.yield(#"{"socket":"/tmp/dionysus.sock","host":"dionysus","pid":1}"#)
                        },
                        onTerminate: { terminated.set() }
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
        #expect(terminated.wasSet == false)

        // Last holder released -> forward torn down.
        registry.release("dionysus")
        try await pollUntil { terminated.wasSet }
        #expect(terminated.wasSet == true)
    }
}

// MARK: - Test doubles

/// Polls a condition across a few yields so the async teardown Task can run.
@MainActor
private func pollUntil(_ condition: @MainActor () -> Bool, attempts: Int = 100) async throws {
    for _ in 0..<attempts {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private final class StoreCapture {
    struct Call { let socketPath: String?; let host: String? }
    private(set) var calls: [Call] = []
    func record(socketPath: String?, host: String?) {
        calls.append(.init(socketPath: socketPath, host: host))
    }
}

private final class ForwardFlag {
    private(set) var wasSet = false
    func set() { wasSet = true }
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

private struct FakeLauncher: ForwardLauncher {
    let make: @Sendable ([String]) async -> ForwardHandle
    func launch(args: [String]) async -> ForwardHandle { await make(args) }
}
