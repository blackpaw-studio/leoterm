import Foundation

// The client-tools relay wire (plan "Wire contract"). Golden JSON for every
// shape lives in `Tests/LeoKitTests/Fixtures/client-tools/`, identical to the
// daemon's `internal/clienttools/testdata/wire/`; change both together.

/// A tool an app declares: what the agent sees, plus the daemon-side timeout
/// (`0` means no timeout).
public struct LeoClientToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: LeoJSONValue
    public let timeoutSeconds: Int

    public init(name: String, description: String, inputSchema: LeoJSONValue, timeoutSeconds: Int) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.timeoutSeconds = timeoutSeconds
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
        case timeoutSeconds = "timeout_s"
    }
}

/// `POST /api/v1/client-tools` body.
public struct LeoClientToolsRegisterRequest: Codable, Equatable, Sendable {
    public let clientID: String
    public let group: String
    public let tools: [LeoClientToolDefinition]

    public init(clientID: String, group: String, tools: [LeoClientToolDefinition]) {
        self.clientID = clientID
        self.group = group
        self.tools = tools
    }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case group, tools
    }
}

/// `POST /api/v1/client-tools` 200.
public struct LeoClientToolsRegistered: Codable, Equatable, Sendable {
    public let revision: Int

    public init(revision: Int) { self.revision = revision }
}

/// One tool as the daemon lists it, tagged with its registering group.
public struct LeoRegisteredClientTool: Codable, Equatable, Sendable {
    public let group: String
    public let name: String
    public let description: String
    public let inputSchema: LeoJSONValue
    public let timeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
        case group, name, description
        case inputSchema = "input_schema"
        case timeoutSeconds = "timeout_s"
    }
}

/// `GET /api/v1/client-tools`.
public struct LeoClientToolsList: Codable, Equatable, Sendable {
    public let revision: Int
    public let everRegistered: Bool
    public let tools: [LeoRegisteredClientTool]

    enum CodingKeys: String, CodingKey {
        case revision, tools
        case everRegistered = "ever_registered"
    }
}

/// `POST /api/agent/{name}/client-tools/call` body (the MCP server's side).
public struct LeoClientToolCallRequest: Codable, Equatable, Sendable {
    public let tool: String
    public let args: LeoJSONValue

    public init(tool: String, args: LeoJSONValue) {
        self.tool = tool
        self.args = args
    }
}

/// An MCP content block. Text and image are the ones apps produce; any other
/// kind passes through verbatim as `.other`.
public enum LeoClientToolContent: Codable, Equatable, Sendable {
    case text(String)
    /// `data` is base64.
    case image(data: String, mimeType: String)
    case other(LeoJSONValue)

    private enum CodingKeys: String, CodingKey { case type, text, data, mimeType }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(data: try container.decode(String.self, forKey: .data), mimeType: try container.decode(String.self, forKey: .mimeType))
        default:
            self = .other(try LeoJSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let text):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .other(let value):
            try value.encode(to: encoder)
        }
    }
}

/// An app-side failure: one of the browser codes (`user_has_control`, ...)
/// or a daemon code (`no_client`, `timeout`, `cancelled`).
public struct LeoClientToolError: Codable, Equatable, Sendable, Error {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// How a tool call ended: `{ok:true, content}` or `{ok:false, error}`. The
/// same shape in the call response and the result body.
public enum LeoClientToolOutcome: Codable, Equatable, Sendable {
    case success([LeoClientToolContent])
    case failure(LeoClientToolError)

    private enum CodingKeys: String, CodingKey { case ok, content, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .ok) {
            self = .success(try container.decodeIfPresent([LeoClientToolContent].self, forKey: .content) ?? [])
        } else {
            self = .failure(try container.decode(LeoClientToolError.self, forKey: .error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let content):
            try container.encode(true, forKey: .ok)
            try container.encode(content, forKey: .content)
        case .failure(let error):
            try container.encode(false, forKey: .ok)
            try container.encode(error, forKey: .error)
        }
    }
}

/// One parked tool call. `owner` is empty until a provider owns the agent's
/// group. `createdAt` is the daemon's RFC 3339 string, kept as sent.
public struct LeoClientToolRequest: Codable, Equatable, Sendable {
    public let id: String
    public let agent: String
    public let group: String
    public let tool: String
    public let args: LeoJSONValue
    public let owner: String
    public let timeoutSeconds: Int
    public let createdAt: String

