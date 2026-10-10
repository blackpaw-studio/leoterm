import Foundation

protocol LeoDaemonClient: Sendable {
    func listAgents() async throws -> [LeoAgent]
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent
    func start(_ name: String) async throws
    func stop(_ name: String, wakeOnMessage: Bool?) async throws
    func restart(_ name: String) async throws -> LeoAgent
    func reset(_ name: String) async throws
    func setTemplate(_ name: String, template: String) async throws
    func rename(_ name: String, newName: String) async throws -> LeoAgent
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws
    func deletePlan(_ name: String) async throws -> LeoDeletePlan
    func logs(_ name: String, lines: Int?) async throws -> String
    func templates() async throws -> [LeoTemplate]
    func templates(host: LeoHostID) async throws -> [LeoTemplate]
    func version() async throws -> String
    func listAgents(host: LeoHostID) async throws -> [LeoAgent]
    func spawn(_ request: LeoSpawnRequest, host: LeoHostID) async throws -> LeoAgent
    func start(_ name: String, host: LeoHostID) async throws
    func stop(_ name: String, host: LeoHostID, wakeOnMessage: Bool?) async throws
    func restart(_ name: String, host: LeoHostID) async throws -> LeoAgent
    func reset(_ name: String, host: LeoHostID) async throws
    func setTemplate(_ name: String, host: LeoHostID, template: String) async throws
    func rename(_ name: String, host: LeoHostID, newName: String) async throws -> LeoAgent
    func delete(_ name: String, host: LeoHostID, force: Bool?, deleteBranch: Bool?) async throws
    func deletePlan(_ name: String, host: LeoHostID) async throws -> LeoDeletePlan
    func logs(_ name: String, host: LeoHostID, lines: Int?) async throws -> String
    /// Operator control routes (B-262); socket-served from leo 0.35.
    func message(_ name: String, text: String) async throws -> LeoMessageDelivery
    func interrupt(_ name: String) async throws
    func compact(_ name: String, instructions: String?) async throws
    func clear(_ name: String) async throws
    /// B-283 (`agent_environments`): the configured names and template
    /// defaults, and an agent's override (empty clears it; the agent restarts).
    func environmentCatalog() async throws -> LeoEnvironmentCatalog
    func setEnvironments(_ name: String, names: [String]) async throws
}

/// Default host-scoped implementations: every daemon socket now represents
/// exactly one host (no more per-host prefixed routes), so any call
/// scoped to a non-local host simply has nothing to route to yet -- app-owned
/// SSH tunnels (see `LeoHostSelection`) are what will eventually give a
/// remote host its own socket path and its own `LeoDaemonClient` instance.
extension LeoDaemonClient {
    func templates() async throws -> [LeoTemplate] { throw LeoDaemonError.transport("Daemon templates are unavailable") }
    func templates(host: LeoHostID) async throws -> [LeoTemplate] {
        try requireLocal(host)
        return try await templates()
    }
    func version() async throws -> String { throw LeoDaemonError.transport("Daemon version is unavailable") }
    func message(_ name: String, text: String) async throws -> LeoMessageDelivery { throw LeoDaemonError.transport("Agent control is unavailable") }
    func interrupt(_ name: String) async throws { throw LeoDaemonError.transport("Agent control is unavailable") }
    func compact(_ name: String, instructions: String?) async throws { throw LeoDaemonError.transport("Agent control is unavailable") }
    func clear(_ name: String) async throws { throw LeoDaemonError.transport("Agent control is unavailable") }
    func environmentCatalog() async throws -> LeoEnvironmentCatalog { throw LeoDaemonError.transport("Environments are unavailable") }
    func setEnvironments(_ name: String, names: [String]) async throws { throw LeoDaemonError.transport("Environments are unavailable") }

    private func requireLocal(_ host: LeoHostID) throws {
        guard host == .local else { throw LeoDaemonError.hostUnavailable("Remote hosts are unavailable") }
    }
    func listAgents(host: LeoHostID) async throws -> [LeoAgent] { try requireLocal(host); return try await listAgents() }
    func spawn(_ request: LeoSpawnRequest, host: LeoHostID) async throws -> LeoAgent { try requireLocal(host); return try await spawn(request) }
    func start(_ name: String, host: LeoHostID) async throws { try requireLocal(host); try await start(name) }
    func stop(_ name: String, host: LeoHostID, wakeOnMessage: Bool?) async throws { try requireLocal(host); try await stop(name, wakeOnMessage: wakeOnMessage) }
    func restart(_ name: String, host: LeoHostID) async throws -> LeoAgent { try requireLocal(host); return try await restart(name) }
    func reset(_ name: String, host: LeoHostID) async throws { try requireLocal(host); try await reset(name) }
    func setTemplate(_ name: String, host: LeoHostID, template: String) async throws { try requireLocal(host); try await setTemplate(name, template: template) }
    func rename(_ name: String, host: LeoHostID, newName: String) async throws -> LeoAgent { try requireLocal(host); return try await rename(name, newName: newName) }
    func delete(_ name: String, host: LeoHostID, force: Bool?, deleteBranch: Bool?) async throws { try requireLocal(host); try await delete(name, force: force, deleteBranch: deleteBranch) }
    func deletePlan(_ name: String, host: LeoHostID) async throws -> LeoDeletePlan { try requireLocal(host); return try await deletePlan(name) }
    func logs(_ name: String, host: LeoHostID, lines: Int?) async throws -> String { try requireLocal(host); return try await logs(name, lines: lines) }
}

