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
}

protocol LeoDaemonTransport: Sendable {
    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse
}

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
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { try await value("POST", "/agents/spawn", body: try JSONEncoder().encode(request), timeout: mutationTimeout) }
    func start(_ name: String) async throws { try await okay("POST", try route(name, "start")) }
    func stop(_ name: String, wakeOnMessage: Bool? = nil) async throws {
        let body = wakeOnMessage.map { try? JSONEncoder().encode(["wake_on_message": $0]) } ?? nil
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
        return try envelope.value()
    }

    private func okay(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval? = nil) async throws {
        let response = try await transport.send(LeoHTTPRequest(method: method, path: path, body: body), socketPath: socketPath, timeout: timeout ?? defaultTimeout)
        try LeoDaemonEnvelope<LeoEmpty>.decode(response.body).expectOK()
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
