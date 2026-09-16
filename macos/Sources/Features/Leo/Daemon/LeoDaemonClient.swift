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
    func hosts() async throws -> [LeoHostRow]
    func connectHost(_ name: String) async throws -> LeoHostRow
    func disconnectHost(_ name: String) async throws -> LeoHostRow
    func templates(host: LeoHostID) async throws -> [LeoTemplate]
    func version() async throws -> String
}

extension LeoDaemonClient {
    func hosts() async throws -> [LeoHostRow] { throw LeoDaemonError.transport("Remote hosts are unavailable") }
    func connectHost(_: String) async throws -> LeoHostRow { throw LeoDaemonError.transport("Remote hosts are unavailable") }
    func disconnectHost(_: String) async throws -> LeoHostRow { throw LeoDaemonError.transport("Remote hosts are unavailable") }
    func templates(host _: LeoHostID) async throws -> [LeoTemplate] { throw LeoDaemonError.transport("Daemon templates are unavailable") }
    func version() async throws -> String { throw LeoDaemonError.transport("Daemon version is unavailable") }

    func listAgents(host _: LeoHostID) async throws -> [LeoAgent] { try await listAgents() }
    func spawn(_ request: LeoSpawnRequest, host _: LeoHostID) async throws -> LeoAgent { try await spawn(request) }
    func start(_ name: String, host _: LeoHostID) async throws { try await start(name) }
    func stop(_ name: String, host _: LeoHostID, wakeOnMessage: Bool?) async throws { try await stop(name, wakeOnMessage: wakeOnMessage) }
    func restart(_ name: String, host _: LeoHostID) async throws -> LeoAgent { try await restart(name) }
    func reset(_ name: String, host _: LeoHostID) async throws { try await reset(name) }
    func setTemplate(_ name: String, host _: LeoHostID, template: String) async throws { try await setTemplate(name, template: template) }
    func rename(_ name: String, host _: LeoHostID, newName: String) async throws -> LeoAgent { try await rename(name, newName: newName) }
    func delete(_ name: String, host _: LeoHostID, force: Bool?, deleteBranch: Bool?) async throws { try await delete(name, force: force, deleteBranch: deleteBranch) }
    func deletePlan(_ name: String, host _: LeoHostID) async throws -> LeoDeletePlan { try await deletePlan(name) }
    func logs(_ name: String, host _: LeoHostID, lines: Int?) async throws -> String { try await logs(name, lines: lines) }
}

protocol LeoDaemonTransport: Sendable {
    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse
}

struct LeoSocketDaemonClient: LeoDaemonClient {
    let socketPath: String
    let defaultTimeout: TimeInterval
    let mutationTimeout: TimeInterval
    private let transport: any LeoDaemonTransport
    let flavor: LeoAPIFlavor

    init(socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
         defaultTimeout: TimeInterval = 5,
         mutationTimeout: TimeInterval = 30,
         transport: any LeoDaemonTransport = LeoUnixSocketTransport(),
         flavor: LeoAPIFlavor = .legacy) {
        self.socketPath = socketPath
        self.defaultTimeout = defaultTimeout
        self.mutationTimeout = mutationTimeout
        self.transport = transport
        self.flavor = flavor
    }

    func listAgents() async throws -> [LeoAgent] { try await value("GET", "/agents/list") }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { try await value("POST", "/agents/spawn", body: try JSONEncoder().encode(request), timeout: mutationTimeout) }
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

    func hosts() async throws -> [LeoHostRow] { try await value("GET", "/hosts") }
    func connectHost(_ name: String) async throws -> LeoHostRow { try await value("POST", "/hosts/\(try Self.pathSegment(name))/connect") }
    func disconnectHost(_ name: String) async throws -> LeoHostRow { try await value("POST", "/hosts/\(try Self.pathSegment(name))/disconnect") }
    func templates(host: LeoHostID) async throws -> [LeoTemplate] { try await value("GET", try hostPrefix(host) + "/templates") }
    func version() async throws -> String {
        struct Version: Decodable, Sendable { let version: String }
        let response = try await transport.send(.init(method: "GET", path: "/version"), socketPath: socketPath, timeout: defaultTimeout)
        return try JSONDecoder().decode(Version.self, from: response.body).version
    }

    func listAgents(host: LeoHostID) async throws -> [LeoAgent] { try await value("GET", try hostPrefix(host) + "/agents/list") }
    func spawn(_ request: LeoSpawnRequest, host: LeoHostID) async throws -> LeoAgent { try await value("POST", try hostPrefix(host) + "/agents/spawn", body: try JSONEncoder().encode(request), timeout: mutationTimeout) }
    func start(_ name: String, host: LeoHostID) async throws { try await okay("POST", try route(name, "start", host: host)) }
    func stop(_ name: String, host: LeoHostID, wakeOnMessage: Bool?) async throws { try await okay("POST", try route(name, "stop", host: host), body: try wakeOnMessage.map { try JSONEncoder().encode(["wake_on_message": $0]) }) }
    func restart(_ name: String, host: LeoHostID) async throws -> LeoAgent { try await value("POST", try route(name, "restart", host: host)) }
    func reset(_ name: String, host: LeoHostID) async throws { try await okay("POST", try route(name, "reset", host: host)) }
    func setTemplate(_ name: String, host: LeoHostID, template: String) async throws { try await okay("POST", try route(name, "set-template", host: host) + "?template=" + URLQueryItem(name: "template", value: template).percentEncodedValue()) }
    func rename(_ name: String, host: LeoHostID, newName: String) async throws -> LeoAgent { try await value("POST", try route(name, "rename", host: host), body: try JSONEncoder().encode(["new_name": newName])) }
    func delete(_ name: String, host: LeoHostID, force: Bool?, deleteBranch: Bool?) async throws { var values: [String: Bool] = [:]; if let force { values["force"] = force }; if let deleteBranch { values["delete_branch"] = deleteBranch }; try await okay("DELETE", try route(name, host: host), body: values.isEmpty ? nil : try JSONEncoder().encode(values), timeout: mutationTimeout) }
    func deletePlan(_ name: String, host: LeoHostID) async throws -> LeoDeletePlan { try await value("GET", try route(name, "delete-plan", host: host)) }
    func logs(_ name: String, host: LeoHostID, lines: Int?) async throws -> String { struct Logs: Decodable, Sendable { let output: String }; return try await value("GET", try route(name, "logs", host: host) + (lines.map { "?lines=\($0)" } ?? ""), as: Logs.self).output }

    static func detectFlavor(socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
                             transport: any LeoDaemonTransport = LeoUnixSocketTransport()) async -> LeoAPIFlavor {
        struct Health: Decodable { let version: String }
        guard let response = try? await transport.send(.init(method: "GET", path: "/health"), socketPath: socketPath, timeout: 5),
              let health = try? JSONDecoder().decode(Health.self, from: response.body) else { return .legacy }
        return .select(version: health.version)
    }

    private func route(_ name: String, _ action: String? = nil, host: LeoHostID? = nil) throws -> String {
        let segment = try Self.pathSegment(name)
        let prefix = try host.map(hostPrefix) ?? ""
        return prefix + "/agents/\(segment)" + (action.map { "/\($0)" } ?? "")
    }

    private func hostPrefix(_ host: LeoHostID) throws -> String {
        let name = switch host {
        case .local: "localhost"
        case .remote(let name): name
        }
        return "/hosts/\(try Self.pathSegment(name))"
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

    private static func map(_ error: LeoDaemonError) -> LeoDaemonError {
        if case .daemon(let code, let message, _) = error, code == "host_unavailable" { return .hostUnavailable(message) }
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
