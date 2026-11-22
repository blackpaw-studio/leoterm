import Foundation

/// One account folder the user chose for a plugin's credential kind (a Claude
/// config dir or a `CODEX_HOME`). App-owned and stored on the plugin's
/// record: it holds a path, never a token. Tokens are read fresh from the
/// account's own Keychain item or file on every use.
public struct LeoPluginCredentialGrant: Codable, Equatable, Sendable {
    /// Opaque to the plugin; the only thing it can name the grant by.
    public let id: String
    public let kind: LeoPluginCredentialKind
    /// Absolute and standardized, no trailing slash (`LeoPluginCredentialPath`).
    public let path: String

    public init(id: String, kind: LeoPluginCredentialKind, path: String) {
        self.id = id
        self.kind = kind
        self.path = path
    }

    /// What the plugin sees: the folder's name and a home-relative path for display.
    public func handle(home: String) -> LeoPluginCredentialHandle {
        LeoPluginCredentialHandle(
            id: id, kind: kind, label: (path as NSString).lastPathComponent,
            path: LeoPluginCredentialPath.abbreviate(path, home: home))
    }
}

/// A grant as the bridge hands it to plugin code (`leo.credentials.list()`).
public struct LeoPluginCredentialHandle: Codable, Equatable, Sendable {
    public let id: String
    public let kind: LeoPluginCredentialKind
    public let label: String
    public let path: String

    public init(id: String, kind: LeoPluginCredentialKind, label: String, path: String) {
        self.id = id
        self.kind = kind
        self.label = label
        self.path = path
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
        pluginID: String, kind: LeoPluginCredentialKind, path: String, id: String
    ) -> LeoPluginCredentialGrant? {
        guard let record = record(for: pluginID), record.approvedPermissions.credentials.contains(kind),
            path.hasPrefix("/"), let standardized = LeoPluginCredentialPath.standardize(path, home: "/")
        else { return nil }
        if let existing = record.credentialGrants.first(where: { $0.kind == kind && $0.path == standardized }) {
            return existing
        }
        let grant = LeoPluginCredentialGrant(id: id, kind: kind, path: standardized)
        update(pluginID) { $0.credentialGrants.append(grant) }
        return grant
    }

    public mutating func removeGrant(pluginID: String, grantID: String) {
        update(pluginID) { $0.credentialGrants.removeAll { $0.id == grantID } }
    }
}
