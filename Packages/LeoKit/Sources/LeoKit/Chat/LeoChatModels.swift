import Foundation
import OSLog

/// Leo Chat wire types (spec 2026-10-12-leo-chat). Field names are the
/// daemon's snake_case; display fields decode leniently, but an `ask`
/// without an `input`, or a malformed `input` or `answer`, fails the
/// message: a question the app can't answer correctly must not show as
/// one. Pages and thread lists drop (and log) messages that fail.
///
/// A message: `{id, agent, direction: in|out, kind, text, transcript?,
/// reply_to?, task?, run_id?, state?, answer?: {values, text}, input?,
/// ts, attachments?}`. `ts` is RFC 3339 or Unix seconds/milliseconds.
public struct LeoChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case inbound = "in"
        case outbound = "out"
    }

    public enum Kind: String, Codable, Sendable {
        case ask, file, permission, system, task, text, voice
        /// A kind this build doesn't know; shown as plain text.
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public let id: String
    public let agent: String
    public let direction: Direction
    public let kind: Kind
    public let text: String
    public let transcript: String?
    public let replyTo: String?
    public let task: String?
    public let runID: String?
    /// Kind-specific: `pending|delivered|failed` for inbound messages,
    /// `open|answered|expired` for `ask` and `permission`.
    public let state: String?
    public let answer: LeoChatAnswer?
    public let ts: Date
    public let attachments: [LeoChatAttachment]
    /// How an `ask` is answered; a `permission` prompt's allow/deny buttons
    /// (absent on rows from before leo #268: see `answerInput`).
    public let input: LeoChatInput?

    public init(
        id: String, agent: String, direction: Direction, kind: Kind, text: String, transcript: String? = nil,
        replyTo: String? = nil, task: String? = nil, runID: String? = nil, state: String? = nil, answer: LeoChatAnswer? = nil,
        ts: Date, attachments: [LeoChatAttachment] = [], input: LeoChatInput? = nil
    ) {
        self.id = id
        self.agent = agent
        self.direction = direction
        self.kind = kind
        self.text = text
        self.transcript = transcript
        self.replyTo = replyTo
        self.task = task
        self.runID = runID
        self.state = state
        self.answer = answer
        self.ts = ts
        self.attachments = attachments
        self.input = input
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, direction, kind, text, transcript, task, state, answer, ts, attachments, input
        case replyTo = "reply_to"
        case runID = "run_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agent = try container.decode(String.self, forKey: .agent)
        direction = try container.decode(Direction.self, forKey: .direction)
        kind = try container.decode(Kind.self, forKey: .kind)
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        transcript = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .transcript))
        replyTo = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .replyTo))
        task = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .task))
        runID = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .runID))
        state = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .state))
        answer = try container.decodeIfPresent(LeoChatAnswer.self, forKey: .answer)
        ts = try container.decode(LeoChatTimestamp.self, forKey: .ts).date
        attachments = ((try? container.decodeIfPresent(LeoLenientArray<LeoChatAttachment>.self, forKey: .attachments)) ?? nil)?.elements ?? []
        input = try container.decodeIfPresent(LeoChatInput.self, forKey: .input)
        if kind == .ask, input == nil {
            throw DecodingError.keyNotFound(CodingKeys.input, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "An ask needs an input"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(agent, forKey: .agent)
        try container.encode(direction, forKey: .direction)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        try container.encodeIfPresent(task, forKey: .task)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(answer, forKey: .answer)
        try container.encode(ts.timeIntervalSince1970, forKey: .ts)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(input, forKey: .input)
    }

    private static func nonEmpty(_ value: String??) -> String? {
        guard let value = value ?? nil, !value.isEmpty else { return nil }
        return value
    }

    /// An `ask` or `permission` still waiting for an answer.
    public var isOpen: Bool { (kind == .ask || kind == .permission) && state == "open" }
    public var isFailed: Bool { state == "failed" }
    public var isPending: Bool { direction == .inbound && state == "pending" }

    /// The text to show: a voice note's transcript, else its text.
    public var displayText: String {
        if kind == .voice, let transcript { return transcript }
        return text
    }

    /// How this message is answered: its `input`, or allow/deny for a
    /// `permission` row stored without one; nil for anything else.
    public var answerInput: LeoChatInput? {
        if let input { return input }
        return kind == .permission ? .permission : nil
    }
}

public struct LeoChatOption: Codable, Equatable, Hashable, Sendable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }

    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case value, label }
        let container = try decoder.container(keyedBy: Keys.self)
        value = try container.decode(String.self, forKey: .value)
        label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? value
    }
}

