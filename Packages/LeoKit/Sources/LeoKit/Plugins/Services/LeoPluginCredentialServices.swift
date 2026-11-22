import Foundation

/// Opens the folder picker for `leo.credentials.add`. Only ever called for a
/// request that spent a fresh gesture. Nil when the user cancels.
public protocol LeoPluginCredentialPicking: Sendable {
    @MainActor func pickFolder(for kind: LeoPluginCredentialKind) async -> String?
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
    func addGrant(pluginID: String, kind: LeoPluginCredentialKind, path: String) throws -> LeoPluginCredentialGrant?
    func removeGrant(pluginID: String, grantID: String) throws
}

extension LeoPluginStore: LeoPluginCredentialGrantStoring {
    public func grants(pluginID: String) -> [LeoPluginCredentialGrant] {
        registry.grants(for: pluginID)
    }

    public func addGrant(pluginID: String, kind: LeoPluginCredentialKind, path: String) throws -> LeoPluginCredentialGrant? {
        try update { $0.addGrant(pluginID: pluginID, kind: kind, path: path, id: UUID().uuidString) }
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

    public init(
        picker: any LeoPluginCredentialPicking, resolver: any LeoPluginCredentialResolving,
        grants: any LeoPluginCredentialGrantStoring, home: String
    ) {
        self.picker = picker
        self.resolver = resolver
        self.grants = grants
        self.home = home
    }
}
