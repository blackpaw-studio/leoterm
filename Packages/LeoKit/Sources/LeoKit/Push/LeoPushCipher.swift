import CryptoKit
import Foundation

/// What a daemon encrypts into a push: `{"v":1,"daemon_id","agent","kind","title","ts"}`.
public struct LeoPushPayload: Codable, Equatable, Sendable {
    public static let version = 1

    public let daemonID: String
    public let agent: String
    /// The daemon's attention state string.
    public let kind: String
    /// The daemon's human summary of what the agent needs.
    public let title: String
    /// Unix seconds.
    public let ts: Int

    public init(daemonID: String, agent: String, kind: String, title: String, ts: Int) {
        self.daemonID = daemonID
        self.agent = agent
        self.kind = kind
        self.title = title
        self.ts = ts
    }

    enum CodingKeys: String, CodingKey {
        case v, daemonID = "daemon_id", agent, kind, title, ts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == Self.version else { throw LeoPushError.unsupportedVersion(version) }
        daemonID = try container.decode(String.self, forKey: .daemonID)
        agent = try container.decode(String.self, forKey: .agent)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        ts = try container.decode(Int.self, forKey: .ts)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .v)
        try container.encode(daemonID, forKey: .daemonID)
        try container.encode(agent, forKey: .agent)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(ts, forKey: .ts)
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
