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
        let phase = PhaseCounter()
        let release = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            _ = Darwin.recv(client, nil, 0, 0)
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
            _ = headers.withUnsafeBytes { Darwin.send(client, $0.baseAddress, headers.count, 0) }
            _ = release.wait(timeout: .now() + 8)
        }
        defer { release.signal(); #expect(server.waitForHandler()) }
        let task = Task { await streamError(transport: LeoUnixSocketTransport(clock: clock, onIdlePhase: phase.increment), server: server) }
        await awaitCondition(timeout: 5) { phase.count >= 2 }

        clock.advance(seconds: 60)

        #expect(await task.value == .timeout)
    }

    @Test func pingResetsStreamIdleTimeout() async throws {
        let clock = SocketTestClock()
        let phase = PhaseCounter()
        let sendPing = DispatchSemaphore(value: 0)
        let pingSent = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            _ = Darwin.recv(client, nil, 0, 0)
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
            _ = headers.withUnsafeBytes { Darwin.send(client, $0.baseAddress, headers.count, 0) }
            _ = sendPing.wait(timeout: .now() + 5)
            let ping = Data(": ping\n\n".utf8)
            _ = ping.withUnsafeBytes { Darwin.send(client, $0.baseAddress, ping.count, 0) }
            pingSent.signal()
            _ = release.wait(timeout: .now() + 8)
        }
        defer { release.signal(); #expect(server.waitForHandler()) }
        let completion = SocketCompletion()
        let task = Task {
            await completion.finish(streamError(transport: LeoUnixSocketTransport(clock: clock, onIdlePhase: phase.increment), server: server))
        }
        // Phase 1: the deadline computed before headers arrive. Phase 2: the
        // deadline recomputed once headers are consumed, now waiting on the
        // ping -- this is the state we need before advancing the clock.
        await awaitCondition(timeout: 5) { phase.count >= 2 }
        clock.advance(seconds: 59)
        sendPing.signal()
        #expect(pingSent.wait(timeout: .now() + 5) == .success)
        // Phase 3: the deadline reset that happened because the ping was
        // consumed -- i.e. "ping consumed" is exactly this phase transition.
        await awaitCondition(timeout: 5) { phase.count >= 3 }
        clock.advance(seconds: 59)
        for _ in 0..<20 { await Task.yield() }
        #expect(await completion.finished == false)
        clock.advance(seconds: 2)
        await awaitCondition(timeout: 5) { await completion.finished }
        #expect(await completion.value == .timeout)
        task.cancel()
    }

    @Test func concurrentRequestsAllSucceed() async throws {
        let server = try ConcurrentUnixSocketServer { client in
            // `recv(_, nil, 0, 0)` (used elsewhere in this file) returns
            // immediately regardless of readability, so it can't be used
            // here to wait for the request to actually arrive before
            // responding -- under concurrency that races the response
            // against the client's send and can close the socket first.
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = Darwin.recv(client, &buffer, buffer.count, 0)
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".utf8)
            _ = response.withUnsafeBytes { Darwin.send(client, $0.baseAddress, response.count, 0) }
        }
        defer { server.stop() }

        let results = try await withThrowingTaskGroup(of: LeoHTTPResponse.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await LeoUnixSocketTransport().send(self.request, socketPath: server.path, timeout: 5)
                }
            }
            var collected: [LeoHTTPResponse] = []
            for try await response in group { collected.append(response) }
            return collected
        }

        #expect(results.count == 20)
        #expect(results.allSatisfy { $0.status == 200 && $0.body == Data("OK".utf8) })
    }

    @Test func streamCancellationClosesPromptly() async throws {
        let started = DispatchSemaphore(value: 0)
        let peerObservedClose = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = try UnixSocketTestServer { client in
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = Darwin.recv(client, nil, 0, 0)
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
            _ = headers.withUnsafeBytes { Darwin.send(client, $0.baseAddress, headers.count, 0) }
            started.signal()
            var byte: UInt8 = 65
            while Darwin.send(client, &byte, 1, 0) > 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            peerObservedClose.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        defer { release.signal(); #expect(server.waitForHandler()) }

        let task = Task<Void, Never> {
            do {
                for try await _ in LeoUnixSocketTransport().stream(path: "/events", socketPath: server.path) {}
            } catch {}
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = ContinuousClock.now
        task.cancel()
        _ = await task.value
        #expect(start.duration(to: .now) < .milliseconds(200))
        #expect(peerObservedClose.wait(timeout: .now() + 1) == .success)
    }

    @Test func streamCancelBeforeConnectCompletesPromptly() async throws {
        // Regression test for a cancel racing the very start of connect():
        // `NWConnection.cancel()` on a connection that hasn't `start()`ed
        // never delivers `.cancelled`, and `start()` after that is a
        // no-op -- so the old code hung `connect()` forever. `beforeStart`
        // is a test-only seam that lets this cancel deterministically land
        // before `connect()` commits to calling `connection.start()`,
        // instead of relying on winning a scheduling race.
        let release = DispatchSemaphore(value: 0)
        // A cancelled connect() means the client never gets far enough to
        // actually connect(), so unlike the other tests here the server's
        // handler may never run at all -- only release it, don't require
        // it to have been reached.
        let server = try UnixSocketTestServer { _ in _ = release.wait(timeout: .now() + 2) }
        defer { release.signal() }

        let bridge = try LeoNWConnectionBridge(socketPath: server.path)
        let completion = CompletionFlag()
        let start = ContinuousClock.now
        let task = Task<Void, Never> {
            do {
                try await bridge.connect(beforeStart: { bridge.cancel(reason: .task) })
            } catch {}
            await completion.markDone()
        }

        // `Task<Void, Never>.value` is not cancellation-aware and a plain
        // `await` on it inside a `withTaskGroup` would block that group's
        // implicit teardown-await forever if `connect()` really hung, which
        // would hide the regression this test exists to catch. Polling a
        // completion flag with `awaitCondition`'s bounded, non-blocking
        // wait avoids that: on a hang this records an Issue and returns,
        // orphaning `task` rather than joining it.
        await awaitCondition(timeout: 0.2, message: "connect() did not return after a cancel raced its start") {
            await completion.isDone
        }
        if await completion.isDone {
            #expect(start.duration(to: .now) < .milliseconds(200))
        } else {
            task.cancel()
        }
    }

    private actor CompletionFlag {
        private(set) var isDone = false
        func markDone() { isDone = true }
    }

    @Test func streamDoesNotHalfCloseSoServerKeepsSendingEvents() async throws {
        // Regression test: the client must never send a FIN after its
        // request. Go's net/http starts a background read of a bodyless
        // GET's (nonexistent) request body; a FIN there reads as EOF,
        // which cancels the request context and ends the daemon's /events
        // SSE handler immediately. This fake server plays the same role:
        // after every send it peeks (non-blocking) for a zero-length read
        // -- a client FIN -- and bails out early if it sees one, exactly
        // as the real handler would.
        let release = DispatchSemaphore(value: 0)
        let eventCount = 3
        let server = try UnixSocketTestServer { client in
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = Darwin.recv(client, &buffer, buffer.count, 0)
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
            _ = headers.withUnsafeBytes { Darwin.send(client, $0.baseAddress, headers.count, 0) }
            for _ in 0..<eventCount {
                var probe: UInt8 = 0
                guard Darwin.recv(client, &probe, 1, Int32(MSG_DONTWAIT | MSG_PEEK)) != 0 else { return }
                let event = Data(": ping\n\n".utf8)
                _ = event.withUnsafeBytes { Darwin.send(client, $0.baseAddress, event.count, 0) }
                Thread.sleep(forTimeInterval: 0.02)
            }
            _ = release.wait(timeout: .now() + 2)
        }
        defer { release.signal(); #expect(server.waitForHandler()) }

        let task = Task<Int, Error> {
            var buffer = Data()
            let marker = Data(": ping".utf8)
            for try await chunk in LeoUnixSocketTransport().stream(path: "/events", socketPath: server.path) {
                // Count occurrences in the accumulated buffer, not
                // yielded chunks: three 20ms-apart pings can coalesce into
                // fewer (or more finely split) `Data` values than events
                // sent, depending on how NWConnection batches reads.
                buffer.append(chunk)
                if countOccurrences(of: marker, in: buffer) >= eventCount { break }
            }
            return countOccurrences(of: marker, in: buffer)
        }

        #expect(try await task.value == eventCount)
    }

    @Test func requestSucceedsWhenFinalChunkCoalescesWithConnectionClose() async throws {
        // Regression test: when the server writes the last body bytes and
        // closes the socket immediately (no delay), NWConnection can
        // deliver that final chunk's content together with isComplete ==
        // true in the same receive completion. The bridge must remember
        // that as EOF instead of letting the caller's next receiveChunk
        // issue another `connection.receive`, which NWConnection rejects
        // once the final read has already been delivered. Sweeping the
        // body size lands the final chunk at every phase relative to
        // NWConnection's internal read granularity (observed to coalesce
        // on roughly half of the 100 sweep points locally), since whether
        // the last chunk coalesces with the FIN depends on exactly where
        // the last byte falls.
        let iterationCount = 100
        // Generated per-connection from the index rather than precomputed
        // into a `[Data]` up front, which would retain ~100 x 512 KB (~56
        // MB) for the whole test. `% iterationCount` guards against a
        // stray extra accepted connection (e.g. a leftover retry) indexing
        // past what the test loop expects and crashing the process instead
        // of just failing an assertion.
        func body(forIndex index: Int) -> Data {
            Data(repeating: 0x41, count: 512 * 1024 + (index % iterationCount) * 997)
        }
        let counter = IterationCounter()
        let server = try ConcurrentUnixSocketServer { client in
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.recv(client, &buffer, buffer.count, 0)
            let body = body(forIndex: counter.next())
            var responseHeader = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            responseHeader.append(body)
            let sent = responseHeader.withUnsafeBytes { Darwin.send(client, $0.baseAddress, responseHeader.count, 0) }
            if sent != responseHeader.count {
                Issue.record("short write: sent \(sent) of \(responseHeader.count) bytes")
            }
            _ = Darwin.shutdown(client, SHUT_WR)
        }
        defer { server.stop() }

        for iteration in 0..<iterationCount {
            let response = try await LeoUnixSocketTransport().send(request, socketPath: server.path, timeout: 5)
            #expect(response.status == 200, "iteration \(iteration)")
            #expect(response.body == body(forIndex: iteration), "iteration \(iteration)")
        }
    }

    @Test func secondReceiveChunkAtTheFinalReadInstantReturnsNilInsteadOfErroring() async throws {
        // Proves the fix's actual contract: a `receiveChunk` call that
        // lands at the exact instant NWConnection delivers its one and
        // only final read -- whether that's the caller's own next
        // sequential call, or (as forced here) a second, independent
        // caller racing it -- must see a clean `nil`, not touch
        // `connection.receive` again, and never surface an error.
        //
        // Plain sequential timing couldn't be made to fail this way
        // locally (the sweep test above coalesces content+isComplete on
        // roughly half of 100 trials, and an unpatched bridge's own next
        // sequential `receiveChunk` call still never errored on any of
        // them), so this uses the `onFinalReadObserved` seam to fire a
        // second, racing `receiveChunk` call from a thread already blocked
        // on a semaphore, woken synchronously from inside the exact
        // receive completion that observed `isComplete == true`. That seam
        // fires *after* the fix's `recordFinalReadDelivered()`, so
        // post-fix the racer always takes the "final read already
        // observed" short-circuit -- that IS the behavior under test, not
        // an artifact of the harness. Pre-fix (no such flag exists yet),
        // that same racing call instead reaches a real second
        // `connection.receive`, which reliably reproduced a real `NWError`
        // (`.transport("Socket is not connected")`, matching the
        // production report's intermittent "already delivered final read"
        // / "No message available on STREAM") or, in some runs, a silent
        // hang (the racer's `connection.receive` completion never firing
        // at all) -- which is why this polls with a bound (`awaitCondition`
        // below) instead of awaiting the racer directly.
        var mutableResponse = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".utf8)
        mutableResponse.append(Data("hi".utf8))
        let response = mutableResponse
        for iteration in 0..<30 {
            let server = try UnixSocketTestServer { client in
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = Darwin.recv(client, &buffer, buffer.count, 0)
                _ = response.withUnsafeBytes { Darwin.send(client, $0.baseAddress, response.count, 0) }
                _ = Darwin.shutdown(client, SHUT_WR)
            }
            let bridge = try LeoNWConnectionBridge(socketPath: server.path)
            try await bridge.connect()
            try await bridge.send(LeoHTTPRequest(method: "GET", path: "/x").serialized())

            let semaphore = DispatchSemaphore(value: 0)
            let box = ResultBox()
            // Block on the semaphore from a plain GCD global-queue thread,
            // not a `Task.detached` body: the latter runs on Swift
            // concurrency's small cooperative thread pool, and 30
            // iterations' worth of blocked racer tasks can starve that
            // pool outright, hanging every *other* concurrency task in the
            // process (including the bridge's own continuations) rather
            // than exercising the bridge at all.
            let racerQueue = DispatchQueue.global()
            racerQueue.async {
                semaphore.wait()
                Task { box.set(await Self.receiveResult(bridge)) }
            }

            // Drain chunks until the completion that reports isComplete --
            // the tiny 2-byte body can arrive as either one read with
            // trailing content or, if it isn't coalesced with the FIN this
            // time, a content read followed by a separate content-less
            // final read; either way `onFinalReadObserved` fires exactly
            // once, at whichever read is the final one, which is the
            // instant that matters for this race.
            var first: Result<Data?, Error> = .success(nil)
            let observedFinal = FlagBox()
            // If the drain loop below breaks out on a `.failure` before the
            // seam ever fires, nothing would otherwise signal the
            // semaphore, and the racer's GCD-global-queue thread would
            // block on `semaphore.wait()` forever (one leaked, permanently
            // blocked thread per such iteration).
            defer { if !observedFinal.get() { semaphore.signal() } }
            while !observedFinal.get() {
                first = await Self.receiveResult(bridge, onFinalReadObserved: {
                    observedFinal.set()
                    semaphore.signal()
                })
                if case .failure = first { break }
            }
            // Poll with a bound rather than `await racer.value` directly:
            // an unpatched bridge can leave the racer's extra
            // `connection.receive` completion handler uncalled forever
            // (a silent hang, not just an error), and this test must fail
            // loudly instead of stalling the whole suite when that
            // regresses.
            await awaitCondition(timeout: 3, message: "iteration \(iteration): the racing receiveChunk() never completed") {
                box.get() != nil
            }
            if case .failure(let error) = first {
                Issue.record("iteration \(iteration): the primary receiveChunk must not error, got \(error)")
            }
            switch box.get() {
            case .success(let chunk):
                #expect(chunk == nil, "iteration \(iteration): the racing receiveChunk must see a clean EOF, not touch the connection for more content")
            case .failure(let error):
                Issue.record("iteration \(iteration): the racing receiveChunk must not error, got \(error)")
            case nil:
                break // already recorded by awaitCondition above
            }

            bridge.cancel(reason: .task)
            _ = server.waitForHandler()
        }
    }

    private static func receiveResult(
        _ bridge: LeoNWConnectionBridge, onFinalReadObserved: (@Sendable () -> Void)? = nil
    ) async -> Result<Data?, Error> {
        do {
            return .success(try await bridge.receiveChunk(maxLength: 64 * 1024, onFinalReadObserved: onFinalReadObserved))
        } catch {
            return .failure(error)
        }
    }

    @Test func streamEndsCleanlyWhenServerClosesRightAfterFinalEvent() async throws {
        // Same coalesced-FIN hazard as above, but for the SSE stream path:
        // a clean close right after the last event must end the stream
        // without throwing.
        let eventCount = 5
        var mutablePayload = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
        for index in 0..<eventCount {
            mutablePayload.append(Data(": ping \(index)\n\n".utf8))
        }
        let payload = mutablePayload
        let server = try ConcurrentUnixSocketServer { client in
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.recv(client, &buffer, buffer.count, 0)
            _ = payload.withUnsafeBytes { Darwin.send(client, $0.baseAddress, payload.count, 0) }
            _ = Darwin.shutdown(client, SHUT_WR)
        }
        defer { server.stop() }

        var values: [Data] = []
        for try await value in LeoUnixSocketTransport().stream(path: "/events", socketPath: server.path) {
            values.append(value)
        }

        let combined = values.reduce(into: Data()) { $0.append($1) }
        #expect(countOccurrences(of: Data(": ping".utf8), in: combined) == eventCount)
    }

    @Test func connectionRefusedMapsToTransportError() async throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("leo-test-\(UUID().uuidString).sock").path
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, limit)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(descriptor, 1) == 0)
        Darwin.close(descriptor) // Leaves a stale socket file with no listener -> ECONNREFUSED.
        defer { unlink(path) }

        do {
            _ = try await LeoUnixSocketTransport().send(request, socketPath: path, timeout: 2)
            Issue.record("expected connection refused")
        } catch let error as LeoDaemonError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
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

    private func countOccurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, in: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
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

/// Counts idle-deadline recomputations reported by `LeoUnixSocketTransport`'s
/// `onIdlePhase` hook -- exactly one per received chunk, unlike the injected
/// clock's `now()` call count, which is also incremented by `wait`'s internal
/// poll-timeout retries and so races ahead unpredictably while blocked.
private final class PhaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    var increment: @Sendable () -> Void { { [self] in lock.withLock { value += 1 } } }
}

/// Lock-guarded slot for handing a `Result` back from a detached `Task` to
/// the awaiting test body.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data?, Error>?
    func set(_ result: Result<Data?, Error>) { lock.withLock { value = result } }
    func get() -> Result<Data?, Error>? { lock.withLock { value } }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func get() -> Bool { lock.withLock { value } }
}

