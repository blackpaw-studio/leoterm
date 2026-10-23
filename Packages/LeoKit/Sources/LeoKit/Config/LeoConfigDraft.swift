import Foundation

/// The unsaved edits to one config document: the form's whole state, as a
/// value. Edits are keyed by field path (`model`, `push.enabled`,
/// `harness_options.sandbox`) and kept only while they differ from the
/// document, so `isDirty` is exact. `patch` is what a save sends.
public struct LeoConfigDraft: Equatable, Sendable {
    public let document: LeoConfigDocument
    public private(set) var edits: [String: LeoConfigValue] = [:]
    private var serverErrors: [LeoConfigFieldError] = []
    private let validator: LeoConfigValidator?

    public init(document: LeoConfigDocument, validator: LeoConfigValidator? = nil) {
        self.document = document
        self.validator = validator
    }

    public var revision: String { document.revision }
    public var isDirty: Bool { !edits.isEmpty }

    public func isDirty(_ path: String) -> Bool {
        edits[path] != nil
    }

    /// The value shown for `path`: the edit, else the document's, else null.
    public func value(at path: String) -> LeoConfigValue {
        edits[path] ?? Self.value(at: path, in: document.values)
    }

    public mutating func set(_ path: String, _ value: LeoConfigValue) {
        if value.isEquivalent(to: Self.value(at: path, in: document.values)) {
            edits[path] = nil
        } else {
            edits[path] = value
        }
        serverErrors.removeAll { $0.field == path || $0.field.isEmpty }
    }

    public mutating func revert(_ path: String) {
        edits[path] = nil
    }

    public mutating func revert() {
        edits = [:]
        serverErrors = []
    }

    // MARK: harness

    /// The harness the form is editing options for: the draft's `harness`,
    /// else the one it inherits.
    public var currentHarness: String? {
        if let own = value(at: "harness").stringValue, !own.isEmpty { return own }
        if let inherited = document.inherited["harness"]?.stringValue, !inherited.isEmpty { return inherited }
        return document.effectiveHarness
    }

    private var isHarnessChanged: Bool { isDirty("harness") }

    // MARK: patch

    /// The changed keys only. A nested edit sends its whole subsection or
    /// `harness_options` object (the document's values with the edits laid
    /// over), so a daemon that replaces a nested object and one that merges it
    /// end up in the same place. Changing the harness always sends
    /// `harness_options`, cut to the new harness's keys, so the old harness's
    /// options don't ride along.
    public var patch: [String: LeoConfigValue] {
        var result: [String: LeoConfigValue] = [:]
        var groups: [String: [String: LeoConfigValue]] = [:]
        for (path, value) in edits {
            guard let (group, key) = Self.split(path) else {
                result[path] = value
                continue
            }
            groups[group, default: baseGroup(group)][key] = value
        }
        if isHarnessChanged, groups[LeoConfigValidator.harnessOptionsKey] == nil {
            groups[LeoConfigValidator.harnessOptionsKey] = baseGroup(LeoConfigValidator.harnessOptionsKey)
        }
        for (group, object) in groups { result[group] = .object(object) }
        return result
    }

    private func baseGroup(_ group: String) -> [String: LeoConfigValue] {
        let current = document.values[group]?.objectValue ?? [:]
        guard group == LeoConfigValidator.harnessOptionsKey, isHarnessChanged, let validator else { return current }
        let keys = validator.harnessOptionKeys(currentHarness)
        return current.filter { keys.contains($0.key) }
    }

    // MARK: errors

    /// Everything blocking a save: the schema's rules over the current
    /// values, then the daemon's last reply.
    public var allErrors: [LeoConfigFieldError] {
        clientErrors + serverErrors
    }

    public var canSave: Bool { isDirty && allErrors.isEmpty }

    public func errors(for path: String) -> [String] {
        allErrors.filter { $0.field == path }.map(\.message)
    }

    /// Messages that belong to no rendered field: form-level ones, and any
    /// that name a field this form doesn't have.
    public var formErrors: [String] {
        let known = Set(knownPaths)
        return serverErrors.compactMap { error in
            if error.field.isEmpty { return error.message }
            return known.contains(error.field) || Self.isNameField(error.field) ? nil : "\(error.field): \(error.message)"
        }
    }

    public func applying(serverErrors errors: [LeoConfigFieldError]) -> Self {
        var copy = self
        copy.serverErrors = errors
        return copy
    }

    private var clientErrors: [LeoConfigFieldError] {
        validator?.errors(values: { value(at: $0) }, harness: currentHarness) ?? []
    }

    private var knownPaths: [String] {
        validator.map { $0.fields(harness: currentHarness).map(\.path) } ?? serverErrors.map(\.field)
    }

    // MARK: rebase

    /// This draft's edits over a newer `document` (a Reload after a conflict):
    /// an edit the new document already has drops out, the daemon's old
    /// replies don't apply, and `patch` is then computed against fresh values.
    public func rebased(onto newDocument: LeoConfigDocument) -> Self {
        var copy = Self(document: newDocument, validator: validator)
        for (path, value) in edits { copy.set(path, value) }
        return copy
    }

    // MARK: paths

    private static func split(_ path: String) -> (group: String, key: String)? {
        guard let dot = path.firstIndex(of: ".") else { return nil }
        return (String(path[..<dot]), String(path[path.index(after: dot)...]))
    }

    private static func value(at path: String, in values: [String: LeoConfigValue]) -> LeoConfigValue {
        guard let (group, key) = split(path) else { return values[path] ?? .null }
        return values[group]?.objectValue?[key] ?? .null
    }

    private static func isNameField(_ field: String) -> Bool {
        field == "name" || field == "new_name"
    }
}
