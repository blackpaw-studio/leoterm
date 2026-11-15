import LeoKit
import UIKit

/// A control built for a field, and how it follows the row it shows.
struct SchemaFieldControl {
    let view: UIView
    let update: () -> Void
    /// What selecting the row does: the same as tapping its trailing button.
    /// Nil for controls the row has no other way to open (a text field, a switch).
    var activate: (() -> Void)?
    var rowMenuSource: UIButton?

    func activating(_ action: @escaping () -> Void) -> SchemaFieldControl {
        SchemaFieldControl(view: view, update: update, activate: action, rowMenuSource: rowMenuSource)
    }

    /// The row opens this button's menu wherever it is tapped, not just on the
    /// button: the content view lays a transparent twin of the menu over the row.
    func menuOpenedByTheRow(of button: UIButton) -> SchemaFieldControl {
        SchemaFieldControl(view: view, update: update, activate: activate, rowMenuSource: button)
    }
}

/// The standard control for each `LeoConfigControl`. Controls update in
/// place, so a text field keeps the keyboard while the row under it changes.
@MainActor
enum SchemaFieldControls {
    static let controlID = "field.control"

    /// Whether selecting the row pushes an editor. (A menu's row opens the menu
    /// through an overlay instead; see `menuOpenedByTheRow`.)
    static func isActivatable(_ control: LeoConfigControl) -> Bool {
        switch control {
        case .list, .keyValue, .multiline, .yaml: true
        default: false
        }
    }

    /// Controls of one kind update in place; a new kind builds a new control.
    static func kind(of control: LeoConfigControl) -> String {
        switch control {
        case .text: "text"
        case .multiline: "multiline"
        case .number: "number"
        case .toggle: "toggle"
        case .triState: "triState"
        case .picker: "picker"
        case .referencePicker: "referencePicker"
        case .list: "list"
        case .keyValue: "keyValue"
        case .duration: "duration"
        case .cron: "cron"
        case .yaml: "yaml"
        case .secret: "secret"
        case .suggestions: "suggestions"
        case .readOnlyUnknown: "unknown"
        }
    }

    static func make(_ control: LeoConfigControl, context: SchemaFieldContext) -> SchemaFieldControl {
        switch control {
        case .text, .number, .duration, .cron: textField(context)
        case .suggestions: suggestionField(context)
        case .toggle: toggle(context)
        case .triState: triStateMenu(context)
        case .picker, .referencePicker: optionMenu(context)
        case .list, .keyValue, .multiline, .yaml: editorButton(context)
        case .secret: secretMenu(context)
        case .readOnlyUnknown: unknownNote(context)
        }
    }

    // MARK: text

    private static func textField(_ context: SchemaFieldContext) -> SchemaFieldControl {
        let field = UITextField()
        field.accessibilityIdentifier = controlID
        field.textAlignment = .right
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .never
        field.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        field.addAction(UIAction { [weak field] _ in
            guard let field else { return }
            context.emit(typedValue(field.text ?? "", for: context.row.control))
        }, for: .editingChanged)
        return SchemaFieldControl(view: field) { [weak field] in
            guard let field else { return }
            let row = context.row
            field.placeholder = placeholder(of: row.control)
            field.font = isMonospaced(row.control) ? .monospacedSystemFont(ofSize: UIFont.labelFontSize, weight: .regular) : .preferredFont(forTextStyle: .body)
            field.keyboardType = isNumber(row.control) ? .numbersAndPunctuation : .default
            show(row.value, in: field, control: row.control)
        }
    }

