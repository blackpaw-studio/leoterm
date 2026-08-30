import Foundation
import os

/// Errors surfaced by `LeoActivityClient`'s transport/decode layer.
enum LeoActivityError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case decode(String)
}

/// Abstracts the two network operations `LeoActivityClient` needs, so tests
/// can inject canned responses/streams without a real network stack.
protocol LeoActivityTransport: Sendable {
    /// One-shot GET, returning `(body, HTTP status)`.
    func fetch(_ request: URLRequest) async throws -> (Data, Int)
    /// A streaming GET whose response body is delivered as it arrives.
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

/// Production transport backed by `URLSession`.
struct URLSessionActivityTransport: LeoActivityTransport {
    let session: URLSession
    private static let streamChunkSize = 512

    /// The daemon's SSE heartbeat arrives every ~20s, so `URLSession.shared`'s
    /// default 60s request timeout would happen to work — but only by
    /// accident. Made deliberate and generous here so this only ever trips on
    /// a truly dead stream, not a slow-but-alive one.
    private static let requestTimeout: TimeInterval = 300
    /// The stream is long-lived (runs for the app's lifetime, reconnecting
    /// with backoff on its own), not a bounded download — this just needs to
    /// be "effectively unbounded".
    private static let resourceTimeout: TimeInterval = 60 * 60 * 24 * 365

