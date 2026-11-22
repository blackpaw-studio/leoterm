import Foundation

/// The plugin API revision this build of Leo implements.
public enum LeoPluginAPI {
    public static let supported = 2
}

/// Agent capabilities a plugin may request. `read` gates `leo.agents.list`,
/// `send` gates the `sendToAgent` action, `spawn` the `spawnAgent` action, and
/// `usage` gates `leo.agents.usage`, the `usageChanged` event and the `model` and
/// `workspace` fields on `leo.agents.list` entries. `usage` requires `read`; the
/// manifest validator refuses it alone.
public enum LeoPluginAgentVerb: String, Codable, CaseIterable, Hashable, Sendable {
    case read, send, spawn, usage
}

/// Account credentials a plugin may use through the host (apiVersion 2). Each
/// kind is a host-defined adapter with one fixed bound host: the host injects
/// the account's token only on requests to that host, and the token never
/// enters the plugin process.
public enum LeoPluginCredentialKind: String, Codable, CaseIterable, Hashable, Sendable {
    case claudeCode = "claude-code"
    case codex

    /// The only host this kind's headers are ever sent to.
    public var boundHost: String {
        switch self {
        case .claudeCode: "api.anthropic.com"
        case .codex: "chatgpt.com"
        }
    }

    /// Reader-facing name for the approval sheet and Settings.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// `permissions` block of `leo-plugin.json`. Network entries are raw host
/// patterns (`api.github.com`, `*.example.com`); parse them with
/// ``LeoPluginHostPattern``.
public struct LeoPluginPermissions: Equatable, Sendable {
    public let network: [String]
    public let secrets: Bool
    public let agents: [LeoPluginAgentVerb]
    /// Credential kinds (apiVersion 2 only; the validator refuses them on v1).
    public let credentials: [LeoPluginCredentialKind]

    public static let none = LeoPluginPermissions(network: [], secrets: false, agents: [])

    public init(
        network: [String] = [], secrets: Bool = false, agents: [LeoPluginAgentVerb] = [],
        credentials: [LeoPluginCredentialKind] = []
    ) {
        self.network = network
        self.secrets = secrets
        self.agents = agents
        self.credentials = credentials
    }
}

public struct LeoPluginViewContribution: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sfSymbol: String

    public init(id: String, title: String, sfSymbol: String) {
        self.id = id
        self.title = title
        self.sfSymbol = sfSymbol
    }
}

public struct LeoPluginRowAccessoryContribution: Equatable, Sendable {
    public let id: String

    public init(id: String) { self.id = id }
}

public struct LeoPluginCommandContribution: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sfSymbol: String?

    public init(id: String, title: String, sfSymbol: String? = nil) {
        self.id = id
        self.title = title
        self.sfSymbol = sfSymbol
    }
}

public struct LeoPluginSidebarSectionContribution: Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A pane under the agent's terminal/chat view (at most one per plugin).
public struct LeoPluginPaneContribution: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sfSymbol: String?

    public init(id: String, title: String, sfSymbol: String? = nil) {
        self.id = id
        self.title = title
        self.sfSymbol = sfSymbol
    }
}

public struct LeoPluginContributions: Equatable, Sendable {
    public let views: [LeoPluginViewContribution]
    public let rowAccessories: [LeoPluginRowAccessoryContribution]
    public let commands: [LeoPluginCommandContribution]
    public let sidebarSections: [LeoPluginSidebarSectionContribution]
    public let panes: [LeoPluginPaneContribution]

    public static let none = LeoPluginContributions()

    public init(
        views: [LeoPluginViewContribution] = [],
        rowAccessories: [LeoPluginRowAccessoryContribution] = [],
        commands: [LeoPluginCommandContribution] = [],
        sidebarSections: [LeoPluginSidebarSectionContribution] = [],
        panes: [LeoPluginPaneContribution] = []
    ) {
        self.views = views
        self.rowAccessories = rowAccessories
        self.commands = commands
        self.sidebarSections = sidebarSections
        self.panes = panes
    }
}

/// A parsed `leo-plugin.json`. Decoding is strict (unknown keys are errors) but
/// semantic checks (id shape, `main` escapes, id uniqueness, API version) live
/// in ``LeoPluginManifestValidator``; use that rather than decoding directly.
public struct LeoPluginManifest: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let apiVersion: Int
    public let main: String
    public let permissions: LeoPluginPermissions
    public let contributes: LeoPluginContributions

    public init(
        id: String,
        name: String,
        version: String,
        apiVersion: Int,
        main: String,
        permissions: LeoPluginPermissions = .none,
        contributes: LeoPluginContributions = .none
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.main = main
        self.permissions = permissions
        self.contributes = contributes
    }
}

// MARK: - Strict decoding

