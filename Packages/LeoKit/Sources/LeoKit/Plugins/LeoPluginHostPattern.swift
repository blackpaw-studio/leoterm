import Foundation

public struct LeoPluginHostPatternError: Error, Equatable, Sendable {
    public let reason: String
}

/// A manifest `permissions.network` entry: an exact DNS host or `*.suffix`.
///
/// Rules (deliberately strict, since this is the plugin network allowlist):
/// - ASCII DNS names only (IDNs must be written as punycode), lowercase after
///   parsing, one trailing dot ignored.
/// - At least two labels, and the last label may not be all digits. That rules
///   out single-label names, bare `*`/`*.com`, and every IPv4 spelling.
/// - `*.suffix` matches subdomains of `suffix` at any depth, never the bare
///   suffix itself. The `*.` may only appear once, at the start.
/// - No scheme, port, path, userinfo or whitespace in a pattern.
public enum LeoPluginHostPattern: Hashable, Sendable {
    case exact(String)
    case wildcard(suffix: String)

    private static let maxHostLength = 253
    private static let maxLabelLength = 63

    public static func parse(_ text: String) throws -> LeoPluginHostPattern {
        if text.hasPrefix("*.") {
            let suffix = String(text.dropFirst(2))
            guard let host = normalize(suffix) else {
                throw LeoPluginHostPatternError(reason: "'\(suffix)' is not a valid DNS name")
            }
            try requireRegistrable(host, wildcard: true)
            return .wildcard(suffix: host)
        }
        if text.contains("*") {
            throw LeoPluginHostPatternError(reason: "'*' is only allowed as a leading '*.' label")
        }
        guard let host = normalize(text) else {
            throw LeoPluginHostPatternError(reason: "must be a plain DNS host name (no scheme, port, path or userinfo)")
        }
        try requireRegistrable(host, wildcard: false)
        return .exact(host)
    }

    /// `*.suffix` or the exact host, in canonical (lowercase) form.
    public var canonical: String {
        switch self {
        case .exact(let host): return host
        case .wildcard(let suffix): return "*." + suffix
        }
    }

    /// Whether this pattern allows `host` (as found in a URL). Case-insensitive;
    /// one trailing dot is ignored; malformed hosts never match.
    public func matches(host: String) -> Bool {
        guard let host = Self.normalize(host) else { return false }
        switch self {
        case .exact(let exact): return host == exact
        case .wildcard(let suffix): return host.hasSuffix("." + suffix)
        }
    }

    /// Whether everything `other` allows is already allowed by `self`.
    public func covers(_ other: LeoPluginHostPattern) -> Bool {
        switch (self, other) {
        case (.exact(let a), .exact(let b)): return a == b
        case (.exact, .wildcard): return false
        case (.wildcard(let suffix), .exact(let host)): return host.hasSuffix("." + suffix)
        case (.wildcard(let suffix), .wildcard(let inner)): return inner == suffix || inner.hasSuffix("." + suffix)
        }
    }

    /// Lowercases, drops one trailing dot and validates DNS label syntax.
    /// Returns nil for anything that is not a well-formed ASCII DNS name.
    static func normalize(_ raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= maxHostLength else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy(isLabel) ? host : nil
    }

    private static func isLabel(_ label: Substring) -> Bool {
        let bytes = Array(label.utf8)
        let hyphen = UInt8(ascii: "-")
        guard (1...maxLabelLength).contains(bytes.count), bytes.first != hyphen, bytes.last != hyphen else { return false }
        return bytes.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || isDigit($0) || $0 == hyphen }
    }

    private static func isDigit(_ b: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) }

    private static func requireRegistrable(_ host: String, wildcard: Bool) throws {
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else {
            throw LeoPluginHostPatternError(
                reason: wildcard ? "wildcard suffix must have at least two labels (e.g. *.example.com)" : "host must have at least two labels")
        }
        if let last = labels.last, last.utf8.allSatisfy(isDigit) {
            throw LeoPluginHostPatternError(reason: "IP addresses are not allowed; use a DNS name")
        }
    }
}
