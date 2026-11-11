import Foundation

/// Pure parsing and validation for the git installer: what URL and ref the
/// user may ask for, and how `git ls-remote` output resolves to one commit.
public enum LeoPluginGitSource {
    public static let maxRefLength = 200

    /// A 40-hex commit id, lowercased; nil for anything else.
    public static func normalizedSHA(_ text: String) -> String? {
        let lower = text.lowercased()
        guard lower.utf8.count == 40, lower.utf8.allSatisfy(isHex) else { return nil }
        return lower
    }

    /// The URL to hand to git, or the reason it is refused. Only `allowedSchemes`
    /// (https in the app) pass; userinfo, control characters, whitespace and a
    /// leading `-` (option injection) never do. An https URL must name a host.
    public static func validatedURL(_ text: String, allowedSchemes: Set<String>) -> Result<URL, LeoPluginInstallError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func refuse(_ reason: String) -> Result<URL, LeoPluginInstallError> { .failure(.invalidURL(reason)) }
        guard !trimmed.isEmpty else { return refuse("the URL is empty") }
        guard !trimmed.hasPrefix("-") else { return refuse("the URL must not start with '-'") }
        guard trimmed.utf8.allSatisfy({ $0 > 0x20 && $0 != 0x7F }) else {
            return refuse("the URL contains spaces or control characters")
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return refuse("not a valid URL")
        }
        guard allowedSchemes.contains(scheme) else {
            return refuse(scheme == "https" ? "https is not allowed here" : "only https:// URLs can be installed (got \(scheme)://)")
        }
        if scheme == "https" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let host = components.host, !host.isEmpty
            else { return refuse("the URL has no host") }
            guard components.user == nil, components.password == nil else {
                return refuse("the URL must not contain credentials")
            }
        }
        return .success(url)
    }

    /// A branch, tag or full ref name that is safe to pass as a git argument.
    public static func validatedRef(_ text: String) -> Result<String, LeoPluginInstallError> {
        let ref = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref.isEmpty { return .success("HEAD") }
        guard ref.utf8.count <= maxRefLength, !ref.hasPrefix("-"), !ref.contains(".."),
            ref.utf8.allSatisfy(isRefByte)
        else { return .failure(.invalidRef(ref)) }
        return .success(ref)
    }

    /// Resolves `git ls-remote` output for `ref` to a commit. An exact ref name
    /// wins, then a tag (its peeled commit when annotated), then a branch.
    public static func resolve(ref: String, lsRemote output: String) -> String? {
        var commits: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let sha = normalizedSHA(String(fields[0])) else { continue }
            commits[String(fields[1])] = sha
        }
        let candidates = [
            ref, "refs/tags/\(ref)^{}", "refs/tags/\(ref)", "refs/heads/\(ref)",
        ]
        // An annotated tag lists its tag object and the peeled commit; prefer the commit.
        if let peeled = commits["refs/tags/\(ref)^{}"], commits[ref] == nil { return peeled }
        return candidates.lazy.compactMap { commits[$0] }.first
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    private static func isRefByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || "._/+-@".utf8.contains(byte)
    }
}