protocol LeoDaemonTransport: Sendable {
    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse
}

/// Bound to a single unix socket -- every route is unprefixed. Remote hosts
/// get their own socket path (an app-owned SSH tunnel) and their own
/// `LeoSocketDaemonClient` instance rather than a per-host prefixed route.
struct LeoSocketDaemonClient: LeoDaemonClient {
    let socketPath: String
    let defaultTimeout: TimeInterval
    let mutationTimeout: TimeInterval
    private let transport: any LeoDaemonTransport

    init(socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
         defaultTimeout: TimeInterval = 5,
         mutationTimeout: TimeInterval = 30,
         transport: any LeoDaemonTransport = LeoUnixSocketTransport()) {
        self.socketPath = socketPath
        self.defaultTimeout = defaultTimeout
        self.mutationTimeout = mutationTimeout
        self.transport = transport
    }

    func listAgents() async throws -> [LeoAgent] { try await value("GET", "/agents/list") }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent {
        let response = try await checked("POST", "/agents/spawn", body: try LeoEnvironmentsWire.spawnBody(request), timeout: mutationTimeout)
        do { return try LeoDaemonEnvelope<LeoAgent>.decode(response.body).value() } catch let error as LeoDaemonError { throw Self.map(error) }
    }
    func start(_ name: String) async throws { try await okay("POST", try route(name, "start")) }
    func stop(_ name: String, wakeOnMessage: Bool? = nil) async throws {
        let body = try wakeOnMessage.map { try JSONEncoder().encode(["wake_on_message": $0]) }
        try await okay("POST", try route(name, "stop"), body: body)
    }
    func restart(_ name: String) async throws -> LeoAgent { try await value("POST", try route(name, "restart")) }
    func reset(_ name: String) async throws { try await okay("POST", try route(name, "reset")) }
    func setTemplate(_ name: String, template: String) async throws {
        let query = try URLQueryItem(name: "template", value: template).percentEncodedValue()
        try await okay("POST", try route(name, "set-template") + "?template=" + query)
    }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { try await value("POST", try route(name, "rename"), body: try JSONEncoder().encode(["new_name": newName])) }
    func delete(_ name: String, force: Bool? = nil, deleteBranch: Bool? = nil) async throws {
        var values: [String: Bool] = [:]
        if let force { values["force"] = force }
        if let deleteBranch { values["delete_branch"] = deleteBranch }
        try await okay("DELETE", try route(name), body: values.isEmpty ? nil : try JSONEncoder().encode(values), timeout: mutationTimeout)
    }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { try await value("GET", try route(name, "delete-plan")) }
    func logs(_ name: String, lines: Int? = nil) async throws -> String {
        let suffix = lines.map { "?lines=\($0)" } ?? ""
        struct Logs: Decodable, Sendable { let output: String }
        return try await value("GET", try route(name, "logs") + suffix, as: Logs.self).output
    }

    func message(_ name: String, text: String) async throws -> LeoMessageDelivery {
        struct Reply: Decodable, Sendable { let transport: String?; let queued: Bool? }
        let response = try await control(name, .message, body: try JSONEncoder().encode(["text": text]))
        if response.status == 202 { return .queued }
        let reply = try LeoDaemonEnvelope<Reply>.decode(response.body).value()
        return reply.queued == true ? .queued : .delivered(transport: reply.transport)
    }
    func interrupt(_ name: String) async throws { _ = try await control(name, .interrupt) }
    func compact(_ name: String, instructions: String?) async throws {
        let body = try instructions.map { try JSONEncoder().encode(["instructions": $0]) }
        _ = try await control(name, .compact, body: body)
    }
    func clear(_ name: String) async throws { _ = try await control(name, .clear) }

    func templates() async throws -> [LeoTemplate] { try await value("GET", "/templates") }

    func environmentCatalog() async throws -> LeoEnvironmentCatalog {
        let names = try await checked("GET", LeoEnvironmentsWire.catalogRoute)
        let templates = try await checked("GET", LeoEnvironmentsWire.templatesRoute)
        return LeoEnvironmentCatalog(
            names: try LeoEnvironmentsWire.catalogNames(names.body),
            templateDefaults: try LeoEnvironmentsWire.templateDefaults(templates.body)
        )
    }

