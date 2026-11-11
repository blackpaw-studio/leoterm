import Foundation

public enum LeoPluginPermissionDecision: Equatable, Sendable {
    case allowed
    case denied(String)

    public var isAllowed: Bool { self == .allowed }
}

/// Answers "may this plugin do X?" from its approved manifest permissions.
/// Pure and immutable: build one per plugin from the permissions the user approved.
public struct LeoPluginPermissionEngine: Sendable {
    /// Redirect hops allowed after the initial request (hop 0).
    public static let maxRedirectHops = 10

    private let patterns: [LeoPluginHostPattern]
    private let secretsGranted: Bool
    private let agentVerbs: Set<LeoPluginAgentVerb>

    /// Network patterns that fail to parse grant nothing (fail closed).
    public init(permissions: LeoPluginPermissions) {
        patterns = permissions.network.compactMap { try? LeoPluginHostPattern.parse($0) }
        secretsGranted = permissions.secrets
        agentVerbs = Set(permissions.agents)
    }

    /// Checks one hop of a fetch. Call it for the initial URL (`hop` 0) and again
    /// for the target of every redirect (`hop` 1, 2, ...), so a redirect can't
    /// smuggle a request to a host outside the allowlist.
    public func check(url: URL, hop: Int) -> LeoPluginPermissionDecision {
        let prefix = hop > 0 ? "redirect hop \(hop): " : ""
        guard (0...Self.maxRedirectHops).contains(hop) else {
            return .denied("too many redirects (limit \(Self.maxRedirectHops))")
        }
        guard url.scheme?.lowercased() == "https" else {
            return .denied(prefix + "only https URLs are allowed")
        }
        guard let host = Self.canonicalHost(of: url) else {
            return .denied(prefix + "URL has no usable host, or carries userinfo or an encoded host")
        }
        guard patterns.contains(where: { $0.matches(host: host) }) else {
            return .denied(prefix + "host '\(host)' is not in the plugin's network permissions")
        }
        return .allowed
    }

    public func checkSecrets() -> LeoPluginPermissionDecision {
        secretsGranted ? .allowed : .denied("secrets permission not granted in the manifest")
    }

    public func check(agent verb: LeoPluginAgentVerb) -> LeoPluginPermissionDecision {
        agentVerbs.contains(verb) ? .allowed : .denied("agents:\(verb.rawValue) permission not granted in the manifest")
    }

    /// The one canonical host for a URL: lowercase ASCII, IDN as punycode (ACE).
    /// The allowlist check compares this string, and the fetcher must build its
    /// request from this same string, so the host that is checked is exactly the
    /// host that is connected to. Returns nil when anything about the authority
    /// is ambiguous: userinfo (checked on the raw authority, so an empty `:@`
    /// also fails), a percent escape, or any non-DNS or numeric host.
    ///
    /// The host is read from `absoluteString`, where Foundation already writes
    /// IDN hosts as ACE and leaves `xn--` labels untouched. `URLComponents.host`
    /// is never used: it decodes ACE to Unicode, and mapping that back
    /// (case-folding included) can land on a different ACE label.
    public static func canonicalHost(of url: URL) -> String? {
        guard let authority = rawAuthority(url.absoluteString), !authority.contains("@"), !authority.contains("%"),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil, components.password == nil, components.host != nil
        else { return nil }
        let host = authority.prefix { $0 != ":" }
        return LeoPluginHostPattern.normalize(String(host))
    }

    private static func rawAuthority(_ absolute: String) -> String? {
        guard let range = absolute.range(of: "://") else { return nil }
        let rest = absolute[range.upperBound...]
        return String(rest.prefix { !"/?#".contains($0) })
    }
}

/// What an updated manifest asks for beyond what the user already approved.
/// Only increases are listed; removing a permission never needs re-approval.
public struct LeoPluginPermissionDiff: Equatable, Sendable {
    /// Hosts in `new` not already allowed by `old`, canonical form (raw text if unparsable).
    public let addedHosts: [String]
    public let secretsEnabled: Bool
    public let addedAgentVerbs: [LeoPluginAgentVerb]

    public var isEmpty: Bool { addedHosts.isEmpty && !secretsEnabled && addedAgentVerbs.isEmpty }

    public init(old: LeoPluginPermissions, new: LeoPluginPermissions) {
        let oldPatterns = old.network.compactMap { try? LeoPluginHostPattern.parse($0) }
        var seen = Set<String>()
        addedHosts = new.network.compactMap { raw in
            let label: String
            if let pattern = try? LeoPluginHostPattern.parse(raw) {
                if oldPatterns.contains(where: { $0.covers(pattern) }) { return nil }
                label = pattern.canonical
            } else {
                label = raw
            }
            return seen.insert(label).inserted ? label : nil
        }
        secretsEnabled = new.secrets && !old.secrets
        addedAgentVerbs = LeoPluginAgentVerb.allCases.filter { new.agents.contains($0) && !old.agents.contains($0) }
    }
}