/// A stored attachment. `available` is false once the daemon pruned the
/// file (the row outlives it).
public struct LeoChatAttachment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let mime: String
    public let bytes: Int
    public let available: Bool

    public init(id: String, filename: String, mime: String, bytes: Int, available: Bool = true) {
        self.id = id
        self.filename = filename
        self.mime = mime
        self.bytes = bytes
        self.available = available
    }

    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case id, filename, mime, bytes, available }
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        filename = (try? container.decodeIfPresent(String.self, forKey: .filename)) ?? id
        mime = (try? container.decodeIfPresent(String.self, forKey: .mime)) ?? "application/octet-stream"
        bytes = (try? container.decodeIfPresent(Int.self, forKey: .bytes)) ?? 0
        available = (try? container.decodeIfPresent(Bool.self, forKey: .available)) ?? true
    }

    public var isImage: Bool { mime.lowercased().hasPrefix("image/") }
    public var isAudio: Bool { mime.lowercased().hasPrefix("audio/") }
}

/// One agent's thread as the Chats list shows it.
public struct LeoChatThread: Decodable, Equatable, Identifiable, Sendable {
    public let agent: String
    public var lastMessage: LeoChatMessage?
    public var unread: Int
    public let isPinned: Bool

    public var id: String { agent }

    public init(agent: String, lastMessage: LeoChatMessage? = nil, unread: Int = 0, isPinned: Bool = false) {
        self.agent = agent
        self.lastMessage = lastMessage
        self.unread = unread
        self.isPinned = isPinned
    }

    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey {
            case agent, unread, pinned
            case lastMessage = "last_message"
            case unreadCount = "unread_count"
        }
        let container = try decoder.container(keyedBy: Keys.self)
        agent = try container.decode(String.self, forKey: .agent)
        lastMessage = (try? container.decodeIfPresent(LeoChatMessage.self, forKey: .lastMessage)) ?? nil
        unread = ((try? container.decodeIfPresent(Int.self, forKey: .unread)) ?? nil)
            ?? ((try? container.decodeIfPresent(Int.self, forKey: .unreadCount)) ?? nil) ?? 0
        isPinned = (try? container.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
    }
}

/// `GET /api/v1/chat/threads`: `{threads: [Thread]}` (a bare array also
/// decodes). Malformed threads are dropped.
public struct LeoChatThreadList: Decodable, Equatable, Sendable {
    public let threads: [LeoChatThread]

    public init(from decoder: any Decoder) throws {
        if let bare = try? LeoLenientArray<LeoChatThread>(from: decoder) {
            threads = bare.elements
            return
        }
        enum Keys: String, CodingKey { case threads }
        threads = try decoder.container(keyedBy: Keys.self).decode(LeoLenientArray<LeoChatThread>.self, forKey: .threads).elements
    }
}

/// One page of a thread, newest first. Decodes `{messages, has_more}` or a
/// bare array (then `hasMore` is false).
public struct LeoChatPage: Decodable, Equatable, Sendable {
    public let messages: [LeoChatMessage]
    public let hasMore: Bool

    public init(messages: [LeoChatMessage], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }

    public init(from decoder: any Decoder) throws {
        if let bare = try? LeoLenientArray<LeoChatMessage>(from: decoder) {
            self.init(messages: bare.elements, hasMore: false)
            return
        }
        enum Keys: String, CodingKey { case messages; case hasMore = "has_more" }
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(
            messages: try container.decode(LeoLenientArray<LeoChatMessage>.self, forKey: .messages).elements,
            hasMore: (try? container.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        )
    }
}

/// A `chat.*` event from `/api/v1/events`.
public enum LeoChatEvent: Equatable, Sendable {
    /// `chat.message`: a new message in a thread.
    case message(LeoChatMessage)
    /// `chat.updated`: a message's transcript, state or answer changed;
    /// carries the whole message.
    case updated(LeoChatMessage)

    public var message: LeoChatMessage {
        switch self {
        case .message(let message), .updated(let message): message
        }
    }
}

/// Decodes the elements it can and drops the rest, logging each drop: a
/// dropped message is a contract mismatch worth finding.
struct LeoLenientArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                LeoLog.logger(category: "chat").fault(
                    "Dropped an undecodable \(String(describing: Element.self), privacy: .public): \(String(describing: error), privacy: .public)"
                )
                _ = try? container.decode(LeoSkipped.self)
            }
        }
        self.elements = elements
    }
}

private struct LeoSkipped: Decodable {}

/// RFC 3339 (with or without fractional seconds), or a Unix timestamp in
/// seconds or milliseconds.
struct LeoChatTimestamp: Decodable {
    let date: Date

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
            return
        }
        let string = try container.decode(String.self)
        if let parsed = Self.parse(string) {
            date = parsed
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable timestamp \(string)")
        }
    }

    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? fractional.parse(string)
    }
}
