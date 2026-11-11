import Foundation
import Testing

@testable import LeoKit

/// Runs the helper's loop on a thread against a socketpair, playing the app.
private final class LoopHarness {
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

    func send(_ command: LeoPluginHostCommand) throws {
        let frame = try LeoPluginWire.encode(JSONEncoder().encode(command), limit: LeoPluginWire.maxAppToHostBytes)
        try LeoPluginWire.writeAll(frame, to: appFD)
    }

    func receive() throws -> LeoPluginHostMessage? {
        guard let frame = try LeoPluginWire.readFrame(from: appFD, limit: LeoPluginWire.maxHostToAppBytes) else { return nil }
        return try LeoPluginHostMessage.decode(frame: frame)
    }

    /// Messages up to and including the next handler-done marker.
    func receiveUntilDone() throws -> [LeoPluginHostRequest] {
        var requests: [LeoPluginHostRequest] = []
        while let message = try receive() {
            switch message {
            case .request(let request): requests.append(request)
            case .handlerDone: return requests
            }
        }
        return requests
    }

    func closeAppEndAndWait() -> Int32 {
        close(appFD)
        _ = finished.wait(timeout: .now() + 5)
        close(hostFD)
        return exitCode
    }
}

struct LeoPluginHostLoopTests {
    private let agent = LeoPluginAgentRef(machine: "local", name: "alfred")

    @Test func loadThenEventRoundTripsARender() throws {
        let harness = try LoopHarness()
        try harness.send(.load(source: """
        leo.on("viewOpened", (agent, slot) => leo.render(slot, { type: "Loading" }));
        """))
        #expect(try harness.receiveUntilDone() == [])
        let slot = LeoPluginSlotID.view(viewID: "pr", agent: agent)
        try harness.send(.deliver(.viewOpened(agent: agent, slot: slot)))
        let requests = try harness.receiveUntilDone()
        #expect(requests == [.render(slot: slot, node: try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))]))])
        #expect(harness.closeAppEndAndWait() == 0)
    }

    @Test func aBundleThatThrowsOnLoadIsReportedAsAHandlerError() throws {
        let harness = try LoopHarness()
        try harness.send(.load(source: "throw new Error('boom')"))
        let requests = try harness.receiveUntilDone()
        guard case .handlerError(let source, let message) = requests.first else {
            Issue.record("expected handlerError, got \(requests)")
            return
        }
        #expect(source == "load")
        #expect(message.contains("boom"))
        #expect(harness.closeAppEndAndWait() == 0)
    }

    @Test func requestsEmittedByAHandlerArriveBeforeItsDoneMarker() throws {
        let harness = try LoopHarness()
        try harness.send(.load(source: "leo.on('agentsChanged', () => { leo.log('info', 'a'); leo.log('info', 'b'); });"))
        _ = try harness.receiveUntilDone()
        try harness.send(.deliver(.agentsChanged))
        #expect(try harness.receiveUntilDone() == [.log(level: "info", message: "a"), .log(level: "info", message: "b")])
        #expect(harness.closeAppEndAndWait() == 0)
    }

    @Test func theLoopExitsCleanlyWhenTheAppEndCloses() throws {
        let harness = try LoopHarness()
        #expect(harness.closeAppEndAndWait() == 0)
    }

    @Test func anOversizedFrameFromTheAppEndsTheLoopWithFailure() throws {
        let harness = try LoopHarness()
        try LeoPluginWire.writeAll(Data([0x7F, 0xFF, 0xFF, 0xFF]), to: harness.appFD)
        #expect(harness.closeAppEndAndWait() == 1)
    }

    @Test func garbageFromTheAppEndsTheLoopWithFailure() throws {
        let harness = try LoopHarness()
        try LeoPluginWire.writeAll(LeoPluginWire.encode(Data("not json".utf8), limit: 100), to: harness.appFD)
        #expect(harness.closeAppEndAndWait() == 1)
    }

    @Test func aLargeSlashHeavyMessageIsNotInflatedByEscaping() throws {
        let harness = try LoopHarness()
        // JSONEncoder escapes "/" by default, which would double this past the cap.
        try harness.send(.load(source: """
        leo.on('agentsChanged', () => leo.log('info', '/'.repeat(600000)));
        """))
        _ = try harness.receiveUntilDone()
        try harness.send(.deliver(.agentsChanged))
        #expect(try harness.receiveUntilDone() == [.log(level: "info", message: String(repeating: "/", count: 600_000))])
        #expect(harness.closeAppEndAndWait() == 0)
    }
}
