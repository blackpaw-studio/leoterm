import Foundation

/// The unsaved edits to one config document: the form's whole state, as a
/// value. Edits are keyed by field path (`model`, `push.enabled`,
/// `harness_options.sandbox`) and kept only while they differ from the
/// document, so `isDirty` is exact. `patch` is what a save sends.
///
/// The daemon merges nested objects and env maps per entry, so a draft keeps
/// and sends only what the user changed: an edited nested key, or one
/// set/delete per env entry (`entryEdits`). Nothing else is replayed, so a
/// Reload, a reconnect or an Overwrite never touches what another writer
/// changed.
public struct LeoConfigDraft: Equatable, Sendable {
    public let document: LeoConfigDocument
    public private(set) var edits: [String: LeoConfigValue] = [:]
    /// Per-entry changes to a top-level map field (env): a value sets or
    /// replaces the entry, `null` deletes it.
    public private(set) var entryEdits: [String: [String: LeoConfigValue]] = [:]
    private var serverErrors: [LeoConfigFieldError] = []
    private let validator: LeoConfigValidator?

    public init(document: LeoConfigDocument, validator: LeoConfigValidator? = nil) {
        self.document = document
        self.validator = validator
    }

    public var revision: String { document.revision }
    public var isDirty: Bool { !edits.isEmpty || !entryEdits.isEmpty }

    public func isDirty(_ path: String) -> Bool {
        edits[path] != nil || entryEdits[path] != nil
    }

    /// The value shown for `path`: the edit, else the document's, else null.
    /// After a harness change the document's `harness_options` belong to the
    /// old harness, so none of them show.
    public func value(at path: String) -> LeoConfigValue {
        if let diff = entryEdits[path] { return Self.applying(diff, to: baseValue(at: path)) }
        return edits[path] ?? baseValue(at: path)
    }

    private func baseValue(at path: String) -> LeoConfigValue {
        if isHarnessChanged, Self.split(path)?.group == LeoConfigValidator.harnessOptionsKey { return .null }
        return Self.value(at: path, in: document.values)
    }

    /// The same edits judged by another validator: the names a reference
    /// field can pick changed under an open form.
    public func validated(by validator: LeoConfigValidator?) -> Self {
        var copy = Self(document: document, validator: validator)
        copy.edits = edits
        copy.entryEdits = entryEdits
        copy.serverErrors = serverErrors
        return copy
    }

    public mutating func set(_ path: String, _ value: LeoConfigValue) {
        let base = baseValue(at: path)
        edits[path] = nil
        entryEdits[path] = nil
        if Self.isEntrywise(path, value) {
            setEntryEdits(Self.entryDiff(from: base, to: value), at: path)
        } else if !value.isEquivalent(to: base) {
            edits[path] = value
        }
        serverErrors.removeAll { $0.field == path || $0.field.isEmpty }
    }

    public mutating func revert(_ path: String) {
        edits[path] = nil
        entryEdits[path] = nil
    }

    public mutating func revert() {
        edits = [:]
        entryEdits = [:]
        serverErrors = []
    }

    /// Keeps the entry changes that still differ from the document.
    private mutating func setEntryEdits(_ diff: [String: LeoConfigValue], at path: String) {
        let base = baseValue(at: path).objectValue ?? [:]
        let live = diff.filter { entry in
            entry.value.isNull ? base[entry.key] != nil : base[entry.key] != entry.value
        }
        entryEdits[path] = live.isEmpty ? nil : live
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

    /// The changed keys only. A nested edit sends just its own key (the
    /// daemon merges the rest), and an env edit sends one entry per change,
    /// `null` for a removal. Changing the harness sends only `harness`: the
    /// daemon drops the old harness's options itself, and an option edited
    /// afterwards is sent alone.
    public var patch: [String: LeoConfigValue] {
        var result: [String: LeoConfigValue] = [:]
        var groups: [String: [String: LeoConfigValue]] = [:]
        for (path, value) in edits {
            guard let (group, key) = Self.split(path) else {
                result[path] = value
                continue
            }
            groups[group, default: [:]][key] = value
        }
        for (group, object) in groups { result[group] = .object(object) }
        for (path, diff) in entryEdits { result[path] = .object(diff) }
        return result
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
            copy.set(path, replayed(value, at: path, over: copy))
        }
        for (path, diff) in entryEdits { copy.setEntryEdits(diff, at: path) }
        return copy
    }

    /// A list edit is the names it added and removed against the list it was
    /// made on (`LeoDelegationListEdit`), so over a newer list it keeps another
    /// writer's additions and removals instead of replacing them with the
    /// whole list that was typed. Any other value replays as it is.
    private func replayed(_ value: LeoConfigValue, at path: String, over target: Self) -> LeoConfigValue {
        guard let names = value.stringList else { return value }
        let base = baseValue(at: path).stringList ?? []
        let fresh = target.baseValue(at: path).stringList ?? []
        var edit = LeoDelegationListEdit(base: base)
        edit.names = names
        return .list(edit.applied(to: fresh).map(LeoConfigValue.string))
    }

    // MARK: env entries

    /// Top-level map fields (env) are edited and sent per entry.
    private static func isEntrywise(_ path: String, _ value: LeoConfigValue) -> Bool {
        split(path) == nil && value.objectValue != nil
    }

    /// The entry changes that turn `base` into `value`; `null` deletes.
    private static func entryDiff(from base: LeoConfigValue, to value: LeoConfigValue) -> [String: LeoConfigValue] {
        let before = base.objectValue ?? [:]
        let after = value.objectValue ?? [:]
        let changed = after.filter { before[$0.key] != $0.value }
        let removed = before.keys.filter { after[$0] == nil }.map { ($0, LeoConfigValue.null) }
        return changed.merging(removed) { $1 }
    }

    private static func applying(_ diff: [String: LeoConfigValue], to base: LeoConfigValue) -> LeoConfigValue {
        let entries = (base.objectValue ?? [:]).merging(diff) { $1 }.filter { !$0.value.isNull }
        let strings = entries.compactMapValues(\.stringValue)
        return strings.count == entries.count ? .map(strings) : .object(entries)
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
