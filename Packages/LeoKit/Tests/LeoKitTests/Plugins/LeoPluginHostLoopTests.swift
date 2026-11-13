import Foundation
import Testing

@testable import LeoKit

/// Runs the helper's loop on a thread against a socketpair, playing the app.
private final class LoopHarness: @unchecked Sendable {
    let appFD: Int32
    private let hostFD: Int32
    private let finished = DispatchSemaphore(value: 0)
    private(set) var exitCode: Int32 = -1

    init() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw LeoPluginWireError.io(errno: errno) }
        appFD = fds[0]
        hostFD = fds[1]
        let host = fds[1]
        Thread.detachNewThread { [self] in
            exitCode = LeoPluginHostLoop.run(fd: host)
            finished.signal()
        }
    }

    // Every call that can block on the socket runs off the cooperative pool (see `offCooperativePool`).
    func send(_ command: LeoPluginHostCommand) async throws {
        let frame = try LeoPluginWire.encode(JSONEncoder().encode(command), limit: LeoPluginWire.maxAppToHostBytes)
        try await writeRaw(frame)
    }

    func writeRaw(_ bytes: Data) async throws {
        try await offCooperativePool { [appFD] in try LeoPluginWire.writeAll(bytes, to: appFD) }
    }

    private func receive() throws -> LeoPluginHostMessage? {
        guard let frame = try LeoPluginWire.readFrame(from: appFD, limit: LeoPluginWire.maxHostToAppBytes) else { return nil }
        return try LeoPluginHostMessage.decode(frame: frame)
    }

    /// Messages up to and including the next handler-done marker.
    func receiveUntilDone() async throws -> [LeoPluginHostRequest] {
        try await offCooperativePool { try self.drainUntilDone() }
    }

    private func drainUntilDone() throws -> [LeoPluginHostRequest] {
        var requests: [LeoPluginHostRequest] = []
        while let message = try receive() {
            switch message {
            case .request(let request): requests.append(request)
            case .handlerDone: return requests
            }
        }
        return requests
    }

    func closeAppEndAndWait() async -> Int32 {
        (try? await offCooperativePool { self.closeAndJoin() }) ?? -1
    }

    private func closeAndJoin() -> Int32 {
        close(appFD)
        _ = finished.wait(timeout: .now() + 5)
        close(hostFD)
        return exitCode
    }
}

struct LeoPluginHostLoopTests {
    private let agent = LeoPluginAgentRef(machine: "local", name: "alfred")

    @Test func loadThenEventRoundTripsARender() async throws {
        let harness = try LoopHarness()
        try await harness.send(.load(source: """
        leo.on("viewOpened", (agent, slot) => leo.render(slot, { type: "Loading" }));
        """))
        #expect(try await harness.receiveUntilDone() == [])
        let slot = LeoPluginSlotID.view(viewID: "pr", agent: agent)
        try await harness.send(.deliver(.viewOpened(agent: agent, slot: slot)))
        let requests = try await harness.receiveUntilDone()
        #expect(requests == [.render(slot: slot, node: try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))]))])
        #expect(await harness.closeAppEndAndWait() == 0)
    }

    @Test func aBundleThatThrowsOnLoadIsReportedAsAHandlerError() async throws {
        let harness = try LoopHarness()
        try await harness.send(.load(source: "throw new Error('boom')"))
        let requests = try await harness.receiveUntilDone()
        guard case .handlerError(let source, let message) = requests.first else {
            Issue.record("expected handlerError, got \(requests)")
            return
        }
        #expect(source == "load")
        #expect(message.contains("boom"))
        #expect(await harness.closeAppEndAndWait() == 0)
    }

    @Test func requestsEmittedByAHandlerArriveBeforeItsDoneMarker() async throws {
        let harness = try LoopHarness()
        try await harness.send(.load(source: "leo.on('agentsChanged', () => { leo.log('info', 'a'); leo.log('info', 'b'); });"))
        _ = try await harness.receiveUntilDone()
        try await harness.send(.deliver(.agentsChanged))
        #expect(try await harness.receiveUntilDone() == [.log(level: "info", message: "a"), .log(level: "info", message: "b")])
        #expect(await harness.closeAppEndAndWait() == 0)
    }

    @Test func theLoopExitsCleanlyWhenTheAppEndCloses() async throws {
        let harness = try LoopHarness()
        #expect(await harness.closeAppEndAndWait() == 0)
    }

    @Test func anOversizedFrameFromTheAppEndsTheLoopWithFailure() async throws {
        let harness = try LoopHarness()
        try await harness.writeRaw(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        #expect(await harness.closeAppEndAndWait() == 1)
    }

    @Test func garbageFromTheAppEndsTheLoopWithFailure() async throws {
        let harness = try LoopHarness()
        try await harness.writeRaw(LeoPluginWire.encode(Data("not json".utf8), limit: 100))
        #expect(await harness.closeAppEndAndWait() == 1)
    }

    @Test func aLargeSlashHeavyMessageIsNotInflatedByEscaping() async throws {
        let harness = try LoopHarness()
        // JSONEncoder escapes "/" by default, which would double this past the cap.
        try await harness.send(.load(source: """
        leo.on('agentsChanged', () => leo.log('info', '/'.repeat(600000)));
        """))
        _ = try await harness.receiveUntilDone()
        try await harness.send(.deliver(.agentsChanged))
        #expect(try await harness.receiveUntilDone() == [.log(level: "info", message: String(repeating: "/", count: 600_000))])
        #expect(await harness.closeAppEndAndWait() == 0)
    }
}
