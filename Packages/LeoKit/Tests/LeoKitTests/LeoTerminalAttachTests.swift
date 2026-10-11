import Foundation
import Testing

@testable import LeoKit

struct LeoTerminalAttachTests {
    @Test func yieldsOpenedThenOutputAndFinishesWithTheCloseCode() async throws {
        let socket = FakeWebSocket(script: [
            .message(.binary(Data("hello".utf8))),
            .message(.binary(Data(" world".utf8))),
            .fail(LeoTerminalAttachError.closed(code: 1000, reason: "session ended")),
        ])
        var events: [LeoTerminalEvent] = []
        await #expect(throws: LeoTerminalAttachError.closed(code: 1000, reason: "session ended")) {
            for try await event in LeoTerminalAttach.events(socket: socket, clock: SuspendingTestClock()) { events.append(event) }
        }
        #expect(events == [.opened, .output(Data("hello".utf8)), .output(Data(" world".utf8))])
    }

    @Test func answersPingsWithPongsAndSendsNothingElse() async throws {
        let socket = FakeWebSocket(script: [
            .message(.text(#"{"type":"ping"}"#)),
            .message(.text(#"{"type":"error","message":"nope"}"#)),
            .message(.text("not json")),
            .message(.text(#"{"type":"pong"}"#)),
            .fail(LeoTerminalAttachError.closed(code: 1008, reason: "device revoked")),
        ])
        await #expect(throws: LeoTerminalAttachError.closed(code: 1008, reason: "device revoked")) {
            for try await _ in LeoTerminalAttach.events(socket: socket, clock: SuspendingTestClock()) {}
        }
        #expect(socket.sent == [#"{"type":"pong"}"#])
    }

    @Test func aFailedHandshakeYieldsNoOpenedEvent() async throws {
        let socket = FakeWebSocket(openError: LeoTerminalAttachError.rejected(status: 404), script: [])
        var events: [LeoTerminalEvent] = []
        await #expect(throws: LeoTerminalAttachError.rejected(status: 404)) {
            for try await event in LeoTerminalAttach.events(socket: socket, clock: SuspendingTestClock()) { events.append(event) }
        }
        #expect(events.isEmpty)
    }

    @Test func aSilentSocketTimesOutAndIsCancelled() async throws {
        let socket = FakeWebSocket(script: [.hang])
        await #expect(throws: LeoTerminalAttachError.idleTimeout) {
            for try await _ in LeoTerminalAttach.events(socket: socket, clock: ImmediateTestClock()) {}
        }
        #expect(socket.isCancelled)
    }

    @Test func endingTheStreamCancelsTheSocket() async throws {
        let socket = FakeWebSocket(script: [.message(.binary(Data("x".utf8))), .hang])
        for try await event in LeoTerminalAttach.events(socket: socket, clock: SuspendingTestClock()) {
            if case .output = event { break }
        }
        try await waitUntil { socket.isCancelled }
    }

    @Test func buildsTheUpgradeRequestOnThePairedOriginWithCredentials() throws {
        let endpoint = LeoRemoteEndpoint(
            baseURL: URL(string: "https://leo.example.com/")!, token: "tok",
            cfAccess: LeoCFAccessCredentials(clientID: "id.access", clientSecret: "s3cret")
        )
        let request = try LeoTerminalAttach.request(endpoint: endpoint, agent: "apollo dev", cols: 160, rows: 48)

        #expect(request.url?.absoluteString == "wss://leo.example.com/api/v1/agents/apollo%20dev/attach?cols=160&rows=48")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "s3cret")

        let lan = try LeoTerminalAttach.request(
            endpoint: LeoRemoteEndpoint(baseURL: URL(string: "http://10.0.2.5:8370")!, token: "tok"), agent: "a", cols: 80, rows: 24
        )
        #expect(lan.url?.absoluteString == "ws://10.0.2.5:8370/api/v1/agents/a/attach?cols=80&rows=24")
    }

    @Test(arguments: [
        ("https://evil.example.net/attach", false),
        ("wss://evil.example.net/attach", false),
        ("http://leo.example.com/attach", false),
        ("wss://leo.example.com:8443/attach", false),
        ("https://leo.example.com/other", true),
        ("wss://leo.example.com/other", true),
    ])
    func theUpgradeFollowsOnlySameOriginRedirects(target: String, isFollowed: Bool) async throws {
        let origin = URL(string: "wss://leo.example.com/api/v1/agents/a/attach")!
        let redirects = SameOriginRedirects(origin: origin)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: origin)
        defer { task.cancel() }
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!

        let followed = await withCheckedContinuation { continuation in
            redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) {
                continuation.resume(returning: $0)
            }
        }

        #expect((followed != nil) == isFollowed)
        if isFollowed {
            #expect(throws: Never.self) { try redirects.checkNoneRefused() }
        } else {
            #expect(throws: LeoDaemonError.crossOriginRedirect(target)) { try redirects.checkNoneRefused() }
        }
    }
}

// MARK: - Fakes

/// A scripted socket: `open` succeeds (or throws `openError`), then each
/// `receive` plays the next step. `.hang` suspends until cancelled.
final class FakeWebSocket: LeoWebSocket, @unchecked Sendable {
    enum Step {
        case message(LeoWebSocketMessage)
        case fail(any Error)
        case hang
    }

    private let lock = NSLock()
    private let openError: (any Error)?
    private var script: [Step]
    private var sentTexts: [String] = []
    private var cancelled = false
    private var hanging: CheckedContinuation<LeoWebSocketMessage, any Error>?

    init(openError: (any Error)? = nil, script: [Step]) {
        self.openError = openError
        self.script = script
    }

    var sent: [String] { lock.withLock { sentTexts } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func open() async throws {
        if let openError { throw openError }
    }

    func receive() async throws -> LeoWebSocketMessage {
        let step: Step? = lock.withLock { script.isEmpty ? nil : script.removeFirst() }
        switch step {
        case .message(let message): return message
        case .fail(let error): throw error
        case .hang, nil:
            return try await withCheckedThrowingContinuation { continuation in
                let isCancelled = lock.withLock {
                    hanging = continuation
                    return cancelled
                }
                if isCancelled { cancel() }
            }
        }
    }

    func send(text: String) async throws {
        lock.withLock { sentTexts.append(text) }
    }

    func cancel() {
        let continuation = lock.withLock {
            cancelled = true
            defer { hanging = nil }
            return hanging
        }
        continuation?.resume(throwing: CancellationError())
    }
}

/// Never wakes a sleeper: the idle watchdog never fires.
struct SuspendingTestClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

/// Wakes every sleeper at once: the idle watchdog fires immediately.
struct ImmediateTestClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}

/// Polls `condition` across scheduler turns (no wall-clock wait).
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
    #expect(condition())
}
