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
        defer { #expect(server.waitForHandler()) }
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
        defer { #expect(server.waitForHandler()) }
        let error = await result(from: server, timeout: 0.3)
        #expect(error == .timeout)
    }

    @Test func cancellationClosesConnection() async throws {
        let probe = DispatchSemaphore(value: 0)
        let peerObservedClose = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var requestByte: UInt8 = 0
            _ = recv(client, &requestByte, 1, 0)
            _ = probe.wait(timeout: .now() + 1)
            var byte: UInt8 = 65
            let sent = Darwin.send(client, &byte, 1, 0)
            if sent < 0, errno == EPIPE || errno == ECONNRESET {
                peerObservedClose.signal()
            } else if sent >= 0 {
                var responseByte: UInt8 = 0
                if recv(client, &responseByte, 1, 0) == 0 {
                    peerObservedClose.signal()
                }
            }
        }
        let task = Task { () -> Error? in
            do {
                _ = try await LeoUnixSocketTransport().send(request, socketPath: server.path, timeout: 5)
                return nil
            } catch { return error }
        }
        #expect(server.waitForConnection())
        task.cancel()
        let start = ContinuousClock.now
        let error = await task.value
        #expect(error is CancellationError)
        #expect(start.duration(to: .now) < .milliseconds(400))
        probe.signal()
        #expect(peerObservedClose.wait(timeout: .now() + 1) == .success)
        #expect(server.waitForHandler())
    }

    @Test func terminalChunkFinishesWithoutWaitingForSocketClose() async throws {
        let release = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            _ = Darwin.recv(client, nil, 0, 0)
            let response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8)
            _ = response.withUnsafeBytes { Darwin.send(client, $0.baseAddress, response.count, 0) }
            _ = release.wait(timeout: .now() + 2)
        }
        defer { release.signal(); #expect(server.waitForHandler()) }
        var values: [Data] = []

        for try await value in LeoUnixSocketTransport().stream(path: "/events", socketPath: server.path) {
            values.append(value)
        }

        #expect(values == [Data("hello".utf8)])
    }

    @Test func streamIdleTimeoutUsesInjectedClock() async throws {
        let clock = SocketTestClock()
        let server = try UnixSocketTestServer { client in
            _ = Darwin.recv(client, nil, 0, 0)
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
            _ = headers.withUnsafeBytes { Darwin.send(client, $0.baseAddress, headers.count, 0) }
            Thread.sleep(forTimeInterval: 5)
        }
        defer { #expect(server.waitForHandler(timeout: 8)) }
        let task = Task { await streamError(transport: LeoUnixSocketTransport(now: clock.now), server: server) }
        await awaitCondition(timeout: 5) { clock.readCount >= 2 }

        clock.advance(seconds: 60)

        #expect(await task.value == .timeout)
    }

    @Test func pingResetsStreamIdleTimeout() async throws {
        let clock = SocketTestClock()
        let sendPing = DispatchSemaphore(value: 0)
        let pingSent = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            _ = Darwin.recv(client, nil, 0, 0)
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
            _ = headers.withUnsafeBytes { Darwin.send(client, $0.baseAddress, headers.count, 0) }
            _ = sendPing.wait(timeout: .now() + 5)
            let ping = Data(": ping\n\n".utf8)
            _ = ping.withUnsafeBytes { Darwin.send(client, $0.baseAddress, ping.count, 0) }
            pingSent.signal()
            Thread.sleep(forTimeInterval: 5)
        }
        defer { #expect(server.waitForHandler(timeout: 8)) }
        let completion = SocketCompletion()
        let task = Task {
            await completion.finish(streamError(transport: LeoUnixSocketTransport(now: clock.now), server: server))
        }
        await awaitCondition(timeout: 5) { clock.readCount >= 2 }
        clock.advance(seconds: 59)
        sendPing.signal()
        #expect(pingSent.wait(timeout: .now() + 5) == .success)
        await awaitCondition(timeout: 5) { clock.readCount >= 3 }
        clock.advance(seconds: 59)
        for _ in 0..<20 { await Task.yield() }
        #expect(await completion.finished == false)
        clock.advance(seconds: 2)
        await awaitCondition(timeout: 5) { await completion.finished }
        #expect(await completion.value == .timeout)
        task.cancel()
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

    private func streamError(transport: LeoUnixSocketTransport, server: UnixSocketTestServer) async -> LeoDaemonError? {
        do {
            for try await _ in transport.stream(path: "/events", socketPath: server.path) {}
            return nil
        } catch let error as LeoDaemonError {
            return error
        } catch {
            return nil
        }
    }
}

private final class SocketTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: UInt64 = 0
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    var now: @Sendable () -> UInt64 { { [self] in lock.withLock { reads += 1; return instant } } }
    func advance(seconds: UInt64) { lock.withLock { instant += seconds * 1_000_000_000 } }
}

private actor SocketCompletion {
    private(set) var value: LeoDaemonError?
    private(set) var finished = false
    func finish(_ value: LeoDaemonError?) { self.value = value; finished = true }
}
