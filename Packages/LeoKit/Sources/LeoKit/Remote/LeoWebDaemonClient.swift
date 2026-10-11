import Foundation

/// The daemon's web-listener API as a paired device uses it: the
/// observability snapshot and stream, and the agent control routes.
public struct LeoWebDaemonClient: Sendable {
    public let defaultTimeout: TimeInterval
    public let mutationTimeout: TimeInterval
    private let transport: any LeoWebTransport

    public init(transport: any LeoWebTransport, defaultTimeout: TimeInterval = 10, mutationTimeout: TimeInterval = 30) {
        self.transport = transport
        self.defaultTimeout = defaultTimeout
        self.mutationTimeout = mutationTimeout
    }

    /// Redeems a one-time `leo pair` code. The route is unauthenticated, so
    /// `transport` carries no bearer (Cloudflare Access headers, if any).
    public static func pair(code: String, deviceName: String, transport: any LeoWebTransport, timeout: TimeInterval = 15) async throws -> LeoPairingGrant {
        let body = try JSONEncoder().encode(["pairing_code": code, "device_name": deviceName])
        let response = try await transport.send(LeoHTTPRequest(method: "POST", path: "/api/v1/pair", body: body), timeout: timeout)
        return try LeoDaemonEnvelope<LeoPairingGrant>.decode(try checked(response).body).value()
    }

    public func fetchState() async throws -> LeoObservedState {
        try LeoDaemonEnvelope<LeoObservedState>.decode(try await request("GET", "/api/v1/state").body).value()
    }

    /// One `/api/v1/events` connection, decoded. Undecodable events are
    /// dropped; gap handling and reconnecting are the caller's.
    public func events() -> AsyncThrowingStream<LeoObserveEvent, any Error> {
        let source = transport.events(path: "/api/v1/events")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await raw in source {
                        if let event = LeoActivityClient.decode(raw) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stops the agent, leaving it dormant until started (no wake on message).
    public func stop(_ name: String) async throws {
        struct Body: Encodable { let name: String; let wake_on_message: Bool }
        try await expectOK("POST", "/api/agent/stop", body: try JSONEncoder().encode(Body(name: name, wake_on_message: false)))
    }

    public func start(_ name: String) async throws {
        try await expectOK("POST", "/api/agent/start", body: try JSONEncoder().encode(["name": name]))
    }

    /// The web listener has no restart route: stop, then start (which
    /// rejoins the agent's prior session).
    public func restart(_ name: String) async throws {
        try await stop(name)
        try await start(name)
    }

    public func interrupt(_ name: String) async throws {
        try await expectOK("POST", "/api/v1/agents/\(try LeoSocketDaemonClient.pathSegment(name))/interrupt")
    }

    /// The configured named environments, sorted.
    public func environmentNames() async throws -> [String] {
        try LeoEnvironmentsWire.catalogNames(try await request("GET", "/api/v1/environments").body)
    }

    /// Re-points the agent at `names` (empty clears the override); the
    /// daemon restarts it with its conversation resumed.
    public func setEnvironments(_ name: String, names: [String]) async throws {
        let path = "/api/v1/agents/\(try LeoSocketDaemonClient.pathSegment(name))/environments"
        try await expectOK("POST", path, body: try LeoEnvironmentsWire.setBody(names))
    }

    /// Tells the daemon how to push to this device, replacing any earlier
    /// registration. Any 2xx is success, whatever its body.
    public func registerPush(deviceID: String, _ registration: LeoPushRegistration) async throws {
        _ = try await request("PUT", try Self.pushPath(deviceID), body: try JSONEncoder().encode(registration))
    }

    /// Stops the daemon pushing to this device.
    public func unregisterPush(deviceID: String) async throws {
        _ = try await request("DELETE", try Self.pushPath(deviceID))
    }

    private static func pushPath(_ deviceID: String) throws -> String {
        "/api/v1/devices/\(try LeoSocketDaemonClient.pathSegment(deviceID))/push"
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> LeoHTTPResponse {
        let timeout = method == "GET" ? defaultTimeout : mutationTimeout
        return try Self.checked(try await transport.send(LeoHTTPRequest(method: method, path: path, body: body), timeout: timeout))
    }

    private func expectOK(_ method: String, _ path: String, body: Data? = nil) async throws {
        try LeoDaemonEnvelope<LeoWebEmpty>.decode(try await request(method, path, body: body).body).expectOK()
    }

    /// A non-2xx is named by its envelope `code`, else its HTTP status; the
    /// daemon's own message is kept when it sent one.
    private static func checked(_ response: LeoHTTPResponse) throws -> LeoHTTPResponse {
        guard !(200..<300).contains(response.status) else { return response }
        let envelope = try? LeoDaemonEnvelope<LeoWebEmpty>.decode(response.body)
        throw LeoDaemonError.daemon(
            code: envelope?.code ?? LeoSocketDaemonClient.controlCode(forStatus: response.status),
            message: envelope?.error ?? "HTTP \(response.status)",
            matches: envelope?.matches ?? []
        )
    }
}

private struct LeoWebEmpty: Decodable, Sendable {}
