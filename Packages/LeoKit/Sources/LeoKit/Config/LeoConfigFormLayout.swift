import Foundation

/// How the form draws one field. The layout picks it from the field's type
/// and hints; the app maps each case to a standard control.
public enum LeoConfigControl: Equatable, Sendable {
    case text(placeholder: String?)
    case multiline
    case number(min: Int?, max: Int?, placeholder: String?)
    case toggle
    /// A bool that may be unset: inherit, on or off.
    case triState
    case picker(options: [LeoConfigOption])
    case referencePicker(collection: String, names: [String], emptyLabel: String)
    case list
    case keyValue
    case duration(placeholder: String?)
    case cron
    case yaml
    case secret(LeoConfigSecretState)
    /// A text field with a menu of known values (the model field).
    case suggestions([String], placeholder: String?)
    /// A type this app doesn't know: shown, not editable, with a way to the web UI.
    case readOnlyUnknown(typeName: String, webLink: URL?)
}

public enum LeoConfigSecretState: Equatable, Sendable {
    case set
    case notSet
    /// A replacement is waiting for Save.
    case replacing
    /// A clear is waiting for Save.
    case clearing
}

public struct LeoConfigFormRow: Equatable, Sendable, Identifiable {
    public let path: String
    public let field: LeoConfigField
    public let control: LeoConfigControl
    /// What the draft holds for this field now.
    public let value: LeoConfigValue
    /// What the document held for this field when the draft was opened: what
    /// an undo goes back to.
    public let base: LeoConfigValue
    /// What the field falls back to when unset, if the daemon says.
    public let inherited: LeoConfigValue?
    public let isDirty: Bool
    public let errors: [String]

    public var id: String { path }

    public init(
        path: String, field: LeoConfigField, control: LeoConfigControl, value: LeoConfigValue = .null,
        base: LeoConfigValue = .null, inherited: LeoConfigValue? = nil, isDirty: Bool = false, errors: [String] = []
    ) {
        self.path = path
        self.field = field
        self.control = control
        self.value = value
        self.base = base
        self.inherited = inherited
        self.isDirty = isDirty
        self.errors = errors
    }
}

public struct LeoConfigFormSection: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case group
        case harnessOptions
        case subsection
        case advanced
    }

    public let kind: Kind
    public let title: String
    public let rows: [LeoConfigFormRow]

    public var id: String { "\(kind):\(title)" }
}

/// Lays a resource out as a form, as a pure function of the schema and the
/// draft: the non-advanced groups in registry order, "Harness options" for the
/// draft's *current* harness (so switching harness needs no round trip), the
/// subsections, then "Advanced".
public enum LeoConfigFormLayout {
    public static let harnessOptionsTitle = "Harness options"
    public static let advancedTitle = "Advanced"
    public static let defaultGroupTitle = "General"
    public static let defaultEmptyLabel = "None"

    public static func sections(
        resource: LeoConfigResource, harnesses: [String: LeoConfigHarnessSchema], draft: LeoConfigDraft,
        references: [String: [String]], webLink: URL?
    ) -> [LeoConfigFormSection] {
        let context = Context(draft: draft, references: references, webLink: webLink)
        let harness = draft.currentHarness
        let harnessFields = resource.harnessOptions ? (harness.flatMap { harnesses[$0]?.fields } ?? []) : []
        let harnessPaths = harnessFields.map { ("\(LeoConfigValidator.harnessOptionsKey).\($0.key)", $0) }

        let groups = groupedSections(resource.fields.map { ($0.key, $0) }, context: context)
        let options = section(.harnessOptions, harnessOptionsTitle, harnessPaths.filter { !$0.1.advanced }, context)
        let subsections = resource.subsections.compactMap { subsection -> LeoConfigFormSection? in
            let paths = subsection.fields.map { ("\(subsection.key).\($0.key)", $0) }
            let title = paths.lazy.map(\.1.group).first { !$0.isEmpty } ?? subsection.key.capitalizedFirst
            return section(.subsection, title, paths.filter { !$0.1.advanced }, context)
        }
        let advancedPaths = resource.fields.map { ($0.key, $0) }
            + resource.subsections.flatMap { sub in sub.fields.map { ("\(sub.key).\($0.key)", $0) } }
            + harnessPaths
        let advanced = section(.advanced, advancedTitle, advancedPaths.filter { $0.1.advanced }, context)
        return (groups + [options] + subsections + [advanced]).compactMap { $0 }
    }

