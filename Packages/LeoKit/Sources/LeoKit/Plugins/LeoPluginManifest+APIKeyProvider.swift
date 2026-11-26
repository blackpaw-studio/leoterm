import Foundation

/// An `api-key` credential a plugin declares (apiVersion 2): the user pastes a
/// key for `provider`, Leo keeps it in the Keychain, and Leo adds it only to
/// requests for `host`. The plugin never sees the key.
public struct LeoPluginAPIKeyProvider: Codable, Hashable, Sendable {
    /// The manifest `kind` of an api-key credential object.
    public static let kind = "api-key"

    /// Lowercase slug, unique within the plugin.
    public let provider: String
    /// Reader-facing service name ("DeepSeek").
    public let label: String
    /// The one exact host the key is ever sent to.
    public let host: String

    public init(provider: String, label: String, host: String) {
        self.provider = provider
        self.label = label
        self.host = host
    }

    private enum CodingKeys: String, CodingKey { case kind, provider, label, host }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["kind", "provider", "label", "host"], in: "permissions.credentials")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        guard kind == Self.kind else {
            if LeoPluginCredentialKind(rawValue: kind) != nil {
                throw LeoPluginManifestIssue(reason: "credential kind '\(kind)' must be a plain string, not an object")
            }
            throw LeoPluginManifestIssue(reason: "unknown credential kind '\(kind)' (expected claude-code, codex or api-key)")
        }
        self.init(
            provider: try c.decode(String.self, forKey: .provider),
            label: try c.decode(String.self, forKey: .label),
            host: try c.decode(String.self, forKey: .host))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.kind, forKey: .kind)
        try c.encode(provider, forKey: .provider)
        try c.encode(label, forKey: .label)
        try c.encode(host, forKey: .host)
    }
}

/// One entry of the manifest's mixed `credentials` array: an account kind as a
/// string, or an `api-key` provider as an object.
enum LeoPluginCredentialEntry: Codable {
    case account(LeoPluginCredentialKind)
    case apiKey(LeoPluginAPIKeyProvider)

    var accountKind: LeoPluginCredentialKind? {
        if case .account(let kind) = self { return kind }
        return nil
    }

    var apiKeyProvider: LeoPluginAPIKeyProvider? {
        if case .apiKey(let provider) = self { return provider }
        return nil
    }

    init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            guard raw != LeoPluginAPIKeyProvider.kind else {
                throw LeoPluginManifestIssue(
                    reason: "credential kind 'api-key' must be an object {kind, provider, label, host}")
            }
            self = .account(try LeoPluginCredentialKind(from: decoder))
        } else {
            self = .apiKey(try LeoPluginAPIKeyProvider(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .account(let kind):
            var c = encoder.singleValueContainer()
            try c.encode(kind)
        case .apiKey(let provider):
            try provider.encode(to: encoder)
        }
    }
}
