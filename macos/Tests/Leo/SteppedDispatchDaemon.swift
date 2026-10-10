import Darwin
import Foundation

@testable import Ghostty

/// Serves `GET /state` and one `GET /events` stream like a leo 0.35
/// daemon. The trace's `: step N` comments split it into gates; `open`
/// sends one gate's events and waits until they're written. `/state`
/// answers with the agents and dispatches as of the last opened gate
/// (ended dispatches linger with their terminal status, as the daemon's
/// 60 s window keeps them).
final class SteppedDispatchDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [Int: String]
    private var opened = 0
    private var written = 0
    private var finished = false
    private let gate = DispatchSemaphore(value: 0)

    private let stateBody: @Sendable (Int) -> String

    /// `stateBody` is the whole `/state` response body after the `n`th gate
    /// was written.
    init(trace: String, stateBody: @escaping @Sendable (Int) -> String) throws {
        self.stateBody = stateBody
        var steps: [Int: String] = [:]
        var current: Int?
        for line in trace.components(separatedBy: "\n") {
            if line.hasPrefix(": step "), let step = Int(line.dropFirst(": step ".count)) {
                current = step
                continue
            }
            guard let current else { continue }
            steps[current, default: ""] += line + "\n"
        }
        self.steps = steps
    }

    func open(step: Int) async {
        lock.withLock { opened = step }
        gate.signal()
        await awaitCondition(timeout: 5, message: "step \(step) was never written") { self.lock.withLock { self.written >= step } }
    }

    func finish() {
        lock.withLock { finished = true }
        gate.signal()
    }

    func serve(_ client: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(client, &buffer, buffer.count, 0)
        let request = String(bytes: buffer.prefix(max(0, count)), encoding: .utf8) ?? ""
        if request.hasPrefix("GET /state") {
            respondWithState(client)
        } else if request.hasPrefix("GET /events") {
            streamEvents(client)
        }
    }

    private func respondWithState(_ client: Int32) {
        let body = stateBody(lock.withLock { written })
        write(client, "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        _ = Darwin.shutdown(client, SHUT_WR)
    }

    private func streamEvents(_ client: Int32) {
        write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
        while true {
            gate.wait()
            let (step, done) = lock.withLock { (opened, finished) }
            if done { return }
            guard let chunk = steps[step] else { continue }
            write(client, chunk + "\n")
            lock.withLock { written = step }
        }
    }

    private func write(_ client: Int32, _ text: String) {
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress, data.count, 0) }
    }
}

actor HoldListDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] {
        [LeoAgent(name: "alpha", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running, startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)]
    }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}