    func setEnvironments(_ name: String, names: [String]) async throws {
        let response = try await checked(
            "POST", try route(name, LeoEnvironmentsWire.agentAction), body: try LeoEnvironmentsWire.setBody(names), timeout: mutationTimeout
        )
        do { try LeoDaemonEnvelope<LeoEmpty>.decode(response.body).expectOK() } catch let error as LeoDaemonError { throw Self.map(error) }
    }
    func version() async throws -> String {
        struct Version: Decodable, Sendable { let version: String }
        return try await value("GET", "/version", as: Version.self).version
    }

    /// Detects the flavor of the daemon on `socketPath` from `GET /health`.
    /// Validates both the HTTP status (`send` already throws on a non-2xx/
    /// unparseable response) and the envelope's `ok` flag -- a `{ok:false}`
    /// (or a response that fails to parse) is always treated as `.legacy`.
    static func detectFlavor(socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
                             transport: any LeoDaemonTransport = LeoUnixSocketTransport()) async -> LeoAPIFlavor {
        struct Health: Decodable { let ok: Bool; struct Data: Decodable { let version: String }; let data: Data? }
        guard let response = try? await transport.send(.init(method: "GET", path: "/health"), socketPath: socketPath, timeout: 5),
              (200..<300).contains(response.status),
              let health = try? JSONDecoder().decode(Health.self, from: response.body),
              health.ok, let data = health.data else { return .legacy }
        return .select(version: data.version)
    }

    private func route(_ name: String, _ action: String? = nil) throws -> String {
        let segment = try Self.pathSegment(name)
        return "/agents/\(segment)" + (action.map { "/\($0)" } ?? "")
    }

    static func pathSegment(_ name: String) throws -> String {
        guard !name.isEmpty else { throw LeoDaemonError.decoding("Agent name is empty") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw LeoDaemonError.decoding("Cannot encode agent name")
        }
        return encoded
    }

    private func value<T: Decodable & Sendable>(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval? = nil, as: T.Type = T.self) async throws -> T {
        let response = try await transport.send(LeoHTTPRequest(method: method, path: path, body: body), socketPath: socketPath, timeout: timeout ?? defaultTimeout)
        let envelope = try LeoDaemonEnvelope<T>.decode(response.body)
        do { return try envelope.value() } catch let error as LeoDaemonError { throw Self.map(error) }
    }

    private func okay(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval? = nil) async throws {
        let response = try await transport.send(LeoHTTPRequest(method: method, path: path, body: body), socketPath: socketPath, timeout: timeout ?? defaultTimeout)
        do { try LeoDaemonEnvelope<LeoEmpty>.decode(response.body).expectOK() } catch let error as LeoDaemonError { throw Self.map(error) }
    }

    /// A control POST. The control routes' errors carry no envelope `code`,
    /// so a non-2xx is named by its HTTP status (`Self.controlCode`); the
    /// daemon's own message is kept. Returns the 2xx response.
    private func control(_ name: String, _ verb: LeoControlVerb, body: Data? = nil) async throws -> LeoHTTPResponse {
        let response = try await transport.send(
            LeoHTTPRequest(method: "POST", path: try route(name, verb.rawValue), body: body),
            socketPath: socketPath, timeout: mutationTimeout
        )
        guard (200..<300).contains(response.status) else { throw Self.controlError(response) }
        do { try LeoDaemonEnvelope<LeoEmpty>.decode(response.body).expectOK() } catch let error as LeoDaemonError { throw Self.map(error) }
        return response
    }

    /// A request whose non-2xx is reported by the daemon's own message
    /// (else "HTTP n"), whatever the code. Returns the 2xx response.
    private func checked(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval? = nil) async throws -> LeoHTTPResponse {
        let response = try await transport.send(
            LeoHTTPRequest(method: method, path: path, body: body), socketPath: socketPath, timeout: timeout ?? defaultTimeout
        )
        guard (200..<300).contains(response.status) else { throw Self.controlError(response) }
        return response
    }

    private static func controlError(_ response: LeoHTTPResponse) -> LeoDaemonError {
        let envelope = try? LeoDaemonEnvelope<LeoEmpty>.decode(response.body)
        return map(.daemon(
            code: envelope?.code ?? controlCode(forStatus: response.status),
            message: envelope?.error ?? "HTTP \(response.status)",
            matches: envelope?.matches ?? []
        ))
    }

    static func controlCode(forStatus status: Int) -> String {
        switch status {
        case 401: "unauthorized"
        case 403: "forbidden"
        case 404: "not_found"
        case 413: "too_large"
        case 503: "unavailable"
        default: "http_\(status)"
        }
    }

    private static func map(_ error: LeoDaemonError) -> LeoDaemonError {
        if case .daemon(let code, let message, _) = error, code == "host_unavailable" { return .hostUnavailable(message) }
        if case .daemon(let code, let message, _) = error, code == "host_unknown" { return .hostUnknown(message) }
        return error
    }
}

private struct LeoEmpty: Decodable, Sendable {}

private extension URLQueryItem {
    func percentEncodedValue() throws -> String {
        guard let value, let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw LeoDaemonError.decoding("Cannot encode query parameter")
        }
        return encoded.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "&", with: "%26")
    }
}