/// A decoding failure with a reader-facing reason (surfaced as the install
/// refusal), as opposed to Foundation's coding-path style errors.
struct LeoPluginManifestIssue: Error, Equatable {
    let reason: String
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Throws when the keyed container holds any key outside `allowed`.
/// `noun` names what an unknown key is ("key", "permission", ...).
private func rejectUnknownKeys(
    _ decoder: Decoder, allowed: Set<String>, in context: String, noun: String = "key"
) throws {
    let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
    let unknown = keys.filter { !allowed.contains($0) }.sorted()
    guard let first = unknown.first else { return }
    throw LeoPluginManifestIssue(reason: "unknown \(noun) '\(first)' in \(context)")
}

extension LeoPluginAgentVerb {
    // Custom decode so an unknown verb gets a readable reason.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let verb = LeoPluginAgentVerb(rawValue: raw) else {
            throw LeoPluginManifestIssue(reason: "unknown agent permission '\(raw)' (expected read, send, spawn or usage)")
        }
        self = verb
    }
}

extension LeoPluginCredentialKind {
    // Custom decode so an unknown kind gets a readable reason.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = LeoPluginCredentialKind(rawValue: raw) else {
            throw LeoPluginManifestIssue(reason: "unknown credential kind '\(raw)' (expected claude-code or codex)")
        }
        self = kind
    }
}

extension LeoPluginPermissions: Codable {
    private enum CodingKeys: String, CodingKey { case network, secrets, agents, credentials }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder, allowed: ["network", "secrets", "agents", "credentials"], in: "permissions", noun: "permission")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            network: try c.decodeIfPresent([String].self, forKey: .network) ?? [],
            secrets: try c.decodeIfPresent(Bool.self, forKey: .secrets) ?? false,
            agents: try c.decodeIfPresent([LeoPluginAgentVerb].self, forKey: .agents) ?? [],
            credentials: try c.decodeIfPresent([LeoPluginCredentialKind].self, forKey: .credentials) ?? []
        )
    }

    /// `credentials` is written only when non-empty, so a registry.json without
    /// credential grants stays readable by an older Leo's strict decode.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(network, forKey: .network)
        try c.encode(secrets, forKey: .secrets)
        try c.encode(agents, forKey: .agents)
        if !credentials.isEmpty { try c.encode(credentials, forKey: .credentials) }
    }
}

extension LeoPluginViewContribution: Codable {
    private enum CodingKeys: String, CodingKey { case id, title, sfSymbol }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["id", "title", "sfSymbol"], in: "contributes.views")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            sfSymbol: try c.decode(String.self, forKey: .sfSymbol)
        )
    }
}

extension LeoPluginRowAccessoryContribution: Codable {
    private enum CodingKeys: String, CodingKey { case id }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["id"], in: "contributes.rowAccessories")
        self.init(id: try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .id))
    }
}

extension LeoPluginCommandContribution: Codable {
    private enum CodingKeys: String, CodingKey { case id, title, sfSymbol }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["id", "title", "sfSymbol"], in: "contributes.commands")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            sfSymbol: try c.decodeIfPresent(String.self, forKey: .sfSymbol)
        )
    }
}

extension LeoPluginSidebarSectionContribution: Codable {
    private enum CodingKeys: String, CodingKey { case id, title }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["id", "title"], in: "contributes.sidebarSections")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title))
    }
}

extension LeoPluginPaneContribution: Codable {
    private enum CodingKeys: String, CodingKey { case id, title, sfSymbol }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["id", "title", "sfSymbol"], in: "contributes.panes")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            sfSymbol: try c.decodeIfPresent(String.self, forKey: .sfSymbol)
        )
    }
}

extension LeoPluginContributions: Codable {
    private enum CodingKeys: String, CodingKey { case views, rowAccessories, commands, sidebarSections, panes }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder, allowed: ["views", "rowAccessories", "commands", "sidebarSections", "panes"], in: "contributes",
            noun: "contribution kind")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            views: try c.decodeIfPresent([LeoPluginViewContribution].self, forKey: .views) ?? [],
            rowAccessories: try c.decodeIfPresent([LeoPluginRowAccessoryContribution].self, forKey: .rowAccessories) ?? [],
            commands: try c.decodeIfPresent([LeoPluginCommandContribution].self, forKey: .commands) ?? [],
            sidebarSections: try c.decodeIfPresent([LeoPluginSidebarSectionContribution].self, forKey: .sidebarSections) ?? [],
            panes: try c.decodeIfPresent([LeoPluginPaneContribution].self, forKey: .panes) ?? []
        )
    }
}

extension LeoPluginManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, version, apiVersion, main, permissions, contributes
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder, allowed: ["id", "name", "version", "apiVersion", "main", "permissions", "contributes"],
            in: "the manifest")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            version: try c.decode(String.self, forKey: .version),
            apiVersion: try c.decode(Int.self, forKey: .apiVersion),
            main: try c.decode(String.self, forKey: .main),
            permissions: try c.decodeIfPresent(LeoPluginPermissions.self, forKey: .permissions) ?? .none,
            contributes: try c.decodeIfPresent(LeoPluginContributions.self, forKey: .contributes) ?? .none
        )
    }
}