    /// Defaults to a dedicated session (not `.shared`) configured with the
    /// generous timeouts above; injectable so tests can supply a stub session
    /// or configuration instead.
    init(session: URLSession = Self.makeDefaultSession()) {
        self.session = session
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.finish(throwing: LeoActivityError.httpStatus(http.statusCode))
                        return
                    }
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count >= Self.streamChunkSize {
                            continuation.yield(chunk)
                            chunk = Data()
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Decoded shape of `GET /api/v1/state`'s `data` field (leo v0.19). Only the
/// fields this client needs are modeled; everything else is ignored.
private struct LeoStateResponse: Decodable {
    struct AgentEntry: Decodable {
        let name: String
        let activity: AgentActivity
    }
    let agents: [AgentEntry]
}

/// `agent_activity` SSE event payload.
private struct AgentActivityEventPayload: Decodable {
    let agent: String
    let activity: AgentActivity
}

/// `agent_spawned` SSE event payload.
private struct AgentSpawnedEventPayload: Decodable {
    struct SpawnedAgent: Decodable {
        let name: String
        let activity: AgentActivity
    }
    let agent: SpawnedAgent
}

/// The `agent` field on lifecycle events (`agent_stopped`, `agent_state_changed`)
/// may be either a bare name string or an object with a `name` field (and, for
/// `agent_state_changed`, an optional `status`); tolerate both shapes.
private enum AgentReference: Decodable {
    case name(String)
    case object(name: String, status: String?)

    var name: String {
        switch self {
        case .name(let name), .object(let name, _):
            return name
        }
    }

    /// The lifecycle status carried by an object-shaped reference, if any.
    /// `nil` for the bare-string shape (no status is ever present there).
    var status: String? {
        switch self {
        case .name: return nil
        case .object(_, let status): return status
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .name(name)
            return
        }
        struct Wrapper: Decodable { let name: String; let status: String? }
        let wrapper = try Wrapper(from: decoder)
        self = .object(name: wrapper.name, status: wrapper.status)
    }
}

/// `agent_stopped` / `agent_state_changed` SSE event payload.
private struct AgentLifecycleEventPayload: Decodable {
    let agent: AgentReference
}

/// Streams per-agent activity from the Leo daemon's local observability
/// endpoint: one initial `GET /api/v1/state` fetch, then a live
/// `GET /api/v1/events` SSE subscription with exponential-backoff reconnect.
///
/// A `nil` config (no token, or `web.enabled: false` in `leo.yaml`) makes
/// this a no-op: it logs "unavailable" once and finishes without ever
/// connecting or retrying.
actor LeoActivityClient {
    private let config: LeoObserveConfig?
    private let transport: LeoActivityTransport
    private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-activity-client")

    private static let initialBackoff: TimeInterval = 1
    private static let maxBackoff: TimeInterval = 30
    private static let backoffMultiplier: Double = 2

    init(config: LeoObserveConfig?, transport: LeoActivityTransport) {
        self.config = config
        self.transport = transport
    }

    /// A stream of activity snapshots: the full `[agent name: activity]` map
    /// as of each update. Cancelling consumption of the stream tears down
    /// the underlying network task.
    func activityUpdates() -> AsyncStream<[String: AgentActivity]> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(continuation: AsyncStream<[String: AgentActivity]>.Continuation) async {
        guard let config else {
            logger.debug("leo activity: unavailable (no local observability endpoint configured)")
            continuation.finish()
            return
        }

        let backoff = MutableBox<TimeInterval>(Self.initialBackoff)
        var activity: [String: AgentActivity] = [:]

        while !Task.isCancelled {
            do {
                activity = try await fetchInitialState(config: config)
                continuation.yield(activity)
                activity = try await streamEvents(
                    config: config,
                    initial: activity,
                    continuation: continuation,
                    onHello: { backoff.value = Self.initialBackoff }
                )
            } catch is CancellationError {
                break
            } catch {
                logger.warning("leo activity: stream error \(String(describing: error), privacy: .public); retrying in \(backoff.value, privacy: .public)s")
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: UInt64(backoff.value * 1_000_000_000))
            backoff.value = min(backoff.value * Self.backoffMultiplier, Self.maxBackoff)
        }
        continuation.finish()
    }

    private func fetchInitialState(config: LeoObserveConfig) async throws -> [String: AgentActivity] {
        let request = Self.request(path: "/api/v1/state", config: config, accept: nil)
        let (data, status) = try await transport.fetch(request)
        guard (200..<300).contains(status) else {
            throw LeoActivityError.httpStatus(status)
        }
        let state: LeoStateResponse
        do {
            state = try LeoEnvelope<LeoStateResponse>.decode(data).value()
        } catch {
            throw LeoActivityError.decode(String(describing: error))
        }
        return state.agents.reduce(into: [:]) { result, entry in
            result[entry.name] = entry.activity
        }
    }

    private func streamEvents(
        config: LeoObserveConfig,
        initial: [String: AgentActivity],
        continuation: AsyncStream<[String: AgentActivity]>.Continuation,
        onHello: () -> Void
    ) async throws -> [String: AgentActivity] {
        var activity = initial
        var parser = SSEParser()
        let request = Self.request(path: "/api/v1/events", config: config, accept: "text/event-stream")

        for try await chunk in transport.stream(request) {
            for event in parser.feed(chunk) {
                if event.name == "hello" {
                    onHello()
                    continue
                }
                if let updated = Self.applyEvent(event, to: activity) {
                    activity = updated
                    continuation.yield(activity)
                }
            }
        }
        return activity
    }

    private static func request(path: String, config: LeoObserveConfig, accept: String?) -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        return request
    }

    /// Pure event application: decode `event`'s payload per its name and
    /// return the updated activity map, or `nil` if the event doesn't affect
    /// activity (unrecognized name, or an undecodable payload — logged
    /// nowhere since malformed payloads from a live daemon aren't
    /// actionable, and are ignored so one bad event never wedges the stream).
    ///
    /// NOTE: `agent_stopped` always means "agent is no longer active" and
    /// sets `.unknown`. `agent_state_changed` is a general lifecycle
    /// transition (running/starting/stopped) — it only resets activity to
    /// `.unknown` when its payload's status is `stopped`; any other status
    /// (or a bare-string agent reference with no status at all) leaves the
    /// current activity untouched, since a running/starting transition says
    /// nothing about whether the agent is currently working or idle. If
    /// `agent_state_changed` later grows a payload that also carries an
    /// explicit activity, this should switch to reading it instead.
    private static func applyEvent(
        _ event: SSEEvent,
        to activity: [String: AgentActivity]
    ) -> [String: AgentActivity]? {
        guard let name = event.name else { return nil }
        let data = Data(event.data.utf8)
        let decoder = JSONDecoder()

        switch name {
        case "agent_activity":
            guard let payload = try? decoder.decode(AgentActivityEventPayload.self, from: data) else { return nil }
            var updated = activity
            updated[payload.agent] = payload.activity
            return updated
        case "agent_spawned":
            guard let payload = try? decoder.decode(AgentSpawnedEventPayload.self, from: data) else { return nil }
            var updated = activity
            updated[payload.agent.name] = payload.agent.activity
            return updated
        case "agent_stopped":
            guard let payload = try? decoder.decode(AgentLifecycleEventPayload.self, from: data) else { return nil }
            var updated = activity
            updated[payload.agent.name] = .unknown
            return updated
        case "agent_state_changed":
            guard let payload = try? decoder.decode(AgentLifecycleEventPayload.self, from: data) else { return nil }
            guard payload.agent.status == "stopped" else { return nil }
            var updated = activity
            updated[payload.agent.name] = .unknown
            return updated
        default:
            return nil
        }
    }
}

/// A minimal mutable reference box, used to let a plain (non-`@Sendable`)
/// closure mutate actor-local state across `await` points without tripping
/// Swift's "mutation of captured var" diagnostic for `@Sendable` closures.
private final class MutableBox<T> {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}
