import Darwin
import Foundation
import Testing

@testable import Ghostty

struct LeoUnixSocketTransportTests {
    @Test func deadlineExpiresWhenServerNeverReplies() async throws {
        let server = try UnixSocketTestServer { client in
            _ = recv(client, nil, 0, 0)
            Thread.sleep(forTimeInterval: 1)
        }
        let error = await result(from: server, timeout: 0.3)
        #expect(error == .timeout)
    }

    @Test func deadlineIsAbsoluteWhenServerTricklesBytes() async throws {
        let server = try UnixSocketTestServer { client in
            var byte: UInt8 = 65
            while Darwin.send(client, &byte, 1, 0) > 0 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let error = await result(from: server, timeout: 0.3)
        #expect(error == .timeout)
    }

    @Test func cancellationClosesConnection() async throws {
        let peerObservedClose = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            Thread.sleep(forTimeInterval: 0.2)
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var byte: UInt8 = 65
            if Darwin.send(client, &byte, 1, 0) < 0, errno == EPIPE {
                peerObservedClose.signal()
            }
        }
        let task = Task { () -> Error? in
            do {
                _ = try await LeoUnixSocketTransport().send(request, socketPath: server.path, timeout: 5)
                return nil
            } catch { return error }
        }
        #expect(server.waitForConnection())
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let start = ContinuousClock.now
        let error = await task.value
        #expect(error is CancellationError)
        #expect(start.duration(to: .now) < .milliseconds(400))
        #expect(peerObservedClose.wait(timeout: .now() + 1) == .success)
    }

    private let request = LeoHTTPRequest(method: "GET", path: "/agents/list", body: nil)

    private func result(from server: UnixSocketTestServer, timeout: TimeInterval) async -> LeoDaemonError? {
        let start = ContinuousClock.now
        do {
            _ = try await LeoUnixSocketTransport().send(request, socketPath: server.path, timeout: timeout)
            return nil
        } catch let error as LeoDaemonError {
            #expect(start.duration(to: .now) < .milliseconds(800))
            return error
        } catch {
            return nil
        }
    }
}
