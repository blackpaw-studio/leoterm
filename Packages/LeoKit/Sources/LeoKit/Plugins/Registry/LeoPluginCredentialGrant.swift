import Foundation

/// One credential the user granted a plugin, app-owned and stored on the
/// plugin's record. An account grant names a folder (a Claude config dir or a
/// `CODEX_HOME`) whose token is read fresh on every use; an API-key grant names
/// a provider, and its key lives only in the Keychain (`LeoPluginAPIKeyVault`).
/// A grant never holds a token or a key.
public struct LeoPluginCredentialGrant: Codable, Equatable, Sendable {
    public enum Subject: Equatable, Sendable {
        /// Absolute and standardized, no trailing slash (`LeoPluginCredentialPath`).
        /// On a remote machine this is that machine's path, as its daemon listed it.
        case account(LeoPluginCredentialKind, path: String)
        /// A pasted key for the manifest's `provider`; `name` is the user's label for it.
        case apiKey(provider: String, name: String)
    }

    /// Opaque to the plugin; the only thing it can name the grant by.
    public let id: String
    public let subject: Subject
    /// Where the account lives. Grants saved before machines existed decode as
    /// `.local`; API keys are always `.local`.
    public let machine: LeoHostID

    public init(id: String, kind: LeoPluginCredentialKind, path: String, machine: LeoHostID = .local) {
        self.id = id
        subject = .account(kind, path: path)
        self.machine = machine
    }

    public init(id: String, apiKeyProvider provider: String, name: String) {
        self.id = id
        subject = .apiKey(provider: provider, name: name)
        machine = .local
    }

    private enum CodingKeys: String, CodingKey { case id, kind, path, provider, name, machine }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if try container.decode(String.self, forKey: .kind) == LeoPluginAPIKeyProvider.kind {
            subject = .apiKey(
                provider: try container.decode(String.self, forKey: .provider), name: try container.decode(String.self, forKey: .name))
            machine = .local
        } else {
            subject = .account(
                try container.decode(LeoPluginCredentialKind.self, forKey: .kind), path: try container.decode(String.self, forKey: .path))
            machine = try container.decodeIfPresent(LeoHostID.self, forKey: .machine) ?? .local
        }
    }

    /// Account grants encode exactly as they did before API keys existed.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch subject {
        case .account(let kind, let path):
            try container.encode(kind, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .apiKey(let provider, let name):
            try container.encode(LeoPluginAPIKeyProvider.kind, forKey: .kind)
            try container.encode(provider, forKey: .provider)
            try container.encode(name, forKey: .name)
        }
        try container.encode(machine, forKey: .machine)
    }

    public var isRemote: Bool { machine != .local }

    public var accountKind: LeoPluginCredentialKind? {
        if case .account(let kind, _) = subject { return kind }
        return nil
    }

    public var accountPath: String? {
        if case .account(_, let path) = subject { return path }
        return nil
    }

    public var apiKeyProvider: String? {
        if case .apiKey(let provider, _) = subject { return provider }
        return nil
    }

    /// What the plugin sees for an account: the folder's name and a path for
    /// display. A remote path stays absolute, since this Mac's home says nothing
    /// about that machine's. Nil for an API key.
    public func accountHandle(home: String) -> LeoPluginCredentialHandle? {
        guard case .account(let kind, let path) = subject else { return nil }
        switch machine {
        case .local:
            return LeoPluginCredentialHandle(
                id: id, kind: kind, label: (path as NSString).lastPathComponent,
                path: LeoPluginCredentialPath.abbreviate(path, home: home))
        case .remote(let name):
            return LeoPluginCredentialHandle(
                id: id, kind: kind, label: (path as NSString).lastPathComponent, path: path, machine: name)
        }
    }

    /// What the plugin sees for an API key: never the key. Nil for an account.
    public var apiKeyHandle: LeoPluginAPIKeyHandle? {
        guard case .apiKey(let provider, let name) = subject else { return nil }
        return LeoPluginAPIKeyHandle(id: id, provider: provider, name: name)
    }
}

/// An API-key grant as plugin code sees it: `{id, kind: "api-key", provider, name}`.
public struct LeoPluginAPIKeyHandle: Equatable, Sendable {
    public let id: String
    public let provider: String
    public let name: String

    public init(id: String, provider: String, name: String) {
        self.id = id
        self.provider = provider
        self.name = name
    }
}

