import Foundation

/// Opens the folder picker for `leo.credentials.add`. Only ever called for a
/// request that spent a fresh gesture. Nil when the user cancels.
public protocol LeoPluginCredentialPicking: Sendable {
    @MainActor func pickFolder(for kind: LeoPluginCredentialKind) async -> String?
    /// The account the user chose, on this Mac or on a connected machine.
    @MainActor func pickAccount(for kind: LeoPluginCredentialKind) async -> LeoPluginCredentialSelection?
    /// Shows the paste-a-key sheet for `provider` on behalf of `pluginName`.
    /// Nil when the user cancels. The entry is used once and never stored.
    @MainActor func pickAPIKey(for provider: LeoPluginAPIKeyProvider, pluginName: String) async -> LeoPluginAPIKeyEntry?
}

extension LeoPluginCredentialPicking {
    /// A picker that only knows this Mac's folders.
    @MainActor public func pickAccount(for kind: LeoPluginCredentialKind) async -> LeoPluginCredentialSelection? {
        await pickFolder(for: kind).map { LeoPluginCredentialSelection(machine: .local, path: $0) }
    }

    /// A picker without a key sheet: every API-key add is cancelled.
    @MainActor public func pickAPIKey(for provider: LeoPluginAPIKeyProvider, pluginName: String) async -> LeoPluginAPIKeyEntry? {
        nil
    }
}

/// One account the user chose: a folder on `machine`.
public struct LeoPluginCredentialSelection: Equatable, Sendable {
    public let machine: LeoHostID
    /// Absolute, on `machine`.
    public let path: String

    public init(machine: LeoHostID, path: String) {
        self.machine = machine
        self.path = path
    }
}

/// Turns a grant into fetch headers. May block (a Keychain read with UI waits
/// on the dialog), so callers run it off the main actor.
public protocol LeoPluginCredentialResolving: Sendable {
    func resolve(_ grant: LeoPluginCredentialGrant, allowUI: Bool) throws(LeoPluginCredentialError) -> LeoPluginFetchCredential
}

extension LeoPluginCredentials: LeoPluginCredentialResolving {}

/// The persisted credential grants, per plugin.
public protocol LeoPluginCredentialGrantStoring: Sendable {
    func grants(pluginID: String) -> [LeoPluginCredentialGrant]
    /// Nil when the plugin isn't approved for `kind` or the path isn't absolute.
    func addGrant(pluginID: String, kind: LeoPluginCredentialKind, path: String, machine: LeoHostID) throws -> LeoPluginCredentialGrant?
    /// Nil when the plugin isn't approved for `provider` or the name is invalid.
    func addAPIKeyGrant(pluginID: String, provider: String, host: String, name: String, id: String) throws -> LeoPluginCredentialGrant?
    func removeGrant(pluginID: String, grantID: String) throws
}

extension LeoPluginCredentialGrantStoring {
    /// An account on this Mac.
    public func addGrant(pluginID: String, kind: LeoPluginCredentialKind, path: String) throws -> LeoPluginCredentialGrant? {
        try addGrant(pluginID: pluginID, kind: kind, path: path, machine: .local)
    }
}

extension LeoPluginStore: LeoPluginCredentialGrantStoring {
    public func grants(pluginID: String) -> [LeoPluginCredentialGrant] {
        registry.grants(for: pluginID)
    }

    public func addGrant(pluginID: String, kind: LeoPluginCredentialKind, path: String, machine: LeoHostID) throws -> LeoPluginCredentialGrant? {
        try update { $0.addGrant(pluginID: pluginID, kind: kind, path: path, id: UUID().uuidString, machine: machine) }
    }

    public func addAPIKeyGrant(pluginID: String, provider: String, host: String, name: String, id: String) throws -> LeoPluginCredentialGrant? {
        try update { $0.addAPIKeyGrant(pluginID: pluginID, provider: provider, host: host, name: name, id: id) }
    }

    public func removeGrant(pluginID: String, grantID: String) throws {
        try update { $0.removeGrant(pluginID: pluginID, grantID: grantID) }
    }
}

/// What the router needs for `leo.credentials` and credential fetches.
public struct LeoPluginCredentialServices: Sendable {
    public let picker: any LeoPluginCredentialPicking
    public let resolver: any LeoPluginCredentialResolving
    public let grants: any LeoPluginCredentialGrantStoring
    /// This Mac's home directory, for `~`-abbreviated handle paths.
    public let home: String
    /// How to reach another machine's daemon, for accounts that live there.
    /// Nil refuses (as offline) every remote account.
    public let remote: (any LeoPluginRemoteCredentialForwarding)?
    /// Where pasted API keys live. Nil refuses every `api-key` add and fetch.
    public let apiKeys: LeoPluginAPIKeyVault?

    public init(
        picker: any LeoPluginCredentialPicking, resolver: any LeoPluginCredentialResolving,
        grants: any LeoPluginCredentialGrantStoring, home: String, remote: (any LeoPluginRemoteCredentialForwarding)? = nil,
        apiKeys: LeoPluginAPIKeyVault? = nil
    ) {
        self.picker = picker
        self.resolver = resolver
        self.grants = grants
        self.home = home
        self.remote = remote
        self.apiKeys = apiKeys
    }
}

/// Passes grant changes through and reports each one (to refresh Settings).
struct LeoPluginPublishingGrantStore: LeoPluginCredentialGrantStoring {
    let base: any LeoPluginCredentialGrantStoring
    let didChange: @Sendable () -> Void

    func grants(pluginID: String) -> [LeoPluginCredentialGrant] { base.grants(pluginID: pluginID) }

    func addGrant(pluginID: String, kind: LeoPluginCredentialKind, path: String, machine: LeoHostID) throws -> LeoPluginCredentialGrant? {
        defer { didChange() }
        return try base.addGrant(pluginID: pluginID, kind: kind, path: path, machine: machine)
    }

    func addAPIKeyGrant(pluginID: String, provider: String, host: String, name: String, id: String) throws -> LeoPluginCredentialGrant? {
        defer { didChange() }
        return try base.addAPIKeyGrant(pluginID: pluginID, provider: provider, host: host, name: name, id: id)
    }

    func removeGrant(pluginID: String, grantID: String) throws {
        defer { didChange() }
        try base.removeGrant(pluginID: pluginID, grantID: grantID)
    }
}
