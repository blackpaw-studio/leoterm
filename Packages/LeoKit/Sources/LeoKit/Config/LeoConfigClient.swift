import Foundation

/// What `GET /version` says: the release and the optional capabilities.
public struct LeoDaemonVersionInfo: Decodable, Equatable, Sendable {
    public let version: String
    public let capabilities: [String]

    public init(version: String, capabilities: [String] = []) {
        self.version = version
        self.capabilities = capabilities
    }

    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    enum CodingKeys: String, CodingKey { case version, capabilities }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decode(String.self, forKey: .version),
            capabilities: try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        )
    }
}

/// What a daemon needs for the app to edit its settings.
public enum LeoConfigAPI {
    public static let capability = "config_api"
    /// The first leo release that serves the config API; shown as
    /// "Requires leo ≥ X". Nil until the daemon PR has a release.
    public static let minimumVersion: LeoDaemonVersion? = nil

    public static func isSupported(by info: LeoDaemonVersionInfo) -> Bool {
        info.supports(capability)
    }
}

/// A daemon's JSON config API (plan Part A), the same over the unix socket
/// and `/api/v1`. Every write names the revision it was based on; a stale one
/// throws `LeoConfigError.conflict`. `resource` is a schema resource key and
/// `name` an item of a collection resource.
public protocol LeoConfigClient: Sendable {
    func versionInfo() async throws -> LeoDaemonVersionInfo
    func schema() async throws -> LeoConfigSchema
    /// A singleton resource (`defaults`, `web`, `client`).
    func document(_ resource: String) async throws -> LeoConfigDocument
    /// Every item of a collection resource, sorted by name.
    func collection(_ resource: String) async throws -> LeoConfigCollection
    func item(_ resource: String, name: String) async throws -> LeoConfigDocument
    /// `PUT`: a present key replaces its value, `null` clears it, and an
    /// absent key keeps what is there. `name` is nil for a singleton.
    func update(_ resource: String, name: String?, patch: [String: LeoConfigValue], ifMatch: String) async throws -> LeoConfigWriteResult
    /// `POST`: `values` carries the fields an add requires beyond the name
    /// (a task's `schedule`).
    func add(_ resource: String, name: String, values: [String: LeoConfigValue], ifMatch: String) async throws -> LeoConfigWriteResult
    func rename(_ resource: String, name: String, to newName: String, ifMatch: String) async throws -> LeoConfigWriteResult
    func duplicate(_ resource: String, name: String, as newName: String, ifMatch: String) async throws -> LeoConfigWriteResult
    func delete(_ resource: String, name: String, ifMatch: String) async throws -> LeoConfigWriteResult
}

extension LeoConfigClient {
    public func add(_ resource: String, name: String, ifMatch: String) async throws -> LeoConfigWriteResult {
        try await add(resource, name: name, values: [:], ifMatch: ifMatch)
    }
}
