import Foundation

/// An account a machine's daemon is willing to act as: `GET /credentials/accounts`.
/// It carries no token and no token metadata.
public struct LeoCredentialAccount: Codable, Equatable, Sendable {
    public let kind: LeoPluginCredentialKind
    /// Absolute, on that machine.
    public let dir: String
    public let label: String

    public init(kind: LeoPluginCredentialKind, dir: String, label: String) {
        self.kind = kind
        self.dir = dir
        self.label = label
    }
}

/// One header on the wire: a `["name","value"]` pair, so order and repeats survive.
public struct LeoCredentialHeader: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        name = try container.decode(String.self)
        value = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(name)
        try container.encode(value)
    }
}

/// `POST /credentials/fetch`: the daemon reads the token on its own machine and makes the request.
public struct LeoCredentialFetchRequest: Equatable, Sendable {
    public let kind: LeoPluginCredentialKind
    public let dir: String
    public let url: String
    public let method: String
    public let headers: [LeoCredentialHeader]
    public let body: Data?

    public init(kind: LeoPluginCredentialKind, dir: String, url: String, method: String, headers: [LeoCredentialHeader], body: Data?) {
        self.kind = kind
        self.dir = dir
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    func wireBody() throws -> Data {
        struct Wire: Encodable {
            let kind: String, dir: String, url: String, method: String
            let headers: [LeoCredentialHeader]
            let bodyBase64: String?
        }
        return try JSONEncoder().encode(Wire(
            kind: kind.rawValue, dir: dir, url: url, method: method, headers: headers, bodyBase64: body?.base64EncodedString()))
    }
}

public struct LeoCredentialFetchReply: Equatable, Sendable {
    public let status: Int
    public let headers: [LeoCredentialHeader]
    public let body: Data

    public init(status: Int, headers: [LeoCredentialHeader], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The daemon's refusal in a credential route's `{"error":{reason,message}}`
/// body (HTTP 200). `reason` is one of the plugin-facing codes; the message never holds token bytes.
public struct LeoCredentialRemoteError: Error, Equatable, Sendable {
    public let reason: String
    public let message: String

    public init(reason: String, message: String) {
        self.reason = reason
        self.message = message
    }
}

/// The credential routes answer plain JSON, not the `{ok,data}` envelope.
enum LeoCredentialWire {
    private struct Failure: Decodable {
        struct Body: Decodable { let reason: String; let message: String }
        let error: Body?
    }

    private struct Accounts: Decodable { let accounts: [LeoCredentialAccount]? }
    private struct Check: Decodable { let ok: Bool? }
    private struct Reply: Decodable {
        let status: Int?
        let headers: [LeoCredentialHeader]?
        let bodyBase64: String?
    }

    /// Throws the daemon's error body when there is one.
    private static func raise(_ data: Data) throws {
        guard let body = (try? JSONDecoder().decode(Failure.self, from: data))?.error else { return }
        throw LeoCredentialRemoteError(reason: body.reason, message: body.message)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw LeoDaemonError.decoding(String(describing: error)) }
    }

    static func accounts(_ data: Data) throws -> [LeoCredentialAccount] {
        try raise(data)
        guard let accounts = try decode(Accounts.self, data).accounts else { throw LeoDaemonError.decoding("no accounts in reply") }
        return accounts
    }

    static func check(_ data: Data) throws {
        try raise(data)
        guard try decode(Check.self, data).ok == true else { throw LeoDaemonError.decoding("no ok in reply") }
    }

    static func fetch(_ data: Data) throws -> LeoCredentialFetchReply {
        try raise(data)
        let reply = try decode(Reply.self, data)
        guard let status = reply.status else { throw LeoDaemonError.decoding("no status in reply") }
        let body: Data
        if let encoded = reply.bodyBase64, !encoded.isEmpty {
            guard let decoded = Data(base64Encoded: encoded) else { throw LeoDaemonError.decoding("body is not base64") }
            body = decoded
        } else {
            body = Data()
        }
        return LeoCredentialFetchReply(status: status, headers: reply.headers ?? [], body: body)
    }

    static func checkBody(kind: LeoPluginCredentialKind, dir: String) throws -> Data {
        try JSONEncoder().encode(["kind": kind.rawValue, "dir": dir])
    }
}
