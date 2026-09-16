import Darwin
import Foundation
import Testing

@testable import Ghostty

/// `FakeHubListener.shutdown()` signals every open connection with
/// `shutdown(fd, SHUT_RDWR)` while its handler may still be mid-`send()`.
/// Without `SO_NOSIGPIPE` on the accepted descriptor, a `send()` racing that
/// signal can raise `SIGPIPE`, whose default disposition kills the whole
/// test process -- not just fail an assertion. An SSE handler, which sends
/// repeatedly for the life of its connection, is the case most likely to hit
/// exactly that race.
struct FakeHubDaemonSIGPIPETests {
    @Test func sseHandlerSurvivesShutdownRacingAnInFlightSendWithoutCrashing() async throws {
        let recorder = CloseRecorder()
        var daemon: FakeHubDaemon? = try FakeHubDaemon(script: .init()) { fd in
            Task { await recorder.record(fd) }
        }
        let path = try #require(daemon?.path)

        let sseClient = try Self.connect(to: path)
        defer { Darwin.close(sseClient) }
        Self.send(sseClient, "GET /events HTTP/1.1\r\nHost: fake\r\n\r\n")

        await awaitCondition(timeout: 5, message: "SSE client never received its response headers") {
            var byte: UInt8 = 0
            return Darwin.recv(sseClient, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
        }

        // Keep the SSE handler busy sending events concurrently with
        // shutdown, to maximize the chance a `send()` lands exactly as
        // `shutdown()` shuts the fd's write side down.
        let controller = daemon?.controller
        let injecting = Task {
            while !Task.isCancelled {
                await controller?.inject(event: ": ping\n\n")
                try? await Task.sleep(nanoseconds: 200_000)
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)

        daemon?.shutdown()
        injecting.cancel()

        // If SIGPIPE were left at its default disposition and delivered
        // during the race above, the test process would already be dead and
        // this line would never run. Reaching it, plus the handler cleanly
        // closing its connection exactly once, is the assertion.
        await awaitCondition(timeout: 5, message: "SSE handler never closed its connection after shutdown") {
            await recorder.count == 1
        }
        #expect(await recorder.maxCloseCountForAnyFD == 1, "The SSE connection's fd was closed more than once")

        daemon = nil
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
