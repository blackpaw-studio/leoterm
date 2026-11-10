import Foundation

public struct LeoPluginHostPatternError: Error, Equatable, Sendable {
    public let reason: String
}

/// A manifest `permissions.network` entry: an exact DNS host or `*.suffix`.
///
/// Rules (deliberately strict, since this is the plugin network allowlist):
/// - DNS names only, canonicalised to lowercase ASCII: IDN labels are accepted
///   in Unicode or punycode and stored as punycode (see `LeoPluginIDNA`). One
///   trailing dot is ignored. Percent escapes are never accepted.
/// - At least two labels, and no numeric host: a last label that is decimal,
///   `0x…` hex or leading-zero octal (WHATWG "ends in a number") is refused.
///   That rules out single-label names, bare `*`/`*.com`, every IPv4 spelling
///   (`127.1`, `127.0.0.0x1`, ...) and IPv6 literals.
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
            let host = try canonical(suffix, invalid: "'\(suffix)' is not a valid DNS name")
            try requireRegistrable(host, wildcard: true)
            return .wildcard(suffix: host)
        }
        if text.contains("*") {
            throw LeoPluginHostPatternError(reason: "'*' is only allowed as a leading '*.' label")
        }
        let host = try canonical(text, invalid: "must be a plain DNS host name (no scheme, port, path or userinfo)")
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

    /// Canonical lowercase-ASCII form of a host (IDN labels as punycode, one
    /// trailing dot dropped), or nil for anything that is not a well-formed DNS
    /// name or is a numeric/IP host. The single choke point for patterns and requests.
    static func normalize(_ raw: String) -> String? {
        try? canonicalize(raw).get()
    }

    private enum HostProblem: Error { case malformed, numeric }

    private static func canonicalize(_ raw: String) -> Result<String, HostProblem> {
        var host = raw
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= maxHostLength * 4 else { return .failure(.malformed) }
        var labels: [String] = []
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard let ascii = LeoPluginIDNA.asciiLabel(String(label)), isLabel(Substring(ascii)) else {
                return .failure(.malformed)
            }
            labels.append(ascii)
        }
        let result = labels.joined(separator: ".")
        guard result.utf8.count <= maxHostLength else { return .failure(.malformed) }
        return isNumeric(labels) ? .failure(.numeric) : .success(result)
    }

    private static func canonical(_ text: String, invalid: String) throws -> String {
        switch canonicalize(text) {
        case .success(let host): return host
        case .failure(.numeric): throw LeoPluginHostPatternError(reason: "IP addresses are not allowed; use a DNS name")
        case .failure(.malformed): throw LeoPluginHostPatternError(reason: invalid)
        }
    }

    /// WHATWG "ends in a number": the last label is decimal, `0x…` hex or octal.
    private static func isNumeric(_ labels: [String]) -> Bool {
        guard let last = labels.last?.utf8 else { return false }
        if last.allSatisfy(isDigit) { return true }
        let bytes = Array(last)
        guard bytes.count >= 2, bytes[0] == UInt8(ascii: "0"), bytes[1] == UInt8(ascii: "x") else { return false }
        return bytes.dropFirst(2).allSatisfy { isDigit($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    private static func isLabel(_ label: Substring) -> Bool {
        let bytes = Array(label.utf8)
        let hyphen = UInt8(ascii: "-")
        guard (1...maxLabelLength).contains(bytes.count), bytes.first != hyphen, bytes.last != hyphen else { return false }
        return bytes.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || isDigit($0) || $0 == hyphen }
    }

    private static func isDigit(_ b: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) }

    private static func requireRegistrable(_ host: String, wildcard: Bool) throws {
        guard host.split(separator: ".").count >= 2 else {
            throw LeoPluginHostPatternError(
                reason: wildcard ? "wildcard suffix must have at least two labels (e.g. *.example.com)" : "host must have at least two labels")
        }
    }
}
