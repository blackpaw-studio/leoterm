import Foundation
import OSLog

private let leoActivityClientLogger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

enum LeoActivity: String, Codable, Equatable, Sendable { case working, idle, unknown }

struct LeoCurrentAction: Codable, Equatable, Sendable {
    let kind: String?
    let detail: String?
}

struct LeoObservedAgent: Codable, Equatable, Sendable {
    let name: String
    let host: String?
    let status: LeoAgentStatus?
    let activity: LeoActivity?
    let currentAction: LeoCurrentAction?
    let lastActivityAt: String?
    let attention: LeoAttentionSignal?
    /// When this incarnation started; the same value the agent list
    /// reports, so it identifies which incarnation an entry describes.
    let startedAt: String?

    init(name: String, host: String? = nil, status: LeoAgentStatus?, activity: LeoActivity?,
         currentAction: LeoCurrentAction?, lastActivityAt: String?, attention: LeoAttentionSignal? = nil,
         startedAt: String? = nil) {
        self.name = name
        self.host = host
        self.status = status
        self.activity = activity
        self.currentAction = currentAction
        self.lastActivityAt = lastActivityAt
        self.attention = attention
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, host, status, activity, attention
        case currentAction = "current_action"
        case lastActivityAt = "last_activity_at"
        case startedAt = "started_at"
    }

    /// Hand-written only so a malformed optional `attention` degrades to
    /// "absent" (legacy) instead of failing the whole `/state` payload.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        status = try container.decodeIfPresent(LeoAgentStatus.self, forKey: .status)
        activity = try container.decodeIfPresent(LeoActivity.self, forKey: .activity)
        currentAction = try container.decodeIfPresent(LeoCurrentAction.self, forKey: .currentAction)
        lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt)
        attention = try container.decodeIfPresent(LeoLenientAttention.self, forKey: .attention)?.value
        startedAt = try? container.decodeIfPresent(String.self, forKey: .startedAt)
    }
}

/// Decodes an optional `attention` object without ever failing its parent:
/// a malformed value (missing revision, wrong types) reads as absent.
struct LeoLenientAttention: Decodable, Sendable {
    let value: LeoAttentionSignal?

    init(from decoder: any Decoder) throws {
        value = try? LeoAttentionSignal(from: decoder)
    }
}

/// The daemon's `hello.version` has shipped as both a JSON string
/// (`"0.29.0"`) and a JSON number (`1`, leo >= 0.30) across daemon versions;
/// decode either shape instead of failing the whole `hello` payload (and
/// silently dropping it, since callers use `try?`) on a type mismatch.
struct LeoLenientVersion: Decodable, Equatable, Sendable {
    let stringValue: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
        } else if let int = try? container.decode(Int.self) {
            stringValue = String(int)
        } else {
            let double = try container.decode(Double.self)
            stringValue = String(double)
        }
    }
}

enum LeoObserveEvent: Equatable, Sendable {
    case connected
    case disconnected(reason: String)
    case hello(seq: Int, at: String?, version: String?, serverTime: String?, bootID: String? = nil)
    case agentSpawned(seq: Int, at: String?, agent: LeoAgent, attention: LeoAttentionSignal? = nil)
    case agentStateChanged(seq: Int, at: String?, agent: String, status: LeoAgentStatus?, restarts: Int?, wakeOnMessage: Bool?)
    case agentActivity(
        seq: Int, at: String?, agent: String, activity: LeoActivity?, currentAction: LeoCurrentAction?,
        attention: LeoAttentionSignal? = nil
    )
    case agentStopped(seq: Int, at: String?, agent: String, wakeOnMessage: Bool?)
    case gap(expected: Int, received: Int)
    case snapshot([LeoObservedAgent])
}

protocol LeoActivityTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, Int)
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

