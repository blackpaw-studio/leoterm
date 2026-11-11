import Foundation

/// Outcome of validating a `leo-plugin.json`. `refused` carries a reason fit to
/// show the user in the install sheet.
public enum LeoPluginManifestValidation: Equatable, Sendable {
    case valid(LeoPluginManifest)
    case refused(String)
}

/// Strict validator for plugin manifests: install is refused on any unknown key
/// or permission, a future `apiVersion`, a malformed id/version, a `main` that
/// could escape the plugin folder, or duplicate/invalid contribution ids.
public enum LeoPluginManifestValidator {
    /// Manifests are tiny; a cap stops a hostile repo from feeding us a huge blob.
    public static let maxManifestBytes = 256 * 1024
    static let maxContributionIDLength = 40
    static let maxIDLength = 128
    static let maxMainLength = 256

    public static func validate(_ data: Data) -> LeoPluginManifestValidation {
        guard data.count <= maxManifestBytes else {
            return .refused("manifest is too large (limit \(maxManifestBytes / 1024) KB)")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .refused("manifest is not valid JSON")
        }
        guard let object = root as? [String: Any] else {
            return .refused("manifest must be a JSON object")
        }
        // A newer manifest may legitimately use keys we don't know; say "too new"
        // rather than a confusing unknown-key error.
        if let future = futureAPIVersion(object) {
            return .refused("plugin requires API version \(future); this Leo supports \(LeoPluginAPI.supported)")
        }
        // Foundation reports a non-integral number as root-level corruption with
        // no field name, so check the shape of apiVersion ourselves.
        if let raw = object["apiVersion"], !isInteger(raw) {
            return .refused("apiVersion must be an integer")
        }
        let manifest: LeoPluginManifest
        do {
            manifest = try JSONDecoder().decode(LeoPluginManifest.self, from: data)
        } catch {
            return .refused(describe(error))
        }
        if let problem = semanticProblem(manifest) { return .refused(problem) }
        return .valid(manifest)
    }

    // MARK: - Semantic checks