/// A grant as the bridge hands it to plugin code (`leo.credentials.list()`).
public struct LeoPluginCredentialHandle: Codable, Equatable, Sendable {
    public let id: String
    public let kind: LeoPluginCredentialKind
    public let label: String
    public let path: String
    /// The machine's name, for an account on another machine. Nil for this Mac,
    /// so plugins never match on a display string.
    public let machine: String?

    public init(id: String, kind: LeoPluginCredentialKind, label: String, path: String, machine: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.path = path
        self.machine = machine
    }
}

/// Path rules for account folders. Lexical only: symlinks are not resolved,
/// because Claude Code hashes the path as it was given (see the service-name
/// derivation in `LeoPluginCredentials`).
public enum LeoPluginCredentialPath {
    /// `~` expanded against `home`, `.`/`..` collapsed, no trailing slash.
    /// Nil for a relative or empty path.
    public static func standardize(_ raw: String, home: String) -> String? {
        let expanded: String
        if raw == "~" {
            expanded = home
        } else if raw.hasPrefix("~/") {
            expanded = home + raw.dropFirst(1)
        } else {
            expanded = raw
        }
        guard expanded.hasPrefix("/") else { return nil }
        let standardized = URL(fileURLWithPath: expanded).standardized.path
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    /// `path` with `home` shown as `~` when it is inside it.
    public static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}

extension LeoPluginRegistry {
    public func grants(for pluginID: String) -> [LeoPluginCredentialGrant] {
        record(for: pluginID)?.credentialGrants ?? []
    }

    /// Records an account for `pluginID`. Nil when the plugin is unknown, the
    /// kind isn't approved, or the path isn't absolute. The same kind and
    /// folder granted twice returns the existing grant.
    public mutating func addGrant(
        pluginID: String, kind: LeoPluginCredentialKind, path: String, id: String, machine: LeoHostID = .local
    ) -> LeoPluginCredentialGrant? {
        guard let record = record(for: pluginID), record.approvedPermissions.credentials.contains(kind),
            path.hasPrefix("/"), let standardized = LeoPluginCredentialPath.standardize(path, home: "/")
        else { return nil }
        if let existing = record.credentialGrants.first(where: { $0.subject == .account(kind, path: standardized) && $0.machine == machine }) {
            return existing
        }
        let grant = LeoPluginCredentialGrant(id: id, kind: kind, path: standardized, machine: machine)
        update(pluginID) { $0.credentialGrants.append(grant) }
        return grant
    }

    /// Records an API-key grant (the key itself is already in the Keychain under
    /// `id`). Nil when the plugin is unknown, the provider isn't approved, or the
    /// name is blank, longer than 64 characters or has control characters.
    /// Several keys for one provider are allowed.
    public mutating func addAPIKeyGrant(pluginID: String, provider: String, name: String, id: String) -> LeoPluginCredentialGrant? {
        guard let record = record(for: pluginID), record.approvedPermissions.apiKeys.contains(where: { $0.provider == provider }),
            LeoPluginCredentialGrant.isValidAPIKeyName(name)
        else { return nil }
        let grant = LeoPluginCredentialGrant(id: id, apiKeyProvider: provider, name: name)
        update(pluginID) { $0.credentialGrants.append(grant) }
        return grant
    }

    public mutating func removeGrant(pluginID: String, grantID: String) {
        update(pluginID) { $0.credentialGrants.removeAll { $0.id == grantID } }
    }
}

extension LeoPluginCredentialGrant {
    public static let maxAPIKeyNameLength = 64

    /// 1–64 characters, not blank, no control characters.
    public static func isValidAPIKeyName(_ name: String) -> Bool {
        (1...maxAPIKeyNameLength).contains(name.count) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !LeoPluginManifestValidator.hasControlCharacters(name)
    }

    /// Whether this grant survives the user approving `new` over `old`: its
    /// account kind is still declared, or its provider is still declared with
    /// the same host. A key is never sent to a host the user didn't see it bound to.
    func survives(old: LeoPluginPermissions, new: LeoPluginPermissions) -> Bool {
        switch subject {
        case .account(let kind, _):
            return new.credentials.contains(kind)
        case .apiKey(let provider, _):
            guard let now = new.apiKeys.first(where: { $0.provider == provider }),
                let before = old.apiKeys.first(where: { $0.provider == provider })
            else { return false }
            return now.host == before.host
        }
    }
}
