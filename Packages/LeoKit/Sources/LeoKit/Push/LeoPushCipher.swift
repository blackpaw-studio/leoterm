import CryptoKit
import Foundation

/// What a daemon encrypts into a push:
/// `{"v":1,"daemon_id","agent","kind","title","ts"}` plus an optional `body`.
public struct LeoPushPayload: Codable, Equatable, Sendable {
    public static let version = 1

    public let daemonID: String
    public let agent: String
    /// The daemon's attention state string.
    public let kind: String
    /// The short state line: "Has a question", "Finished".
    public let title: String
    /// The detail (the question, the tool, a message preview), already
    /// sanitized by the daemon; empty when the daemon sent none.
    public let body: String
    /// Unix seconds.
    public let ts: Int
    /// Leo Chat: the message a `chat` push (or a permission attention
    /// push) is about, its kind (`ask`, `permission`, ...), an `ask`'s
    /// input type, and a `buttons` ask's choices when they fit. All
    /// optional; older daemons send none, and a malformed one is dropped:
    /// a push is a hint, not the record.
    public let messageID: String?
    public let messageKind: String?
    public let options: [LeoChatOption]
    /// `buttons|radio|checkboxes|text` for an `ask`.
    public let inputType: String?

    public init(
        daemonID: String, agent: String, kind: String, title: String, body: String = "", ts: Int,
        messageID: String? = nil, messageKind: String? = nil, options: [LeoChatOption] = [], inputType: String? = nil
    ) {
        self.daemonID = daemonID
        self.agent = agent
        self.kind = kind
        self.title = title
        self.body = body
        self.ts = ts
        self.messageID = messageID
        self.messageKind = messageKind
        self.options = options
        self.inputType = inputType
    }

    enum CodingKeys: String, CodingKey {
        case v, daemonID = "daemon_id", agent, kind, title, body, ts, options
        case messageID = "message_id"
        case messageKind = "message_kind"
        case inputType = "input_type"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == Self.version else { throw LeoPushError.unsupportedVersion(version) }
        daemonID = try container.decode(String.self, forKey: .daemonID)
        agent = try container.decode(String.self, forKey: .agent)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        ts = try container.decode(Int.self, forKey: .ts)
        messageID = ((try? container.decodeIfPresent(String.self, forKey: .messageID)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        messageKind = ((try? container.decodeIfPresent(String.self, forKey: .messageKind)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        options = ((try? container.decodeIfPresent(LeoLenientArray<LeoChatOption>.self, forKey: .options)) ?? nil)?.elements ?? []
        inputType = ((try? container.decodeIfPresent(String.self, forKey: .inputType)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .v)
        try container.encode(daemonID, forKey: .daemonID)
        try container.encode(agent, forKey: .agent)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        if !body.isEmpty { try container.encode(body, forKey: .body) }
        try container.encode(ts, forKey: .ts)
        try container.encodeIfPresent(messageID, forKey: .messageID)
        try container.encodeIfPresent(messageKind, forKey: .messageKind)
        if !options.isEmpty { try container.encode(options, forKey: .options) }
        try container.encodeIfPresent(inputType, forKey: .inputType)
    }
}

public enum LeoPushError: Error, Equatable, Sendable {
    /// Not base64, or too short to hold a nonce and tag.
    case malformedCiphertext
    /// The wrong key, or bytes changed in transit.
    case authenticationFailed
    /// Decrypted, but not a push payload.
    case malformedPayload
    case unsupportedVersion(Int)
}

/// The push wire format: base64(nonce(12) ‖ AES-256-GCM(key, plaintext,
/// aad = "leo-push-v1") ‖ tag(16)).
public enum LeoPushCipher {
    public static let aad = Data("leo-push-v1".utf8)

    public static func open(_ ciphertext: String, key: LeoPushKey) throws(LeoPushError) -> LeoPushPayload {
        let plaintext = try openPlaintext(ciphertext, key: key)
        do {
            return try JSONDecoder().decode(LeoPushPayload.self, from: plaintext)
        } catch let error as LeoPushError {
            throw error
        } catch {
            throw .malformedPayload
        }
    }

    public static func seal(_ payload: LeoPushPayload, key: LeoPushKey) throws -> String {
        try seal(plaintext: JSONEncoder().encode(payload), key: key)
    }

    /// Seals arbitrary bytes; how tests and the debug tooling build pushes.
    public static func seal(plaintext: Data, key: LeoPushKey) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: key.symmetricKey, authenticating: aad)
        guard let combined = box.combined else { throw LeoPushError.malformedCiphertext }
        return combined.base64EncodedString()
    }

    private static func openPlaintext(_ ciphertext: String, key: LeoPushKey) throws(LeoPushError) -> Data {
        // A 12-byte nonce and a 16-byte tag around at least one byte.
        guard let bytes = Data(base64Encoded: ciphertext), bytes.count > 28,
              let box = try? AES.GCM.SealedBox(combined: bytes) else { throw .malformedCiphertext }
        do {
            return try AES.GCM.open(box, using: key.symmetricKey, authenticating: aad)
        } catch {
            throw .authenticationFailed
        }
    }
}
