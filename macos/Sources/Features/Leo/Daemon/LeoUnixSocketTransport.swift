import Foundation

struct LeoUnixSocketTransport: LeoDaemonTransport {
    private let clock: any LeoDaemonClock
    /// Test-only hook invoked exactly once per idle-deadline recomputation
    /// (i.e. once per received chunk, including keep-alive pings), decoupled
    /// from the watchdog's own sleeper task. Lets tests synchronize on "a
    /// chunk was consumed and the deadline was reset" precisely, instead of
    /// racing against the injected clock's `now()` call count.
    private let onIdlePhase: @Sendable () -> Void

    init(clock: any LeoDaemonClock = LeoRealClock(), onIdlePhase: @escaping @Sendable () -> Void = {}) {
        self.clock = clock
        self.onIdlePhase = onIdlePhase
    }

    func stream(path: String, socketPath: String, idleTimeout: TimeInterval = 60) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard FileManager.default.fileExists(atPath: socketPath) else {
                continuation.finish(throwing: LeoDaemonError.socketMissing(path: socketPath))
                return
            }
            let bridge: LeoNWConnectionBridge
            do {
                bridge = try LeoNWConnectionBridge(socketPath: socketPath)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let request = LeoHTTPRequest(method: "GET", path: path).serialized()
            let task = Task.detached(priority: .userInitiated) { [clock, onIdlePhase] in
                do {
                    try await Self.runStream(bridge, wire: request, idleTimeout: idleTimeout, clock: clock, onIdlePhase: onIdlePhase) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in bridge.cancel(reason: .task); task.cancel() }
        }
    }

    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else { throw LeoDaemonError.socketMissing(path: socketPath) }
        let bridge = try LeoNWConnectionBridge(socketPath: socketPath)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Self.runRequest(bridge, wire: request.serialized(), timeout: timeout)
        }, onCancel: { bridge.cancel(reason: .task) })
    }

    private static func runRequest(_ bridge: LeoNWConnectionBridge, wire: Data, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        try await withThrowingTaskGroup(of: LeoHTTPResponse.self) { group in
            group.addTask {
                defer { bridge.cancel(reason: .task) }
                try await bridge.connect()
                try await bridge.send(wire)
                var data = Data()
                while let chunk = try await bridge.receiveChunk(maxLength: 64 * 1024) {
                    data.append(chunk)
                }
                do {
                    return try LeoHTTPResponse.parse(data)
                } catch {
                    // A truncated read can be a genuine malformed response,
                    // or it can be this same request's watchdog cancelling
                    // the connection mid-read (a race between "receive
                    // completed as a clean EOF just before cancel" and "the
                    // watchdog task throws .timeout") -- prefer the
                    // recorded cancel reason so a timeout surfaces as
                    // `.timeout`/`CancellationError`, not a misleading
                    // parse error.
                    if let reason = bridge.recordedCancelReason() {
                        throw reason == .task ? CancellationError() : LeoDaemonError.timeout
                    }
                    throw LeoDaemonError.transport("Incomplete or invalid HTTP response")
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                bridge.cancel(reason: .timeout)
                throw LeoDaemonError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw LeoDaemonError.transport("Request produced no result") }
            return result
        }
    }

    private static func runStream(_ bridge: LeoNWConnectionBridge, wire: Data, idleTimeout: TimeInterval,
                                  clock: any LeoDaemonClock, onIdlePhase: @escaping @Sendable () -> Void,
                                  yield: (Data) -> Void) async throws {
        defer { bridge.cancel(reason: .task) }
        try await bridge.connect()
        // Never half-close: Go's net/http starts a background read on a
        // bodyless GET's request body even though there isn't one, and a
        // FIN here reads as EOF on that body, which cancels the request
        // context and ends the /events SSE handler immediately. The
        // `Connection: close` header already tells the server to close
        // once done; read-to-EOF (below) picks that up without an explicit
        // FIN, which also sidesteps a FIN sent through an SSH `-L` tunnel
        // propagating and truncating a different request multiplexed over
        // the same tunnel.
        try await bridge.send(wire, isFinal: false)
        let watchdog = LeoIdleWatchdog(bridge: bridge, clock: clock)
        defer { watchdog.stop() }
        var pending = Data()
        var headersRead = false
        var chunked = false
        while true {
            onIdlePhase()
            watchdog.reset(idleTimeout: idleTimeout)
            guard let chunk = try await bridge.receiveChunk(maxLength: 16 * 1024) else { return }
            pending.append(chunk)
            if !headersRead {
                guard let separator = pending.range(of: Data("\r\n\r\n".utf8)) else { continue }
                guard let headers = String(bytes: pending[..<separator.lowerBound], encoding: .utf8)?.lowercased() else {
                    throw LeoDaemonError.decoding("HTTP headers are not UTF-8")
                }
                guard headers.hasPrefix("http/1.1 2") || headers.hasPrefix("http/1.0 2") else {
                    throw LeoDaemonError.transport("Events endpoint returned a non-success status")
                }
                chunked = headers.contains("transfer-encoding: chunked")
                pending.removeSubrange(..<separator.upperBound)
                headersRead = true
            }
            if chunked {
                while let chunk = try nextChunk(from: &pending) {
                    if !chunk.data.isEmpty { yield(chunk.data) }
                    if chunk.terminal { return }
                }
            } else if !pending.isEmpty {
                yield(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    private static func nextChunk(from data: inout Data) throws -> (data: Data, terminal: Bool)? {
        let crlf = Data("\r\n".utf8)
        guard let lineEnd = data.range(of: crlf) else { return nil }
        guard let line = String(data: data[..<lineEnd.lowerBound], encoding: .utf8),
              let size = Int(line.split(separator: ";")[0], radix: 16) else { throw LeoDaemonError.decoding("Invalid chunk size") }
        let start = lineEnd.upperBound
        guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex),
              data.distance(from: end, to: data.endIndex) >= 2 else { return nil }
        if size == 0 { data.removeAll(); return (Data(), true) }
        let result = Data(data[start..<end])
        data.removeSubrange(..<data.index(end, offsetBy: 2))
        return (result, false)
    }
}

/// Watchdog for `stream()`'s idle timeout: one sleeper `Task` per idle
/// window rather than a polling loop -- `reset()` cancels any still-running
/// sleeper (a no-op re-arm since `LeoDaemonClock.sleep(until:)` is
/// cancellable) and starts a fresh one for the new deadline, so there are
/// zero wakeups while data is flowing and exactly one outstanding sleep at
/// idle. A monotonic `generation`, bumped under `lock` by every `reset()`/
/// `stop()`, additionally guards the narrow window where a sleeper has
/// already returned from `clock.sleep` (so `Task.cancel()` can no longer
/// stop it) and is about to call `bridge.cancel(.timeout)` just as a chunk
/// arrives and re-arms the deadline -- without the generation check that
/// sleeper would fire a spurious timeout on a connection that's still
/// actively receiving data.
private final class LeoIdleWatchdog: @unchecked Sendable {
    private let bridge: LeoNWConnectionBridge
    private let clock: any LeoDaemonClock
    private let lock = NSLock()
    private var generation = 0
    private var sleeperTask: Task<Void, Never>?

    init(bridge: LeoNWConnectionBridge, clock: any LeoDaemonClock) {
        self.bridge = bridge
        self.clock = clock
    }

    func reset(idleTimeout: TimeInterval) {
        let deadline = clock.now() &+ UInt64(max(idleTimeout, 0) * 1_000_000_000)
        lock.lock()
        generation += 1
        let myGeneration = generation
        let previous = sleeperTask
        let task = Task.detached { [bridge, clock, weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self?.cancelBridgeIfCurrent(myGeneration)
        }
        sleeperTask = task
        lock.unlock()
        previous?.cancel()
    }

    /// Checks the generation and cancels the bridge under the same lock
    /// acquisition (rather than check-then-unlock-then-cancel), closing the
    /// window where a `reset()` lands between the two and this sleeper
    /// fires a spurious timeout anyway. Safe to call `bridge.cancel` while
    /// holding `lock`: it only touches the bridge's own (different) lock,
    /// and NWConnection's state handler never calls back into the
    /// watchdog, so there's no cycle.
    private func cancelBridgeIfCurrent(_ generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        bridge.cancel(reason: .timeout)
    }

    func stop() {
        lock.lock()
        generation += 1
        let task = sleeperTask
        sleeperTask = nil
        lock.unlock()
        task?.cancel()
    }
}