    private static func suggestionField(_ context: SchemaFieldContext) -> SchemaFieldControl {
        let text = textField(context)
        let menu = UIButton(configuration: .plain())
        menu.accessibilityIdentifier = "field.suggestions"
        menu.accessibilityLabel = String(localized: "Suggestions")
        menu.configuration?.image = UIImage(systemName: "chevron.down.circle")
        menu.showsMenuAsPrimaryAction = true
        menu.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [text.view, menu])
        stack.alignment = .center
        stack.spacing = 4
        return SchemaFieldControl(view: stack) { [weak menu, weak field = text.view as? UITextField] in
            text.update()
            guard case .suggestions(let suggestions, _) = context.row.control else { return }
            menu?.menu = UIMenu(children: suggestions.map { suggestion in
                UIAction(title: suggestion) { _ in
                    field?.text = suggestion
                    context.emit(.string(suggestion))
                }
            })
        }
    }

    private static func placeholder(of control: LeoConfigControl) -> String? {
        switch control {
        case .text(let placeholder), .number(_, _, let placeholder), .duration(let placeholder), .suggestions(_, let placeholder): placeholder
        default: nil
        }
    }

    private static func isMonospaced(_ control: LeoConfigControl) -> Bool {
        switch control {
        case .duration, .cron: true
        default: false
        }
    }

    private static func isNumber(_ control: LeoConfigControl) -> Bool {
        if case .number = control { true } else { false }
    }

    /// What typing `text` into a field means. A whole number reads as `.int`,
    /// empty as unset, and anything else is kept as typed so the validator can
    /// say why.
    static func typedValue(_ text: String, for control: LeoConfigControl) -> LeoConfigValue {
        guard isNumber(control) else { return text.isEmpty ? .null : .string(text) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .null }
        return Int(trimmed).map(LeoConfigValue.int) ?? .string(text)
    }

    private static func shownText(_ value: LeoConfigValue) -> String {
        switch value {
        case .string(let text): text
        case .int(let number): String(number)
        default: ""
        }
    }

    /// Writes the row's value into the field, unless the user's own typing
    /// already reads as that value ("04" for 4).
    private static func show(_ value: LeoConfigValue, in field: UITextField, control: LeoConfigControl) {
        if field.isFirstResponder, typedValue(field.text ?? "", for: control) == value { return }
        let text = shownText(value)
        if field.text != text { field.text = text }
    }

    // MARK: bool

    private static func toggle(_ context: SchemaFieldContext) -> SchemaFieldControl {
        let toggle = UISwitch()
        toggle.accessibilityIdentifier = controlID
        toggle.addAction(UIAction { [weak toggle] _ in
            if let toggle { context.emit(.bool(toggle.isOn)) }
        }, for: .valueChanged)
        return SchemaFieldControl(view: toggle) { [weak toggle] in
            let row = context.row
            let isOn = row.value.boolValue ?? row.field.defaultValue.boolValue ?? false
            if toggle?.isOn != isOn { toggle?.setOn(isOn, animated: false) }
        }
    }

    private static func triStateMenu(_ context: SchemaFieldContext) -> SchemaFieldControl {
        let button = menuButton()
        return SchemaFieldControl(view: button) { [weak button] in
            let row = context.row
            let selected = row.value.boolValue
            let inherit = switch row.inherited?.boolValue {
            case true?: "Inherit (on)"
            case false?: "Inherit (off)"
            case nil: "Inherit"
            }
            button?.menu = UIMenu(children: [
                UIAction(title: inherit, state: selected == nil ? .on : .off) { _ in context.emit(.null) },
                UIAction(title: "On", state: selected == true ? .on : .off) { _ in context.emit(.bool(true)) },
                UIAction(title: "Off", state: selected == false ? .on : .off) { _ in context.emit(.bool(false)) },
            ])
        }.menuOpenedByTheRow(of: button)
    }

    // MARK: pickers

    /// A value the list doesn't have (a newer daemon's, or a deleted
    /// reference) stays as an extra entry rather than being replaced.
    private static func optionMenu(_ context: SchemaFieldContext) -> SchemaFieldControl {
        let button = menuButton()
        return SchemaFieldControl(view: button) { [weak button] in
            let row = context.row
            let value = row.value.stringValue ?? ""
            var options: [(value: String, title: String)]
            var missingSuffix = ""
            switch row.control {
            case .picker(let list):
                options = list.map { ($0.value, $0.label) }
            case .referencePicker(_, let names, let emptyLabel):
                options = [("", emptyLabel)] + names.map { ($0, $0) }
                missingSuffix = " (missing)"
            default:
                options = []
            }
            if !value.isEmpty, !options.contains(where: { $0.value == value }) { options.append((value, value + missingSuffix)) }
            button?.menu = UIMenu(children: options.map { option in
                UIAction(title: option.title, state: option.value == value ? .on : .off) { _ in context.emit(.string(option.value)) }
            })
        }.menuOpenedByTheRow(of: button)
    }

    private static func menuButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.indicator = .popup
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = controlID
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.contentHorizontalAlignment = .trailing
        button.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        return button
    }

    // MARK: pushed editors

    private static func editorButton(_ context: SchemaFieldContext) -> SchemaFieldControl {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            context.handlers.push(editor(for: context.row))
        })
        button.accessibilityIdentifier = controlID
        button.contentHorizontalAlignment = .trailing
        button.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        return SchemaFieldControl(view: button) { [weak button] in
            button?.configuration?.title = summary(of: context.row)
        }
        .activating { [weak button] in button?.sendActions(for: .primaryActionTriggered) }
    }

    private static func editor(for row: LeoConfigFormRow) -> SchemaFieldEditor {
        switch row.control {
        case .list: .list(row)
        case .keyValue: .keyValue(row)
        default: .text(row)
        }
    }

    private static func summary(of row: LeoConfigFormRow) -> String {
        switch row.control {
        case .list:
            count(row.value.stringList?.count ?? 0, one: "item", other: "items")
        case .keyValue:
            count(row.value.envEntries.count + row.value.envSecrets.count, one: "variable", other: "variables")
        default:
            row.value.stringValue?.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "Empty"
        }
    }

    private static func count(_ number: Int, one: String, other: String) -> String {
        switch number {
        case 0: "None"
        case 1: "1 \(one)"
        default: "\(number) \(other)"
        }
    }

    // MARK: secret

    private static func secretMenu(_ context: SchemaFieldContext) -> SchemaFieldControl {
        var configuration = UIButton.Configuration.plain()
        configuration.indicator = .popup
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = controlID
        button.showsMenuAsPrimaryAction = true
        button.contentHorizontalAlignment = .trailing
        button.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        return SchemaFieldControl(view: button) { [weak button] in
            guard case .secret(let state) = context.row.control else { return }
            button?.configuration?.title = SecretText.summary(state)
            button?.menu = UIMenu(children: secretActions(state, context: context))
        }.menuOpenedByTheRow(of: button)
    }

    private static func secretActions(_ state: LeoConfigSecretState, context: SchemaFieldContext) -> [UIAction] {
        let replace = { (title: String) in
            UIAction(title: title) { _ in
                context.handlers.promptSecret(context.row.field.label) { answer in
                    guard let answer, !answer.isEmpty else { return }
                    context.emit(.secretReplace(answer))
                }
            }
        }
        switch state {
        case .set:
            return [replace("Replace…"), UIAction(title: "Clear", attributes: .destructive) { _ in context.emit(.secretClear) }]
        case .notSet:
            return [replace("Set…")]
        case .replacing, .clearing:
            return [UIAction(title: "Undo") { _ in context.handlers.revert(context.row.path) }]
        }
    }

    // MARK: unknown

    private static func unknownNote(_ context: SchemaFieldContext) -> SchemaFieldControl {
        let note = UILabel()
        note.accessibilityIdentifier = controlID
        note.text = String(localized: "Can’t be edited here")
        note.font = .preferredFont(forTextStyle: .body)
        note.textColor = .secondaryLabel
        note.textAlignment = .right
        note.numberOfLines = 0

        let link = UIButton(configuration: .plain(), primaryAction: UIAction { _ in
            if case .readOnlyUnknown(_, let url?) = context.row.control { context.handlers.open(url) }
        })
        link.accessibilityIdentifier = "field.webLink"
        link.configuration?.title = String(localized: "Edit in the web UI")
        link.contentHorizontalAlignment = .trailing

        let stack = UIStackView(arrangedSubviews: [note])
        stack.axis = .vertical
        stack.alignment = .trailing
        stack.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        return SchemaFieldControl(view: stack) { [weak note, weak stack] in
            guard case .readOnlyUnknown(let typeName, let url) = context.row.control else { return }
            note?.accessibilityLabel = "A \(typeName) setting this version of Leo can’t edit. Edit it in the web UI."
            // The link exists only when there is somewhere to go.
            if url == nil { link.removeFromSuperview() } else if link.superview == nil { stack?.addArrangedSubview(link) }
        }
    }
}

enum SecretText {
    static func summary(_ state: LeoConfigSecretState) -> String {
        switch state {
        case .set: "Set"
        case .notSet: "Not set"
        case .replacing: "Will be replaced"
        case .clearing: "Will be cleared"
        }
    }
}
