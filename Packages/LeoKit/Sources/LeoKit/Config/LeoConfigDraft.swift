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
    /// After a harness change the document's `harness_options` belong to the
    /// old harness, so none of them show.
    public func value(at path: String) -> LeoConfigValue {
        edits[path] ?? baseValue(at: path)
    }

    private func baseValue(at path: String) -> LeoConfigValue {
        if isHarnessChanged, Self.split(path)?.group == LeoConfigValidator.harnessOptionsKey { return .null }
        return Self.value(at: path, in: document.values)
    }

    public mutating func set(_ path: String, _ value: LeoConfigValue) {
        if value.isEquivalent(to: baseValue(at: path)) {
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
        harness(own: value(at: "harness"))
    }

    /// The harness the document itself resolves to.
    private var originalHarness: String? {
        harness(own: Self.value(at: "harness", in: document.values))
    }

    private func harness(own: LeoConfigValue) -> String? {
        if let own = own.stringValue, !own.isEmpty { return own }
        if let inherited = document.inherited["harness"]?.stringValue, !inherited.isEmpty { return inherited }
        return document.effectiveHarness
    }

    /// The effective harness differs from the saved one.
    private var isHarnessChanged: Bool { isDirty("harness") && currentHarness != originalHarness }

    // MARK: patch

    /// The changed keys only. A nested edit sends its whole subsection or
    /// `harness_options` object (the document's values with the edits laid
    /// over), so a daemon that replaces a nested object and one that merges it
    /// end up in the same place. Changing the harness sends only `harness`:
    /// the daemon drops the old harness's options itself, and an option edited
    /// afterwards is sent alone.
    public var patch: [String: LeoConfigValue] {
        var result: [String: LeoConfigValue] = [:]
        var groups: [String: [String: LeoConfigValue]] = [:]
        for (path, value) in edits {
            guard let (group, key) = Self.split(path) else {
                result[path] = withDeletions(value, at: path)
                continue
            }
            groups[group, default: baseGroup(group)][key] = value
        }
        for (group, object) in groups { result[group] = .object(object) }
        return result
    }

    /// A map field is merged by the daemon (an omitted key is kept), so an
    /// entry the edit removed is sent as `null`.
    private func withDeletions(_ value: LeoConfigValue, at path: String) -> LeoConfigValue {
        guard case .map = value, let base = document.values[path]?.objectValue else { return value }
        let kept = value.objectValue ?? [:]
        let removed = base.keys.filter { kept[$0] == nil }
        guard !removed.isEmpty else { return value }
        return .object(kept.merging(removed.map { ($0, LeoConfigValue.null) }) { $1 })
    }

    private func baseGroup(_ group: String) -> [String: LeoConfigValue] {
        if group == LeoConfigValidator.harnessOptionsKey, isHarnessChanged { return [:] }
        return document.values[group]?.objectValue ?? [:]
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
        // The harness first: it decides what the option edits are measured against.
        for (path, value) in edits.sorted(by: { $0.key == "harness" || ($1.key != "harness" && $0.key < $1.key) }) {
            copy.set(path, value)
        }
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
