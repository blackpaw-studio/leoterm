import Foundation

enum LeoActivity: String, Codable, Equatable, Sendable { case working, idle, unknown }

struct LeoCurrentAction: Codable, Equatable, Sendable {
    let kind: String?
    let detail: String?
}

struct LeoObservedAgent: Codable, Equatable, Sendable {
    let name: String
    let status: LeoAgentStatus?
    let activity: LeoActivity?
    let currentAction: LeoCurrentAction?
    let lastActivityAt: String?

    enum CodingKeys: String, CodingKey {
        case name, status, activity
        case currentAction = "current_action"
        case lastActivityAt = "last_activity_at"
    }
}

enum LeoObserveEvent: Equatable, Sendable {
    case hello(seq: Int, at: String?, version: String?, serverTime: String?)
    case agentSpawned(seq: Int, at: String?, agent: LeoAgent)
    case agentStateChanged(seq: Int, at: String?, agent: String, status: LeoAgentStatus?, restarts: Int?, wakeOnMessage: Bool?)
    case agentActivity(seq: Int, at: String?, agent: String, activity: LeoActivity?, currentAction: LeoCurrentAction?)
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

    init(config: LeoObserveConfig, transport: any LeoActivityTransport = LeoURLSessionActivityTransport(), initialBackoff: UInt64 = 1_000_000_000, maximumBackoff: UInt64 = 30_000_000_000) {
        self.config = config
        self.transport = transport
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
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
                        if case .hello = event { backoff = initialBackoff }
                        continuation.yield(event)
                    }
                }
            } catch is CancellationError { break
            } catch { }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: backoff)
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

    private static func decode(_ raw: LeoSSEEvent) -> LeoObserveEvent? {
        guard let name = raw.name, let data = raw.data.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        switch name {
        case "hello":
            struct Payload: Decodable { let seq: Int; let at: String?; let version: String?; let serverTime: String?; enum CodingKeys: String, CodingKey { case seq, at, version; case serverTime = "server_time" } }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .hello(seq: p.seq, at: p.at, version: p.version, serverTime: p.serverTime)
        case "agent_spawned":
            struct Payload: Decodable { let seq: Int; let at: String?; let agent: LeoAgent }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .agentSpawned(seq: p.seq, at: p.at, agent: p.agent)
        case "agent_state_changed":
            struct Payload: Decodable { let seq: Int; let at: String?; let agent: String; let status: LeoAgentStatus?; let restarts: Int?; let wakeOnMessage: Bool?; enum CodingKeys: String, CodingKey { case seq, at, agent, status, restarts; case wakeOnMessage = "wake_on_message" } }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .agentStateChanged(seq: p.seq, at: p.at, agent: p.agent, status: p.status, restarts: p.restarts, wakeOnMessage: p.wakeOnMessage)
        case "agent_activity":
            struct Payload: Decodable { let seq: Int; let at: String?; let agent: String; let activity: LeoActivity?; let currentAction: LeoCurrentAction?; enum CodingKeys: String, CodingKey { case seq, at, agent, activity; case currentAction = "current_action" } }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .agentActivity(seq: p.seq, at: p.at, agent: p.agent, activity: p.activity, currentAction: p.currentAction)
        case "agent_stopped":
            struct Payload: Decodable { let seq: Int; let at: String?; let agent: String; let wakeOnMessage: Bool?; enum CodingKeys: String, CodingKey { case seq, at, agent; case wakeOnMessage = "wake_on_message" } }
            guard let p = try? decoder.decode(Payload.self, from: data) else { return nil }
            return .agentStopped(seq: p.seq, at: p.at, agent: p.agent, wakeOnMessage: p.wakeOnMessage)
        default: return nil
        }
    }
}

private extension LeoObserveEvent {
    var sequence: Int {
        switch self {
        case .hello(let seq, _, _, _), .agentSpawned(let seq, _, _),
             .agentStateChanged(let seq, _, _, _, _, _), .agentActivity(let seq, _, _, _, _),
             .agentStopped(let seq, _, _, _): return seq
        case .gap, .snapshot: return -1
        }
    }
}
