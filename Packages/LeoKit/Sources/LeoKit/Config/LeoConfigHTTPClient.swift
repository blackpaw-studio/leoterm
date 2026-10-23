import Foundation

/// `LeoConfigClient` over any daemon transport. The socket serves the routes
/// unprefixed and the web listener under `/api/v1`, so one implementation
/// takes the prefix and the transport.
public struct LeoConfigHTTPClient: LeoConfigClient {
    public static let socketPrefix = ""
    public static let webPrefix = "/api/v1"

    public let prefix: String
    public let defaultTimeout: TimeInterval
    public let mutationTimeout: TimeInterval
    private let transport: any LeoChatTransport

    public init(prefix: String, transport: any LeoChatTransport, defaultTimeout: TimeInterval = 10, mutationTimeout: TimeInterval = 30) {
        self.prefix = prefix
        self.transport = transport
        self.defaultTimeout = defaultTimeout
        self.mutationTimeout = mutationTimeout
    }

    public func versionInfo() async throws -> LeoDaemonVersionInfo {
        try await read("\(prefix)/version")
    }

    public func schema() async throws -> LeoConfigSchema {
        do {
            return try await read("\(prefix)/config/schema")
        } catch LeoDaemonError.daemon(let code, _, _) where code == LeoSocketDaemonClient.controlCode(forStatus: 404) || code == "not_found" {
            throw LeoConfigError.unsupported
        }
    }

    public func document(_ resource: String) async throws -> LeoConfigDocument {
        try await read(try route(resource))
    }

    public func collection(_ resource: String) async throws -> LeoConfigCollection {
        try await read(try route(resource))
    }

    public func item(_ resource: String, name: String) async throws -> LeoConfigDocument {
        try await read(try route(resource, name))
    }

    public func update(_ resource: String, name: String?, patch: [String: LeoConfigValue], ifMatch: String) async throws -> LeoConfigWriteResult {
        try await write("PUT", try route(resource, name), body: ["values": .object(patch.mapValues(\.writeForm))], ifMatch: ifMatch)
    }

    public func add(_ resource: String, name: String, values: [String: LeoConfigValue], ifMatch: String) async throws -> LeoConfigWriteResult {
        try await write("POST", try route(resource), body: values.mapValues(\.writeForm).merging(["name": .string(name)]) { _, name in name }, ifMatch: ifMatch)
    }

    public func rename(_ resource: String, name: String, to newName: String, ifMatch: String) async throws -> LeoConfigWriteResult {
        try await write("POST", try route(resource, name, "rename"), body: ["new_name": .string(newName)], ifMatch: ifMatch)
    }

    public func duplicate(_ resource: String, name: String, as newName: String, ifMatch: String) async throws -> LeoConfigWriteResult {
        try await write("POST", try route(resource, name, "duplicate"), body: ["new_name": .string(newName)], ifMatch: ifMatch)
    }

    public func delete(_ resource: String, name: String, ifMatch: String) async throws -> LeoConfigWriteResult {
        try await write("DELETE", try route(resource, name), body: nil, ifMatch: ifMatch)
    }

    // MARK: plumbing

    /// `<prefix>/config/<resource>[/<name>[/<action>]]`, each part escaped.
    private func route(_ resource: String, _ name: String? = nil, _ action: String? = nil) throws -> String {
        var path = "\(prefix)/config/\(try Self.segment(resource, what: "Config resource"))"
        if let name { path += "/\(try Self.segment(name, what: "Config item name"))" }
        if let action { path += "/\(action)" }
        return path
    }

    private static func segment(_ part: String, what: String) throws -> String {
        guard !part.isEmpty else { throw LeoDaemonError.decoding("\(what) is empty") }
        return try LeoSocketDaemonClient.pathSegment(part)
    }

    private func read<T: Decodable & Sendable>(_ path: String) async throws -> T {
        let response = try await transport.send(LeoHTTPRequest(method: "GET", path: path), timeout: defaultTimeout)
        return try Self.payload(response)
    }

    private func write(_ method: String, _ path: String, body: [String: LeoConfigValue]?, ifMatch: String) async throws -> LeoConfigWriteResult {
        let encoded = try body.map { try Self.encoder.encode($0) }
        let request = LeoHTTPRequest(method: method, path: path, body: encoded, headers: ["If-Match": ifMatch])
        return try Self.payload(try await transport.send(request, timeout: mutationTimeout))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func payload<T: Decodable & Sendable>(_ response: LeoHTTPResponse) throws -> T {
        guard (200..<300).contains(response.status) else { throw failure(response) }
        return try LeoDaemonEnvelope<T>.decode(response.body).value()
    }

    private struct FailureBody: Decodable {
        struct Current: Decodable { let revision: String? }
        let error: String?
        let code: String?
        let data: Current?
        let errors: [LeoConfigFieldError]?
    }

    /// Maps a non-2xx to the config API's own errors, else to a daemon error
    /// named by the envelope `code`, or the HTTP status when there is none.
    private static func failure(_ response: LeoHTTPResponse) -> Error {
        let body = try? JSONDecoder().decode(FailureBody.self, from: response.body)
        switch response.status {
        case 409:
            if let revision = body?.data?.revision { return LeoConfigError.conflict(currentRevision: revision) }
        case 422:
            if let errors = body?.errors, !errors.isEmpty { return LeoConfigError.invalid(errors) }
            if let message = body?.error { return LeoConfigError.invalid([LeoConfigFieldError(field: "", message: message)]) }
        case 428:
            return LeoConfigError.revisionRequired
        default:
            break
        }
        return LeoDaemonError.daemon(
            code: body?.code ?? LeoSocketDaemonClient.controlCode(forStatus: response.status),
            message: body?.error ?? "HTTP \(response.status)",
            matches: []
        )
    }
}