    public init(
        id: String, agent: String, group: String, tool: String, args: LeoJSONValue,
        owner: String = "", timeoutSeconds: Int, createdAt: String = ""
    ) {
        self.id = id
        self.agent = agent
        self.group = group
        self.tool = tool
        self.args = args
        self.owner = owner
        self.timeoutSeconds = timeoutSeconds
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agent = try container.decode(String.self, forKey: .agent)
        group = try container.decode(String.self, forKey: .group)
        tool = try container.decode(String.self, forKey: .tool)
        args = try container.decodeIfPresent(LeoJSONValue.self, forKey: .args) ?? .object([:])
        owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? ""
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, group, tool, args, owner
        case timeoutSeconds = "timeout_s"
        case createdAt = "created_at"
    }
}

/// `POST .../requests/{id}/claim` body.
public struct LeoClientToolClaimRequest: Codable, Equatable, Sendable {
    public let clientID: String

    public init(clientID: String) { self.clientID = clientID }

    enum CodingKeys: String, CodingKey { case clientID = "client_id" }
}

/// `POST .../requests/{id}/claim` 200.
public struct LeoClientToolClaimed: Codable, Equatable, Sendable {
    public let request: LeoClientToolRequest
}

/// `POST .../requests/{id}/result` body: `client_id` beside the outcome's
/// own `ok` / `content` / `error`.
public struct LeoClientToolResultRequest: Codable, Equatable, Sendable {
    public let clientID: String
    public let outcome: LeoClientToolOutcome

    public init(clientID: String, outcome: LeoClientToolOutcome) {
        self.clientID = clientID
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey { case clientID = "client_id" }

    public init(from decoder: any Decoder) throws {
        clientID = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .clientID)
        outcome = try LeoClientToolOutcome(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientID, forKey: .clientID)
        try outcome.encode(to: encoder)
    }
}

/// An empty `data` object (`result` 200), or the `data` of an error envelope
/// the caller doesn't read.
public struct LeoClientToolEmpty: Codable, Equatable, Sendable {}

/// A pending request: the request's fields flattened beside `claimed_by`
/// (empty while unclaimed).
public struct LeoClientToolPending: Codable, Equatable, Sendable {
    public let request: LeoClientToolRequest
    public let claimedBy: String

    private enum CodingKeys: String, CodingKey { case claimedBy = "claimed_by" }

    public init(request: LeoClientToolRequest, claimedBy: String) {
        self.request = request
        self.claimedBy = claimedBy
    }

    public init(from decoder: any Decoder) throws {
        request = try LeoClientToolRequest(from: decoder)
        claimedBy = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .claimedBy) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        try request.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(claimedBy, forKey: .claimedBy)
    }
}

/// `GET /api/v1/client-tools/requests?pending=1`.
public struct LeoClientToolPendingList: Codable, Equatable, Sendable {
    public let requests: [LeoClientToolPending]
}

/// A typed client-tools route failure, mapped from the envelope's `code`.
public enum LeoClientToolsError: Error, Equatable, Sendable {
    case invalidTool(message: String)
    case tooManyTools(message: String)
    /// The `client_id` is not a live provider stream (the stream closed).
    case unknownClient(message: String)
    /// A tool name collides with a built-in or another client's group.
    case nameConflict(tool: String?, message: String)
    case ownedByOther(message: String)
    case alreadyClaimed(message: String)
    /// Unknown, or already settled.
    case unknownRequest(message: String)
    case notClaimant(message: String)
    case alreadySettled(message: String)
    case other(code: String?, message: String)

    public var code: String? {
        switch self {
        case .invalidTool: "invalid_tool"
        case .tooManyTools: "too_many_tools"
        case .unknownClient: "unknown_client"
        case .nameConflict: "name_conflict"
        case .ownedByOther: "owned_by_other"
        case .alreadyClaimed: "already_claimed"
        case .unknownRequest: "unknown_request"
        case .notClaimant: "not_claimant"
        case .alreadySettled: "already_settled"
        case .other(let code, _): code
        }
    }

    public var message: String {
        switch self {
        case .invalidTool(let message), .tooManyTools(let message), .unknownClient(let message),
             .nameConflict(_, let message), .ownedByOther(let message), .alreadyClaimed(let message),
             .unknownRequest(let message), .notClaimant(let message), .alreadySettled(let message),
             .other(_, let message):
            message
        }
    }

    private struct ConflictData: Decodable { let tool: String? }

