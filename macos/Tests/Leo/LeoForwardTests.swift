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
    func terminate() {}
}

private struct FakeLauncher: ForwardLauncher {
    let make: @Sendable ([String]) async -> ForwardHandle
    func launch(args: [String]) async -> ForwardHandle { await make(args) }
}