/// Hands out sequential indices to the `ConcurrentUnixSocketServer`
/// handler, one per accepted connection, so each of a test's sequential
/// requests gets a distinct precomputed response body.
private final class IterationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// Fake `LeoDaemonClock`: `advance(seconds:)` moves the logical clock
/// forward synchronously (no real sleeping) and immediately wakes any
/// `sleep(until:)` waiter whose deadline that advance has now passed.
private final class SocketTestClock: LeoDaemonClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: UInt64 = 0
    private var waiters: [UUID: (deadline: UInt64, continuation: CheckedContinuation<Void, Error>)] = [:]

    func now() -> UInt64 { lock.withLock { instant } }

    func sleep(until deadline: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if instant >= deadline {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                // `onCancel` fires as soon as the task is (already)
                // cancelled, which can be before this continuation body
                // even runs -- if so, `cancelWaiter` finds nothing to
                // remove and the continuation would otherwise leak
                // forever once registered below.
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = (deadline, continuation)
                lock.unlock()
            }
        }, onCancel: { [weak self] in self?.cancelWaiter(id) })
    }

    func advance(seconds: UInt64) {
        lock.lock()
        instant += seconds * 1_000_000_000
        let ready = waiters.filter { instant >= $0.value.deadline }
        for id in ready.keys { waiters.removeValue(forKey: id) }
        lock.unlock()
        for (_, waiter) in ready { waiter.continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
    }
}

private actor SocketCompletion {
    private(set) var value: LeoDaemonError?
    private(set) var finished = false
    func finish(_ value: LeoDaemonError?) { self.value = value; finished = true }
}
