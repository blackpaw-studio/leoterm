import Foundation

/// A daemon's Leo Chat API: threads, pages, sending, uploads, answers and
/// read marks.
public protocol LeoChatClient: Sendable {
    func threads() async throws -> [LeoChatThread]
    func messages(agent: String, query: LeoChatPageQuery) async throws -> LeoChatPage
    func send(agent: String, _ draft: LeoChatDraft) async throws -> LeoChatMessage
    func upload(_ upload: LeoChatUpload) async throws -> LeoChatAttachment
    func download(attachmentID: String) async throws -> Data
    /// Answers an `ask` or `permission`; the updated message when the
    /// daemon returned it.
    func answer(agent: String, messageID: String, value: String) async throws -> LeoChatMessage?
    func markRead(agent: String, upTo messageID: String) async throws
}

/// One request/response round trip; a status is a response, only failing
/// to get one throws.
public protocol LeoChatTransport: Sendable {
    func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse
}

/// The Mac flavor: the daemon's unix socket.
public struct LeoSocketChatTransport: LeoChatTransport {
    public let socketPath: String
    private let transport: any LeoDaemonTransport

    public init(socketPath: String, transport: any LeoDaemonTransport) {
        self.socketPath = socketPath
        self.transport = transport
    }

    public func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        try await transport.send(request, socketPath: socketPath, timeout: timeout)
    }
}

/// Which page of a thread to read. `limit` is clamped to the daemon's 1...200.
public struct LeoChatPageQuery: Equatable, Sendable {
    public static let maximumLimit = 200

    public let before: String?
    public let limit: Int?
    public let task: String?

    public init(before: String? = nil, limit: Int? = nil, task: String? = nil) {
        self.before = before
        self.limit = limit.map { min(max($0, 1), Self.maximumLimit) }
        self.task = task
    }
}

/// An outgoing message.
public struct LeoChatDraft: Equatable, Sendable {
    public let text: String
    public let replyTo: String?
    public let attachmentIDs: [String]

    public init(text: String, replyTo: String? = nil, attachmentIDs: [String] = []) {
        self.text = text
        self.replyTo = replyTo
        self.attachmentIDs = attachmentIDs
    }
}

/// `LeoChatClient` over HTTP: HTTPS on iOS (`LeoHTTPSTransport`), the unix
/// socket on the Mac (`LeoSocketChatTransport`). Same routes either way.
public struct LeoChatHTTPClient: LeoChatClient {
    static let root = "/api/v1/chat"

    public let defaultTimeout: TimeInterval
    public let mutationTimeout: TimeInterval
    /// Uploads and downloads move up to 50 MB.
    public let transferTimeout: TimeInterval
    private let transport: any LeoChatTransport
    private let boundary: String

    public init(
        transport: any LeoChatTransport, defaultTimeout: TimeInterval = 10, mutationTimeout: TimeInterval = 30,
        transferTimeout: TimeInterval = 300, boundary: String = "leo-\(UUID().uuidString)"
    ) {
        self.transport = transport
        self.defaultTimeout = defaultTimeout
        self.mutationTimeout = mutationTimeout
        self.transferTimeout = transferTimeout
        self.boundary = boundary
    }

    public func threads() async throws -> [LeoChatThread] {
        try value(try await request("GET", "\(Self.root)/threads"))
    }

    public func messages(agent: String, query: LeoChatPageQuery) async throws -> LeoChatPage {
        try value(try await request("GET", try Self.messagesPath(agent, query)))
    }

    public func send(agent: String, _ draft: LeoChatDraft) async throws -> LeoChatMessage {
        struct Body: Encodable {
            let text: String
            let reply_to: String?
            let attachment_ids: [String]?
        }
        let body = Body(text: draft.text, reply_to: draft.replyTo, attachment_ids: draft.attachmentIDs.isEmpty ? nil : draft.attachmentIDs)
        return try value(try await request("POST", try Self.agentPath(agent, "messages"), body: try JSONEncoder().encode(body)))
    }

    public func upload(_ upload: LeoChatUpload) async throws -> LeoChatAttachment {
        try upload.validated().get()
        let request = Self.uploadRequest(upload, boundary: boundary)
        return try value(try Self.checked(try await transport.send(request, timeout: transferTimeout)))
    }

    public func download(attachmentID: String) async throws -> Data {
        let path = try Self.attachmentPath(attachmentID)
        return try Self.checked(try await transport.send(LeoHTTPRequest(method: "GET", path: path), timeout: transferTimeout)).body
    }

    public func answer(agent: String, messageID: String, value answer: String) async throws -> LeoChatMessage? {
        let path = try Self.agentPath(agent, "messages/\(try LeoSocketDaemonClient.pathSegment(messageID))/answer")
        let response = try await request("POST", path, body: try JSONEncoder().encode(["value": answer]))
        let envelope = try LeoDaemonEnvelope<LeoChatMessage>.decode(response.body)
        try envelope.expectOK()
        return envelope.data
    }

    public func markRead(agent: String, upTo messageID: String) async throws {
        let response = try await request("POST", try Self.agentPath(agent, "read"), body: try JSONEncoder().encode(["up_to": messageID]))
        try LeoDaemonEnvelope<LeoChatIgnored>.decode(response.body).expectOK()
    }

    // MARK: Routes

    static func agentPath(_ agent: String, _ suffix: String) throws -> String {
        "\(root)/\(try LeoSocketDaemonClient.pathSegment(agent))/\(suffix)"
    }

    static func attachmentPath(_ id: String) throws -> String {
        "\(root)/attachments/\(try LeoSocketDaemonClient.pathSegment(id))"
    }

    static func messagesPath(_ agent: String, _ query: LeoChatPageQuery) throws -> String {
        let items = [
            query.before.map { ("before", $0) },
            query.limit.map { ("limit", String($0)) },
            query.task.map { ("task", $0) },
        ].compactMap { $0 }
        let base = try agentPath(agent, "messages")
        guard !items.isEmpty else { return base }
        let encoded = try items.map { name, value in "\(name)=\(try LeoSocketDaemonClient.pathSegment(value))" }
        return base + "?" + encoded.joined(separator: "&")
    }

    /// The `POST /api/v1/chat/uploads` request for `upload`.
    public static func uploadRequest(_ upload: LeoChatUpload, boundary: String) -> LeoHTTPRequest {
        LeoHTTPRequest(
            method: "POST", path: "\(root)/uploads", body: upload.multipartBody(boundary: boundary),
            contentType: LeoChatUpload.contentType(boundary: boundary)
        )
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> LeoHTTPResponse {
        let timeout = method == "GET" ? defaultTimeout : mutationTimeout
        return try Self.checked(try await transport.send(LeoHTTPRequest(method: method, path: path, body: body), timeout: timeout))
    }

    private func value<T: Decodable & Sendable>(_ response: LeoHTTPResponse) throws -> T {
        try LeoDaemonEnvelope<T>.decode(response.body).value()
    }

    /// A non-2xx is named by its envelope `code`, else its HTTP status; the
    /// daemon's own message is kept when it sent one.
    public static func checked(_ response: LeoHTTPResponse) throws -> LeoHTTPResponse {
        guard !(200..<300).contains(response.status) else { return response }
        let envelope = try? LeoDaemonEnvelope<LeoChatIgnored>.decode(response.body)
        throw LeoDaemonError.daemon(
            code: envelope?.code ?? LeoSocketDaemonClient.controlCode(forStatus: response.status),
            message: envelope?.error ?? "HTTP \(response.status)",
            matches: envelope?.matches ?? []
        )
    }
}

struct LeoChatIgnored: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}
