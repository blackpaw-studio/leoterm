import Foundation

/// A daemon release version, parsed tolerantly from the strings leo emits:
/// `hello.version` is bare semver, `leo version` prints `leo <semver>`, and
/// either may carry a `v` prefix or a `+build` suffix. At least
/// `major.minor` is required; a missing patch reads as 0.
///
/// For display and "is the remote daemon outdated" warnings. The managed
/// post-update restart decision compares raw strings instead, never this.
public struct LeoDaemonVersion: Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?
    public let build: String?

    public init?(parsing raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("leo ") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("v") { text = String(text.dropFirst()) }

        let (rest, build) = Self.split(text, at: "+")
        let (core, prerelease) = Self.split(rest, at: "-")
        if build?.isEmpty == true || prerelease?.isEmpty == true { return nil }

        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIINumber) }),
              let major = Int(components[0]),
              let minor = Int(components[1]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = components.count > 2 ? Int(components[2]) ?? 0 : 0
        self.prerelease = prerelease
        self.build = build
    }

    /// Same release: build metadata is ignored, the prerelease tag is not.
    public func isSameRelease(as other: Self) -> Bool {
        major == other.major && minor == other.minor && patch == other.patch && prerelease == other.prerelease
    }

    private static func split(_ text: String, at separator: Character) -> (String, String?) {
        guard let index = text.firstIndex(of: separator) else { return (text, nil) }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}