    /// Maps a failed envelope; `rawBody` is only read for `name_conflict`'s `data.tool`.
    public init<T>(envelope: LeoDaemonEnvelope<T>, rawBody: Data? = nil) {
        let message = envelope.error ?? "Unknown daemon error"
        switch envelope.code {
        case "invalid_tool": self = .invalidTool(message: message)
        case "too_many_tools": self = .tooManyTools(message: message)
        case "unknown_client": self = .unknownClient(message: message)
        case "name_conflict":
            self = .nameConflict(tool: rawBody.flatMap(Self.conflictingTool), message: message)
        case "owned_by_other": self = .ownedByOther(message: message)
        case "already_claimed": self = .alreadyClaimed(message: message)
        case "unknown_request": self = .unknownRequest(message: message)
        case "not_claimant": self = .notClaimant(message: message)
        case "already_settled": self = .alreadySettled(message: message)
        default: self = .other(code: envelope.code, message: message)
        }
    }

    private static func conflictingTool(in body: Data) -> String? {
        struct Wrapper: Decodable { let data: ConflictData? }
        return (try? JSONDecoder().decode(Wrapper.self, from: body))?.data?.tool
    }
}

/// One `/events` frame, reduced to what the client-tools stream cares about.
/// Every frame carries `seq`, so a gap is visible even in frames this client
/// doesn't otherwise act on (`.other`).
public enum LeoClientToolsWireEvent: Equatable, Sendable {
    case hello(seq: Int, clientID: String?, features: [String])
    case changed(seq: Int, revision: Int, tools: [String])
    case request(seq: Int, LeoClientToolsRequestPayload)
    case cancelled(seq: Int, LeoClientToolCancellation)
    case other(seq: Int)

    public var sequence: Int {
        switch self {
        case .hello(let seq, _, _), .changed(let seq, _, _), .request(let seq, _), .cancelled(let seq, _), .other(let seq): seq
        }
    }

    private struct Sequence: Decodable { let seq: Int }
    private struct Hello: Decodable {
        let seq: Int
        let clientID: String?
        let features: [String]?
        enum CodingKeys: String, CodingKey { case seq, features; case clientID = "client_id" }
    }
    private struct Changed: Decodable { let seq: Int; let revision: Int; let tools: [String]? }
    private struct RequestEvent: Decodable { let seq: Int; let request: LeoClientToolsRequestPayload }
    private struct CancelledEvent: Decodable {
        let seq: Int
        let id: String
        let agent: String?
        let reason: String?
    }

    /// nil when the payload isn't JSON with a `seq`, or a recognised event's
    /// own fields are malformed.
    public static func decode(name: String?, data: Data) -> Self? {
        let decoder = JSONDecoder()
        switch name {
        case "hello":
            guard let hello = try? decoder.decode(Hello.self, from: data) else { return nil }
            return .hello(seq: hello.seq, clientID: hello.clientID, features: hello.features ?? [])
        case "client_tools.changed":
            guard let changed = try? decoder.decode(Changed.self, from: data) else { return nil }
            return .changed(seq: changed.seq, revision: changed.revision, tools: changed.tools ?? [])
        case "client_tool.request":
            guard let event = try? decoder.decode(RequestEvent.self, from: data) else { return nil }
            return .request(seq: event.seq, event.request)
        case "client_tool.cancelled":
            guard let event = try? decoder.decode(CancelledEvent.self, from: data) else { return nil }
            return .cancelled(seq: event.seq, LeoClientToolCancellation(id: event.id, agent: event.agent, reason: event.reason))
        default:
            guard let sequence = try? decoder.decode(Sequence.self, from: data) else { return nil }
            return .other(seq: sequence.seq)
        }
    }

    public static func decode(_ raw: LeoSSEEvent) -> Self? {
        decode(name: raw.name, data: Data(raw.data.utf8))
    }
}

/// A `client_tool.request` event body: the full request on a provider stream,
/// only its id on any other stream (so `seq` stays contiguous).
public enum LeoClientToolsRequestPayload: Decodable, Equatable, Sendable {
    case full(LeoClientToolRequest)
    case redacted(id: String)

    private struct IDOnly: Decodable { let id: String }

    public init(from decoder: any Decoder) throws {
        if let full = try? LeoClientToolRequest(from: decoder) {
            self = .full(full)
        } else {
            self = .redacted(id: try IDOnly(from: decoder).id)
        }
    }
}

/// A `client_tool.cancelled` event. `agent` and `reason`
/// (`timeout` / `cancelled` / `agent_gone`) are absent on a redacted frame.
public struct LeoClientToolCancellation: Equatable, Sendable {
    public let id: String
    public let agent: String?
    public let reason: String?

    public init(id: String, agent: String?, reason: String?) {
        self.id = id
        self.agent = agent
        self.reason = reason
    }
}