struct LeoURLSessionActivityTransport: LeoActivityTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                        continuation.finish(throwing: LeoDaemonError.transport("Observability endpoint returned a non-success status"))
                        return
                    }
                    var data = Data()
                    for try await byte in bytes {
                        data.append(byte)
                        if data.suffix(2).elementsEqual([10, 10]) {
                            continuation.yield(data)
                            data = Data()
                        }
                    }
                    if !data.isEmpty { continuation.yield(data) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor LeoActivityClient {
    private let config: LeoObserveConfig
    private let transport: any LeoActivityTransport
    private let initialBackoff: UInt64
    private let maximumBackoff: UInt64
    private let sleeper: @Sendable (UInt64) async throws -> Void

    init(config: LeoObserveConfig, transport: any LeoActivityTransport = LeoURLSessionActivityTransport(), initialBackoff: UInt64 = 1_000_000_000, maximumBackoff: UInt64 = 30_000_000_000, sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.config = config
        self.transport = transport
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        sleeper = sleep
    }

    func fetchState() async throws -> [LeoObservedAgent] {
        let (data, status) = try await transport.fetch(request("/api/v1/state", accept: nil))
        guard (200..<300).contains(status) else { throw LeoDaemonError.transport("State endpoint returned HTTP \(status)") }
        struct State: Decodable, Sendable { let agents: [LeoObservedAgent] }
        return try LeoDaemonEnvelope<State>.decode(data).value().agents
    }

    func events() -> AsyncStream<LeoObserveEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<LeoObserveEvent>.Continuation) async {
        var backoff = initialBackoff
        var lastSequence: Int?
        while !Task.isCancelled {
            var parser = LeoSSEParser()
            var disconnectionReason = "EOF"
            leoActivityClientLogger.log("activityClient: connecting baseURL=\(self.config.baseURL.absoluteString, privacy: .public)")
            do {
                for try await bytes in transport.stream(request("/api/v1/events", accept: "text/event-stream")) {
                    for raw in parser.feed(bytes) {
                        guard let event = Self.decode(raw) else { continue }
                        let sequence = event.sequence
                        if let lastSequence, sequence > lastSequence + 1 {
                            continuation.yield(.gap(expected: lastSequence + 1, received: sequence))
                            if let agents = try? await fetchState() {
                                continuation.yield(.snapshot(agents))
                            }
                        }
                        lastSequence = sequence
                        if case .hello(let seq, let at, let version, let serverTime, _) = event {
                            backoff = initialBackoff
                            leoActivityClientLogger.log("activityClient: hello seq=\(seq) version=\(version ?? "nil", privacy: .public) serverTime=\(serverTime ?? "nil", privacy: .public) at=\(at ?? "nil", privacy: .public)")
                            continuation.yield(.connected)
                        }
                        continuation.yield(event)
                    }
                }
            } catch is CancellationError { break
            } catch {
                disconnectionReason = Self.reason(for: error)
            }
            guard !Task.isCancelled else { break }
            leoActivityClientLogger.log("activityClient: disconnected reason=\(disconnectionReason, privacy: .public)")
            continuation.yield(.disconnected(reason: disconnectionReason))
            leoActivityClientLogger.log("activityClient: reconnecting backoffNanoseconds=\(backoff)")
            do {
                try await sleeper(backoff)
            } catch is CancellationError {
                return
            } catch {
                continuation.yield(.disconnected(reason: Self.reason(for: error)))
                return
            }
            backoff = min(backoff * 2, maximumBackoff)
        }
        continuation.finish()
    }

    private func request(_ path: String, accept: String?) -> URLRequest {
        var request = URLRequest(url: config.baseURL.appending(path: path))
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        return request
    }

    static func decode(_ raw: LeoSSEEvent) -> LeoObserveEvent? {
        guard let name = raw.name, let data = raw.data.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        switch name {
        case "hello":
            struct Payload: Decodable { let seq: Int; let at: String?; let version: LeoLenientVersion?; let serverTime: String?; let bootID: LeoLenientVersion?; enum CodingKeys: String, CodingKey { case seq, at, version; case serverTime = "server_time"; case bootID = "boot_id" } }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .hello(seq: p.seq, at: p.at, version: p.version?.stringValue, serverTime: p.serverTime, bootID: p.bootID?.stringValue)
        case "agent_spawned":
            struct Nested: Decodable { let attention: LeoLenientAttention? }
            struct Payload: Decodable { let seq: Int; let at: String?; let agent: LeoAgent; let attention: LeoLenientAttention?; let nested: Nested
                enum CodingKeys: String, CodingKey { case seq, at, agent, attention }
                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    seq = try container.decode(Int.self, forKey: .seq)
                    at = try container.decodeIfPresent(String.self, forKey: .at)
                    agent = try container.decode(LeoAgent.self, forKey: .agent)
                    attention = try container.decodeIfPresent(LeoLenientAttention.self, forKey: .attention)
                    nested = try container.decode(Nested.self, forKey: .agent)
                }
            }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .agentSpawned(seq: p.seq, at: p.at, agent: p.agent, attention: p.attention?.value ?? p.nested.attention?.value)
        case "agent_state_changed":
            struct Payload: Decodable { let seq: Int; let at: String?; let agent: String; let status: LeoAgentStatus?; let restarts: Int?; let wakeOnMessage: Bool?; enum CodingKeys: String, CodingKey { case seq, at, agent, status, restarts; case wakeOnMessage = "wake_on_message" } }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .agentStateChanged(seq: p.seq, at: p.at, agent: p.agent, status: p.status, restarts: p.restarts, wakeOnMessage: p.wakeOnMessage)
        case "agent_activity":
            struct Payload: Decodable { let seq: Int; let at: String?; let agent: String; let activity: LeoActivity?; let currentAction: LeoCurrentAction?; let attention: LeoLenientAttention?; enum CodingKeys: String, CodingKey { case seq, at, agent, activity, attention; case currentAction = "current_action" } }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .agentActivity(seq: p.seq, at: p.at, agent: p.agent, activity: p.activity, currentAction: p.currentAction, attention: p.attention?.value)
        case "agent_stopped":
            struct Payload: Decodable { let seq: Int; let at: String?; let agent: String; let wakeOnMessage: Bool?; enum CodingKeys: String, CodingKey { case seq, at, agent; case wakeOnMessage = "wake_on_message" } }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .agentStopped(seq: p.seq, at: p.at, agent: p.agent, wakeOnMessage: p.wakeOnMessage)
        default: return nil
        }
    }

    private static func reason(for error: Error) -> String {
        guard let error = error as? LeoDaemonError else { return String(describing: error) }
        if case .transport(let reason) = error { return reason }
        return String(describing: error)
    }
}

extension LeoObserveEvent {
    var sequence: Int {
        switch self {
        case .hello(let seq, _, _, _, _), .agentSpawned(let seq, _, _, _),
             .agentStateChanged(let seq, _, _, _, _, _), .agentActivity(let seq, _, _, _, _, _),
             .agentStopped(let seq, _, _, _): return seq
        case .connected, .disconnected, .gap, .snapshot: return -1
        }
    }

    /// The optional semantic attention signal an event carries; `nil` for a
    /// legacy daemon and for every event kind that never carries one.
    var attention: LeoAttentionSignal? {
        switch self {
        case .agentActivity(_, _, _, _, _, let attention), .agentSpawned(_, _, _, let attention): attention
        default: nil
        }
    }
}