    // MARK: sections

    private struct Context {
        let draft: LeoConfigDraft
        let references: [String: [String]]
        let webLink: URL?
    }

    private static func groupedSections(_ fields: [(String, LeoConfigField)], context: Context) -> [LeoConfigFormSection?] {
        let visible = fields.filter { !$0.1.advanced }
        let titles = visible.map { $0.1.group.isEmpty ? defaultGroupTitle : $0.1.group }
        var seen: Set<String> = []
        return titles.filter { seen.insert($0).inserted }.map { title in
            section(.group, title, zip(visible, titles).filter { $0.1 == title }.map(\.0), context)
        }
    }

    private static func section(_ kind: LeoConfigFormSection.Kind, _ title: String, _ fields: [(String, LeoConfigField)], _ context: Context) -> LeoConfigFormSection? {
        guard !fields.isEmpty else { return nil }
        return LeoConfigFormSection(kind: kind, title: title, rows: fields.map { row($0.0, $0.1, context) })
    }

    // MARK: rows

    private static func row(_ path: String, _ field: LeoConfigField, _ context: Context) -> LeoConfigFormRow {
        let draft = context.draft
        let value = draft.value(at: path)
        let inherited = inheritedValue(path, in: draft.document)
        return LeoConfigFormRow(
            path: path, field: field,
            control: control(for: field, value: value, inherited: inherited, context: context),
            value: value, base: draft.baseValue(at: path), inherited: inherited, isDirty: draft.isDirty(path), errors: draft.errors(for: path)
        )
    }

    private static func inheritedValue(_ path: String, in document: LeoConfigDocument) -> LeoConfigValue? {
        guard let dot = path.firstIndex(of: ".") else { return document.inherited[path] }
        let (group, key) = (String(path[..<dot]), String(path[path.index(after: dot)...]))
        return document.inherited[group]?.objectValue?[key]
    }

    private static func control(for field: LeoConfigField, value: LeoConfigValue, inherited: LeoConfigValue?, context: Context) -> LeoConfigControl {
        let hint = context.draft.currentHarness.flatMap { field.hintsByHarness[$0] }
        let placeholder = inherited.flatMap(displayText).map { "inherit: \($0)" } ?? hint?.placeholder ?? displayText(field.defaultValue)
        switch field.type {
        case .string:
            if field.format == "cron" { return .cron }
            if field.multiline { return .multiline }
            if let suggestions = hint?.suggestions, !suggestions.isEmpty { return .suggestions(suggestions, placeholder: placeholder) }
            return .text(placeholder: placeholder)
        case .int:
            return .number(min: field.constraints.min, max: field.constraints.max, placeholder: placeholder)
        case .bool:
            return field.nullable ? .triState : .toggle
        case .enum:
            return .picker(options: field.options)
        case .reference:
            let collection = field.references ?? ""
            return .referencePicker(collection: collection, names: context.references[collection] ?? [], emptyLabel: field.emptyLabel ?? defaultEmptyLabel)
        case .list: return .list
        case .map: return .keyValue
        case .duration: return .duration(placeholder: placeholder)
        case .yaml: return .yaml
        case .secret: return .secret(secretState(value))
        case .unknown(let name): return .readOnlyUnknown(typeName: name, webLink: context.webLink)
        }
    }

    private static func secretState(_ value: LeoConfigValue) -> LeoConfigSecretState {
        switch value {
        case .secret(let isSet): isSet ? .set : .notSet
        case .secretReplace: .replacing
        case .secretClear: .clearing
        default: .notSet
        }
    }

    private static func displayText(_ value: LeoConfigValue) -> String? {
        switch value {
        case .string(let text): text.isEmpty ? nil : text
        case .int(let number): String(number)
        case .double(let number): String(number)
        default: nil
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
