import Foundation

/// The client-side half of validation: the schema's constraints, checked
/// before a save so the common mistakes never leave the app. The daemon stays
/// authoritative; a rule it enforces that the schema doesn't describe comes
/// back as a 422 and is shown on its field.
///
/// Field paths are the schema key (`model`), a subsection key and field
/// (`push.enabled`), or `harness_options.<key>`.
public struct LeoConfigValidator: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let field: LeoConfigField
    }

    public static let harnessOptionsKey = "harness_options"
    public static let defaultNamePattern = "^[A-Za-z0-9._-]+$"
    private static let durationPattern = "^[-+]?(?:(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:ns|us|µs|μs|ms|s|m|h))+$"

    private let entries: [Entry]
    private let harnessEntries: [String: [Entry]]
    private let namePattern: String?
    private let references: [String: [String]]

    /// `references` maps a collection key to the names in it, for the
    /// reference fields; a collection that isn't loaded isn't checked.
    public init(
        resource: LeoConfigResource, harnesses: [String: LeoConfigHarnessSchema] = [:],
        namePattern: String? = nil, references: [String: [String]] = [:]
    ) {
        entries = resource.fields.map { Entry(path: $0.key, field: $0) }
            + resource.subsections.flatMap { section in
                section.fields.map { Entry(path: "\(section.key).\($0.key)", field: $0) }
            }
        harnessEntries = resource.harnessOptions
            ? harnesses.mapValues { $0.fields.map { Entry(path: "\(Self.harnessOptionsKey).\($0.key)", field: $0) } }
            : [:]
        self.namePattern = namePattern
        self.references = references
    }

    /// The fields in force for a `harness`: the resource's own, then that
    /// harness's options. A nil or unknown harness has no options.
    public func fields(harness: String?) -> [Entry] {
        entries + (harness.flatMap { harnessEntries[$0] } ?? [])
    }

    /// The keys of one harness's options.
    public func harnessOptionKeys(_ harness: String?) -> Set<String> {
        Set((harness.flatMap { harnessEntries[$0] } ?? []).map { String($0.path.dropFirst(Self.harnessOptionsKey.count + 1)) })
    }

    public func errors(values: (String) -> LeoConfigValue, harness: String?) -> [LeoConfigFieldError] {
        fields(harness: harness).compactMap { entry in
            check(values(entry.path), entry.field).map { LeoConfigFieldError(field: entry.path, message: $0) }
        }
    }

    /// Why `name` can't be used, or nil. `existing` are the taken names, minus
    /// `excluding` (a rename to the item's own name isn't a clash).
    public func nameError(_ name: String, existing: [String], excluding: String? = nil) -> String? {
        guard !name.isEmpty else { return "Enter a name" }
        let pattern = namePattern ?? ""
        if !pattern.isEmpty, Self.matches(name, pattern: pattern) == false {
            return pattern == Self.defaultNamePattern
                ? "Names can’t contain spaces or symbols other than . _ -"
                : "Names can’t contain these characters (allowed: \(pattern))"
        }
        return existing.contains { $0 == name && $0 != excluding } ? "That name is already taken" : nil
    }

    // MARK: rules

    private func check(_ value: LeoConfigValue, _ field: LeoConfigField) -> String? {
        if field.constraints.required, value.isBlank { return "Required" }
        if value.isBlank { return nil }
        switch field.type {
        case .int: return checkInt(value, field.constraints)
        case .enum: return checkEnum(value, field)
        case .reference: return checkReference(value, field)
        case .duration: return checkDuration(value)
        case .map: return checkMap(value)
        case .string: return checkPattern(value, field.constraints)
        case .bool, .list, .secret, .yaml, .unknown: return nil
        }
    }

    private func checkInt(_ value: LeoConfigValue, _ constraints: LeoConfigConstraints) -> String? {
        guard case .int(let number) = value else { return "Must be a whole number" }
        if let min = constraints.min, number < min { return "Must be at least \(min)" }
        if let max = constraints.max, number > max { return "Must be at most \(max)" }
        return nil
    }

    private func checkEnum(_ value: LeoConfigValue, _ field: LeoConfigField) -> String? {
        guard !field.options.isEmpty, let text = value.stringValue else { return nil }
        return field.options.contains { $0.value == text } ? nil : "Choose one of the listed values"
    }

    private func checkReference(_ value: LeoConfigValue, _ field: LeoConfigField) -> String? {
        guard let collection = field.references, let names = references[collection], let text = value.stringValue else { return nil }
        return names.contains(text) ? nil : "No \(collection) named “\(text)”"
    }

    private func checkDuration(_ value: LeoConfigValue) -> String? {
        guard let text = value.stringValue else { return "Not a valid duration (try 30m or 1h30m)" }
        if Self.matches(text, pattern: "^[-+]?0$") == true || Self.matches(text, pattern: Self.durationPattern) == true { return nil }
        return "Not a valid duration (try 30m or 1h30m)"
    }

    private func checkMap(_ value: LeoConfigValue) -> String? {
        guard case .map(let entries) = value else { return nil }
        if entries.keys.contains("") { return "Variable names can’t be empty" }
        if entries.keys.contains(where: { $0.contains("=") }) { return "Variable names can’t contain “=”" }
        return nil
    }

    private func checkPattern(_ value: LeoConfigValue, _ constraints: LeoConfigConstraints) -> String? {
        guard let pattern = constraints.pattern, let text = value.stringValue else { return nil }
        return Self.matches(text, pattern: pattern) == false ? "Doesn’t match the expected format" : nil
    }

    /// Whether the whole of `text` matches; nil when `pattern` isn't a valid
    /// expression (a rule the app can't read is the daemon's to enforce).
    private static func matches(_ text: String, pattern: String) -> Bool? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
