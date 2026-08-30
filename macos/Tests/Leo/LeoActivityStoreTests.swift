import Testing
import Foundation
@testable import Ghostty

private struct NoOpTransport: LeoActivityTransport {
    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        (Data(), 200)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct SingleUpdateTransport: LeoActivityTransport {
    let stateJSON: Data

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        (stateJSON, 200)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        // Finishes immediately with no events, like a connection the daemon
        // closes right away. The client's reconnect loop then backs off for
        // >=1s before retrying, which is well outside this test's short
        // sleep window, so the single initial-state update stays stable to
        // assert against.
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
struct LeoActivityStoreTests {
    @Test func defaultsToUnknownForUnseenAgent() {
        let store = LeoActivityStore(config: nil, transport: NoOpTransport())
        #expect(store.activity(for: "anything") == .unknown)
    }

    @Test func nilConfigNeverConnects() async throws {
        let store = LeoActivityStore(config: nil, transport: NoOpTransport())
        store.start()
        // Give the (no-op) task a chance to run to completion.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.isConnected == false)
        store.stop()
    }

    @Test func startPopulatesActivityFromInitialState() async throws {
        let json = Data(#"{"ok":true,"data":{"agents":[{"name":"olympus","activity":"working"}]}}"#.utf8)
        let config = LeoObserveConfig(baseURL: URL(string: "http://127.0.0.1:8370")!, token: "tok")
        let store = LeoActivityStore(config: config, transport: SingleUpdateTransport(stateJSON: json))

        store.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(store.activity(for: "olympus") == .working)
        #expect(store.activity(for: "someone-else") == .unknown)
        #expect(store.isConnected == true)
        store.stop()
    }

    @Test func stopTearsDownAndResetsConnectedFlag() async throws {
        let json = Data(#"{"ok":true,"data":{"agents":[]}}"#.utf8)
        let config = LeoObserveConfig(baseURL: URL(string: "http://127.0.0.1:8370")!, token: "tok")
        let store = LeoActivityStore(config: config, transport: SingleUpdateTransport(stateJSON: json))

        store.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        store.stop()
        #expect(store.isConnected == false)
    }

    @Test func startIsIdempotent() async throws {
        let store = LeoActivityStore(config: nil, transport: NoOpTransport())
        store.start()
        store.start() // second call should be a no-op, not spawn a second task
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.isConnected == false)
        store.stop()
    }
}
