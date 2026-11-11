import Foundation

/// Who already owns a plugin id.
public enum LeoPluginIDClaim: Equatable, Sendable {
    /// Installed from this git source URL.
    case installed(sourceURL: String)
    /// A bundled or dev plugin; no git source may take the id.
    case reserved
}

/// The installer's view of the registry: which ids are taken, and by what. The
/// registry (3.1) implements it; an id stays bound to the source it was first
/// installed from, so a repo can't land in another plugin's folder and inherit
/// its Keychain service.
public protocol LeoPluginIDClaimLookup: Sendable {
    func claim(forID id: String) -> LeoPluginIDClaim?
}

/// Nothing is taken. Only for contexts with no registry yet (tests, tools).
public struct LeoPluginNoIDClaims: LeoPluginIDClaimLookup {
    public init() {}
    public func claim(forID id: String) -> LeoPluginIDClaim? { nil }
}

extension LeoPluginGitSource {
    /// Whether two source URLs name the same repository: scheme and host are
    /// case-insensitive, a trailing `/` and `.git` don't matter, the path does.
    public static func isSameSource(_ a: String, _ b: String) -> Bool {
        canonicalSource(a) == canonicalSource(b)
    }

    private static func canonicalSource(_ text: String) -> String {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = rest.range(of: "://") else { return rest }
        let scheme = rest[..<schemeEnd.lowerBound].lowercased()
        rest = String(rest[schemeEnd.upperBound...])
        let hostEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = rest[..<hostEnd].lowercased()
        var path = String(rest[hostEnd...])
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        return "\(scheme)://\(host)\(path)"
    }
}
