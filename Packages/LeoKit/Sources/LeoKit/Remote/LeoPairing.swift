import Foundation

/// What `leo pair` prints, as a QR code and as one line of JSON:
/// `{daemon_id, name, urls[], pairing_code}`.
public struct LeoPairingPayload: Equatable, Sendable {
    public let daemonID: String
    public let name: String
    /// The origins to try, in order; only absolute http(s) URLs survive.
    public let urls: [URL]
    public let pairingCode: String

    public init(daemonID: String, name: String, urls: [URL], pairingCode: String) {
        self.daemonID = daemonID
        self.name = name
        self.urls = urls
        self.pairingCode = pairingCode
    }

    /// Parses pasted or scanned text; surrounding whitespace is ignored.
    public static func parse(_ text: String) throws(LeoPairingError) -> Self {
        struct Wire: Decodable {
            let daemon_id: String
            let name: String?
            let urls: [String]
            let pairing_code: String
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(trimmed.utf8)) else { throw .malformed }
        let id = wire.daemon_id.trimmingCharacters(in: .whitespaces)
        let code = wire.pairing_code.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !code.isEmpty else { throw .malformed }
        let urls = wire.urls.compactMap(Self.origin)
        guard !urls.isEmpty else { throw .noUsableURL }
        let name = wire.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return Self(daemonID: id, name: name.isEmpty ? id : name, urls: urls, pairingCode: code)
    }

    private static func origin(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}

public enum LeoPairingError: Error, Equatable, Sendable {
    /// Not a `leo pair` payload at all.
    case malformed
    /// A payload whose URLs are all unusable (none is an http(s) origin).
    case noUsableURL
}

extension LeoPairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformed: "That isn't a Leo pairing code. Run `leo pair` on the machine and paste the line it prints."
        case .noUsableURL: "The pairing code has no address this device can reach. Set web.public_urls on the daemon."
        }
    }
}

/// `POST /api/v1/pair`'s answer: this device's id and bearer token.
public struct LeoPairingGrant: Decodable, Equatable, Sendable {
    public let deviceID: String
    public let token: String

    public init(deviceID: String, token: String) {
        self.deviceID = deviceID
        self.token = token
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case token
    }
}
