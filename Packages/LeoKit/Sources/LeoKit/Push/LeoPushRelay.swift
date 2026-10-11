import Foundation

/// Which APNs gateway the relay sends through: Debug builds get sandbox
/// tokens, Release (TestFlight, App Store) builds production ones.
public enum LeoAPNsEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

public enum LeoPushRelayError: Error, Equatable, Sendable {
    case status(Int)
    case malformedResponse
}

/// The push relay's `POST /register {apns_token, env}` → `{grant}`.
public enum LeoPushRelay {
    public static let timeout: TimeInterval = 15

    public static func registerRequest(relayURL: URL, apnsToken: Data, environment: LeoAPNsEnvironment) throws -> URLRequest {
        var request = URLRequest(url: relayURL.appending(path: "register"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = apnsToken.map { String(format: "%02x", $0) }.joined()
        request.httpBody = try JSONEncoder().encode(["apns_token": token, "env": environment.rawValue])
        return request
    }

    public static func grant(status: Int, body: Data) throws(LeoPushRelayError) -> String {
        guard (200..<300).contains(status) else { throw .status(status) }
        struct Wire: Decodable { let grant: String }
        guard let grant = try? JSONDecoder().decode(Wire.self, from: body).grant, !grant.isEmpty else { throw .malformedResponse }
        return grant
    }

    public static func register(
        relayURL: URL, apnsToken: Data, environment: LeoAPNsEnvironment, session: URLSession = .shared
    ) async throws -> String {
        let request = try registerRequest(relayURL: relayURL, apnsToken: apnsToken, environment: environment)
        let (data, response) = try await session.data(for: request)
        return try grant(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

/// What a daemon needs to push to this device: `PUT /api/v1/devices/{id}/push`.
public struct LeoPushRegistration: Encodable, Equatable, Sendable {
    public let grant: String
    /// `LeoPushKey.base64`.
    public let key: String
    public let relayURL: URL

    public init(grant: String, key: String, relayURL: URL) {
        self.grant = grant
        self.key = key
        self.relayURL = relayURL
    }

    enum CodingKeys: String, CodingKey {
        case grant, key, relayURL = "relay_url"
    }
}