    static func semanticProblem(_ m: LeoPluginManifest) -> String? {
        if m.apiVersion < 1 { return "apiVersion must be a positive integer" }
        if m.apiVersion > LeoPluginAPI.supported {
            return "plugin requires API version \(m.apiVersion); this Leo supports \(LeoPluginAPI.supported)"
        }
        if !isReverseDNS(m.id) {
            return "id '\(m.id)' must be lowercase reverse-DNS (e.g. studio.blackpaw.github)"
        }
        if m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "name must not be empty" }
        if !isSemver(m.version) { return "version '\(m.version)' is not a semantic version (e.g. 1.2.3)" }
        if let problem = mainPathProblem(m.main) { return "main \(problem)" }
        if let problem = permissionsProblem(m.permissions) { return problem }
        return contributionsProblem(m.contributes)
    }

    static func isReverseDNS(_ id: String) -> Bool {
        guard id.utf8.count <= maxIDLength else { return false }
        let labels = id.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy(isDNSLabel)
    }

    /// Lowercase ASCII letters/digits/hyphen, 1–63 chars, no leading/trailing hyphen.
    private static func isDNSLabel(_ label: Substring) -> Bool {
        let bytes = Array(label.utf8)
        guard (1...63).contains(bytes.count), bytes.first != hyphen, bytes.last != hyphen else { return false }
        return bytes.allSatisfy { isLowerAlnum($0) || $0 == hyphen }
    }

    static func isSemver(_ version: String) -> Bool {
        // Core + optional -prerelease + optional +build, per semver.org, ASCII only.
        let (core, build) = split(version, on: "+")
        if let build, !build.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isBuildIdentifier) { return false }
        let (numbers, prerelease) = split(core, on: "-")
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy(isNumericIdentifier) else { return false }
        guard let prerelease else { return true }
        return prerelease.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isPrereleaseIdentifier)
    }

    private static func split(_ s: String, on separator: Character) -> (String, String?) {
        guard let index = s.firstIndex(of: separator) else { return (s, nil) }
        return (String(s[..<index]), String(s[s.index(after: index)...]))
    }

    private static func isNumericIdentifier(_ s: Substring) -> Bool {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy(isDigit) else { return false }
        return bytes.count == 1 || bytes[0] != zero
    }

    private static func isBuildIdentifier(_ s: Substring) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { isDigit($0) || isAlpha($0) || $0 == hyphen }
    }

    private static func isPrereleaseIdentifier(_ s: Substring) -> Bool {
        guard isBuildIdentifier(s) else { return false }
        // All-numeric identifiers must not have leading zeros.
        return s.utf8.allSatisfy(isDigit) ? isNumericIdentifier(s) : true
    }

    /// Why `main` can't be trusted as a path inside the plugin folder, or nil.
    /// Symlinks are the installer's problem (3.3); this is the lexical check.
    static func mainPathProblem(_ main: String) -> String? {
        if main.isEmpty { return "must not be empty" }
        if main.utf8.count > maxMainLength { return "is too long" }
        if main.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "contains control characters"
        }
        // Byte-level on purpose: Swift Characters glue combining marks onto
        // '/', '.', '\\' and '~', which would hide them from a Character split.
        let bytes = Array(main.utf8)
        if bytes.contains(UInt8(ascii: "\\")) { return "must use '/' separators" }
        if bytes.first == UInt8(ascii: "/") || bytes.first == UInt8(ascii: "~") {
            return "must be a relative path inside the plugin folder"
        }
        for component in bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false) {
            if component.isEmpty { return "must not contain empty path components" }
            if isDotComponent(component) { return "must not contain '.' or '..' components" }
        }
        return nil
    }

    /// `.` or `..`, including spellings with combining marks glued on, which
    /// no real plugin needs and which some file-system layers normalise away.
    private static func isDotComponent(_ component: ArraySlice<UInt8>) -> Bool {
        // Bytes that are not valid UTF-8 are rejected rather than lossily decoded.
        guard let text = String(bytes: component, encoding: .utf8) else { return true }
        let scalars = text.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: false
            default: true
            }
        }
        let stripped = String(String.UnicodeScalarView(scalars))
        return stripped == "." || stripped == ".."
    }

    private static func permissionsProblem(_ p: LeoPluginPermissions) -> String? {
        if let dup = firstDuplicate(p.agents.map(\.rawValue)) {
            return "permissions.agents lists '\(dup)' more than once"
        }
        var hosts: [String] = []
        for raw in p.network {
            do {
                hosts.append(try LeoPluginHostPattern.parse(raw).canonical)
            } catch let error as LeoPluginHostPatternError {
                return "permissions.network '\(raw)' is invalid: \(error.reason)"
            } catch {
                return "permissions.network '\(raw)' is invalid"
            }
        }
        if let dup = firstDuplicate(hosts) { return "permissions.network lists '\(dup)' more than once" }
        return nil
    }

    private static func contributionsProblem(_ c: LeoPluginContributions) -> String? {
        let kinds: [(String, [String])] = [
            ("views", c.views.map(\.id)),
            ("rowAccessories", c.rowAccessories.map(\.id)),
            ("commands", c.commands.map(\.id)),
            ("sidebarSections", c.sidebarSections.map(\.id)),
        ]
        for (kind, ids) in kinds {
            if let bad = ids.first(where: { !isContributionID($0) }) {
                return "\(kind) id '\(bad)' must match [a-z0-9-]{1,\(maxContributionIDLength)}"
            }
            if let dup = firstDuplicate(ids) { return "\(kind) id '\(dup)' is used more than once" }
        }
        for view in c.views {
            if isBlank(view.title) { return "views '\(view.id)' needs a title" }
            if isBlank(view.sfSymbol) { return "views '\(view.id)' needs an sfSymbol" }
        }
        for command in c.commands {
            if isBlank(command.title) { return "commands '\(command.id)' needs a title" }
            if let symbol = command.sfSymbol, isBlank(symbol) { return "commands '\(command.id)' has a blank sfSymbol" }
        }
        for section in c.sidebarSections where isBlank(section.title) {
            return "sidebarSections '\(section.id)' needs a title"
        }
        return nil
    }

    private static func isContributionID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        return (1...maxContributionIDLength).contains(bytes.count) && bytes.allSatisfy { isLowerAlnum($0) || $0 == hyphen }
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func firstDuplicate(_ values: [String]) -> String? {
        var seen = Set<String>()
        return values.first { !seen.insert($0).inserted }
    }

    // MARK: - Error text

    private static func isInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return Int(exactly: number) != nil
    }

    private static func futureAPIVersion(_ object: [String: Any]) -> Int? {
        guard let number = object["apiVersion"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let value = Int(exactly: number), value > LeoPluginAPI.supported
        else { return nil }
        return value
    }

    private static func describe(_ error: Error) -> String {
        if let issue = error as? LeoPluginManifestIssue { return issue.reason }
        guard let decoding = error as? DecodingError else { return "manifest could not be read" }
        func path(_ context: DecodingError.Context, adding key: CodingKey? = nil) -> String {
            let keys = (context.codingPath + (key.map { [$0] } ?? [])).map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing required field '\(path(context, adding: key))'"
        case .valueNotFound(_, let context):
            return "field '\(path(context))' must not be null"
        case .typeMismatch(_, let context), .dataCorrupted(let context):
            let at = path(context)
            return at.isEmpty ? "manifest is malformed" : "field '\(at)' has the wrong type or an invalid value"
        @unknown default:
            return "manifest could not be read"
        }
    }

    // MARK: - ASCII helpers

    private static let hyphen = UInt8(ascii: "-")
    private static let zero = UInt8(ascii: "0")
    private static func isDigit(_ b: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) }
    private static func isLowerAlnum(_ b: UInt8) -> Bool { isDigit(b) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b) }
    private static func isAlpha(_ b: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
    }
}
