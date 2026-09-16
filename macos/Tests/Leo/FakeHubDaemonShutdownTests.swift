import Darwin
import Foundation
import Testing

@testable import Ghostty

/// `FakeHubDaemon.shutdown()` used to close every accepted fd directly while
/// each connection handler's own `defer` also closed the same fd -- a
/// double-close. Once the OS reused that integer for an unrelated
/// connection, the stale handler's second close could sever the new
/// connection out from under it. `shutdown()` must only signal handlers and
/// wait for them to close their own fd exactly once.
struct FakeHubDaemonShutdownTests {
    @Test func shutdownClosesEachAcceptedConnectionExactlyOnceForIdleAndSSEClients() async throws {
        let recorder = CloseRecorder()
        var daemon: FakeHubDaemon? = try FakeHubDaemon(script: .init()) { fd in
            Task { await recorder.record(fd) }
        }
        weak var weakDaemon = daemon
        let path = try #require(daemon?.path)

        let idleClient = try Self.connect(to: path)
        defer { Darwin.close(idleClient) }
        let sseClient = try Self.connect(to: path)
        defer { Darwin.close(sseClient) }

        // Route sseClient into the long-lived SSE handler so shutdown has to
        // unblock a handler that's parked in its event-polling loop, not
        // just one waiting to read a request.
        Self.send(sseClient, "GET /events HTTP/1.1\r\nHost: fake\r\n\r\n")

        await awaitCondition(timeout: 5, message: "Listener never accepted both test clients") {
            (daemon?.acceptedConnectionCount() ?? 0) >= 2
        }
        await awaitCondition(timeout: 5, message: "SSE client never received its response headers") {
            var byte: UInt8 = 0
            return Darwin.recv(sseClient, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
        }

        daemon?.shutdown()

        await awaitCondition(timeout: 5, message: "Both handlers never closed their connections") {
            await recorder.count == 2
        }
        #expect(await recorder.maxCloseCountForAnyFD == 1, "A connection's fd was closed more than once")

        daemon = nil
        await awaitCondition(timeout: 5, message: "FakeHubDaemon never deinited after shutdown and dropping the last reference") {
            weakDaemon == nil
        }
    }

    private static func connect(to path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, capacity)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return descriptor
    }

    private static func send(_ client: Int32, _ text: String) {
        var data = Data(text.utf8)
        data.withUnsafeBytes { buffer in
            _ = Darwin.send(client, buffer.baseAddress, buffer.count, 0)
        }
    }
}

private actor CloseRecorder {
    private var closeCounts: [Int32: Int] = [:]
    var count: Int { closeCounts.count }
    var maxCloseCountForAnyFD: Int { closeCounts.values.max() ?? 0 }
    func record(_ fd: Int32) { closeCounts[fd, default: 0] += 1 }
}
