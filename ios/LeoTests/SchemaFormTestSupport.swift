import LeoKit
import UIKit

@testable import Leo

/// What a cell asked its owner to do, in the order it asked.
@MainActor
final class CellRecorder {
    private(set) var edits: [Edit] = []
    private(set) var reverts: [String] = []
    private(set) var pushes: [SchemaFieldEditor] = []
    private(set) var opened: [URL] = []
    private(set) var secretPrompts: [String] = []
    /// What the secret prompt answers with; nil is the user cancelling.
    var secretAnswer: String?

    struct Edit: Equatable {
        let path: String
        let value: LeoConfigValue
    }

    var handlers: SchemaFieldHandlers {
        SchemaFieldHandlers(
            edit: { [self] path, value in edits.append(Edit(path: path, value: value)) },
            revert: { [self] path in reverts.append(path) },
            push: { [self] editor in pushes.append(editor) },
            promptSecret: { [self] title, done in
                secretPrompts.append(title)
                done(secretAnswer)
            },
            open: { [self] url in opened.append(url) }
        )
    }

    var lastValue: LeoConfigValue? { edits.last?.value }
}

@MainActor
enum CellHarness {
    static func view(
        _ row: LeoConfigFormRow, cron: LeoCronPreviewResult? = nil, recorder: CellRecorder
    ) -> UIView & UIContentView {
        let configuration = SchemaFieldContentConfiguration(row: row, cronPreview: cron, handlers: recorder.handlers)
        let view = configuration.makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        view.layoutIfNeeded()
        return view
    }

    static func row(
        _ control: LeoConfigControl, value: LeoConfigValue = .null, path: String = "field", label: String = "Field",
        help: String = "", warning: String = "", inherited: LeoConfigValue? = nil, isDirty: Bool = false,
        errors: [String] = [], defaultValue: LeoConfigValue = .null
    ) -> LeoConfigFormRow {
        LeoConfigFormRow(
            path: path,
            field: LeoConfigField(key: path, label: label, help: help, warning: warning, type: .string, defaultValue: defaultValue),
            control: control, value: value, inherited: inherited, isDirty: isDirty, errors: errors
        )
    }
}

extension UIView {
    func subview(_ identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for child in subviews {
            if let found = child.subview(identifier) { return found }
        }
        return nil
    }

    func subviews(_ identifier: String) -> [UIView] {
        (accessibilityIdentifier == identifier ? [self] : []) + subviews.flatMap { $0.subviews(identifier) }
    }

    var control: UIView? { subview("field.control") }
    var label: UILabel? { subview("field.label") as? UILabel }
    var help: UILabel? { subview("field.help") as? UILabel }
}

extension UIButton {
    var actions: [UIAction] { menu?.children.compactMap { $0 as? UIAction } ?? [] }

    func action(_ title: String) -> UIAction? { actions.first { $0.title == title } }

    func choose(_ title: String) {
        action(title)?.performWithSender(nil, target: nil)
    }
}
