import LeoKit
import Testing
import UIKit

@testable import Leo

@MainActor
struct SchemaFormCellTests {
    nonisolated static let everyControl: [LeoConfigControl] = [
        .text(placeholder: nil), .multiline, .number(min: nil, max: nil, placeholder: nil), .toggle, .triState,
        .picker(options: [LeoConfigOption(value: "a", label: "A")]),
        .referencePicker(collection: "environments", names: ["prod"], emptyLabel: "None"),
        .list, .keyValue, .duration(placeholder: nil), .cron, .yaml, .secret(.notSet),
        .suggestions(["opus"], placeholder: nil), .readOnlyUnknown(typeName: "blob", webLink: nil),
    ]

    // MARK: every control

    @Test(arguments: SchemaFormCellTests.everyControl)
    func everyControlShowsItsLabelHelpAndAControl(control: LeoConfigControl) {
        let view = CellHarness.view(
            CellHarness.row(control, label: "Model", help: "The model to run."), recorder: CellRecorder()
        )

        #expect(view.label?.text == "Model")
        #expect(view.help?.text == "The model to run.")
        #expect(view.help?.textColor == .secondaryLabel)
        #expect(view.control != nil)
    }

    /// A list cell sizes itself from its content view; an unconstrained one
    /// makes UIKit throw ("Content view returned an invalid size").
    @Test(arguments: SchemaFormCellTests.everyControl)
    func everyControlSizesItselfToAFiniteHeight(control: LeoConfigControl) {
        let view = CellHarness.view(
            CellHarness.row(control, help: "Some help.", warning: "Careful.", errors: ["Bad"]), recorder: CellRecorder()
        )

        for target in [UIView.layoutFittingCompressedSize.height, UIView.layoutFittingExpandedSize.height] {
            let size = view.systemLayoutSizeFitting(
                CGSize(width: 370, height: target), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            )
            #expect(size.height > 0 && size.height < 2_000, "target \(target)")
        }
    }

    @Test func emptyHelpIsHidden() {
        let view = CellHarness.view(CellHarness.row(.toggle, help: ""), recorder: CellRecorder())

        #expect(view.help?.isHidden == true)
    }

    @Test func dirtyMarkerFollowsTheRow() {
        let clean = CellHarness.view(CellHarness.row(.toggle), recorder: CellRecorder())
        let dirty = CellHarness.view(CellHarness.row(.toggle, isDirty: true), recorder: CellRecorder())

        #expect(clean.subview("field.dirty")?.isHidden == true)
        #expect(dirty.subview("field.dirty")?.isHidden == false)
    }

    @Test func warningAndEachErrorShowUnderTheField() {
        let view = CellHarness.view(
            CellHarness.row(.text(placeholder: nil), warning: "Changes the harness.", errors: ["Required", "Too long"]),
            recorder: CellRecorder()
        )

        let warning = view.subview("field.warning") as? UILabel
        #expect(warning?.text?.contains("Changes the harness.") == true)
        #expect(warning?.isHidden == false)
        #expect(view.subviews("field.error").compactMap { ($0 as? UILabel)?.text } == ["Required", "Too long"])
    }

    @Test func noWarningOrErrorsMeansNoneShown() {
        let view = CellHarness.view(CellHarness.row(.text(placeholder: nil)), recorder: CellRecorder())

        #expect(view.subview("field.warning")?.isHidden == true)
        #expect(view.subviews("field.error").isEmpty)
    }

    @Test func aRowUpdatesInPlace() throws {
        let recorder = CellRecorder()
        let view = CellHarness.view(CellHarness.row(.text(placeholder: nil), value: .string("one")), recorder: recorder)

        view.configuration = SchemaFieldContentConfiguration(
            row: CellHarness.row(.text(placeholder: nil), value: .string("two")), cronPreview: nil, handlers: recorder.handlers
        )

        #expect(try #require(view.control as? UITextField).text == "two")
    }

    // MARK: text-like

    @Test func textEditEmitsAStringOrNullWhenEmptied() throws {
        let recorder = CellRecorder()
        let view = CellHarness.view(CellHarness.row(.text(placeholder: "inherit: opus"), value: .string("a")), recorder: recorder)
        let field = try #require(view.control as? UITextField)
        #expect(field.text == "a")
        #expect(field.placeholder == "inherit: opus")

        field.text = "ab"
        field.sendActions(for: .editingChanged)
        field.text = ""
        field.sendActions(for: .editingChanged)

        #expect(recorder.edits == [.init(path: "field", value: .string("ab")), .init(path: "field", value: .null)])
    }

    @Test(arguments: [LeoConfigControl.duration(placeholder: "10m"), .cron, .suggestions(["opus"], placeholder: "x")])
    func otherTextControlsEmitStrings(control: LeoConfigControl) throws {
        let recorder = CellRecorder()
        let view = CellHarness.view(CellHarness.row(control, value: .string("5m")), recorder: recorder)
        let field = try #require(view.control as? UITextField)
        #expect(field.text == "5m")

        field.text = "7m"
        field.sendActions(for: .editingChanged)

        #expect(recorder.lastValue == .string("7m"))
    }

    @Test func numberReadsAsIntEmptyAsUnsetAndJunkIsKeptForTheValidator() throws {
        let recorder = CellRecorder()
        let control = LeoConfigControl.number(min: 1, max: 9, placeholder: nil)
        let view = CellHarness.view(CellHarness.row(control, value: .int(7)), recorder: recorder)
        let field = try #require(view.control as? UITextField)
        #expect(field.text == "7")

        for typed in ["42", " ", "4x"] {
            field.text = typed
            field.sendActions(for: .editingChanged)
        }

        #expect(recorder.edits.map(\.value) == [.int(42), .null, .string("4x")])
        let junk = CellHarness.view(CellHarness.row(control, value: .string("4x")), recorder: recorder)
        #expect(try #require(junk.control as? UITextField).text == "4x")
    }

    @Test func aTypedValueThatReadsTheSameIsNotOverwrittenWhileEditing() throws {
        let recorder = CellRecorder()
        let control = LeoConfigControl.number(min: nil, max: nil, placeholder: nil)
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let view = CellHarness.view(CellHarness.row(control, value: .int(4)), recorder: recorder)
        host.addSubview(view)
        host.makeKeyAndVisible()
        let field = try #require(view.control as? UITextField)
        field.becomeFirstResponder()
        field.text = "04"

        view.configuration = SchemaFieldContentConfiguration(
            row: CellHarness.row(control, value: .int(4)), cronPreview: nil, handlers: recorder.handlers
        )

        #expect(field.text == "04")
    }

    // MARK: bool

    @Test func toggleShowsTheValueOrTheDefaultAndEmitsBool() throws {
        let recorder = CellRecorder()
        let set = CellHarness.view(CellHarness.row(.toggle, value: .bool(true)), recorder: recorder)
        let defaulted = CellHarness.view(CellHarness.row(.toggle, defaultValue: .bool(true)), recorder: recorder)
        #expect(try #require(set.control as? UISwitch).isOn)
        #expect(try #require(defaulted.control as? UISwitch).isOn)

        let toggle = try #require(set.control as? UISwitch)
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)

        #expect(recorder.lastValue == .bool(false))
    }

    @Test func triStateMenuOffersInheritOnOffAndEmitsEach() throws {
        let recorder = CellRecorder()
        let row = CellHarness.row(.triState, value: .bool(true), inherited: .bool(false))
        let button = try #require(CellHarness.view(row, recorder: recorder).control as? UIButton)
        #expect(button.actions.map(\.title) == ["Inherit (off)", "On", "Off"])
        #expect(button.action("On")?.state == .on)

        button.choose("Inherit (off)")
        button.choose("On")
        button.choose("Off")

        #expect(recorder.edits.map(\.value) == [.null, .bool(true), .bool(false)])
    }

    @Test func triStateUnsetSelectsInherit() throws {
        let button = try #require(
            CellHarness.view(CellHarness.row(.triState, value: .null), recorder: CellRecorder()).control as? UIButton
        )

        #expect(button.action("Inherit")?.state == .on)
    }

    // MARK: pickers

    @Test func pickerMenuListsTheOptionsSelectsTheValueAndEmitsIt() throws {
        let recorder = CellRecorder()
        let options = [LeoConfigOption(value: "low", label: "Low"), LeoConfigOption(value: "high", label: "High")]
        let button = try #require(
            CellHarness.view(CellHarness.row(.picker(options: options), value: .string("high")), recorder: recorder).control as? UIButton
        )
        #expect(button.actions.map(\.title) == ["Low", "High"])
        #expect(button.action("High")?.state == .on)

        button.choose("Low")

        #expect(recorder.lastValue == .string("low"))
    }

    @Test func pickerKeepsAValueTheListDoesNotHave() throws {
        let control = LeoConfigControl.picker(options: [LeoConfigOption(value: "low", label: "Low")])
        let button = try #require(
            CellHarness.view(CellHarness.row(control, value: .string("max")), recorder: CellRecorder()).control as? UIButton
        )

        #expect(button.actions.map(\.title) == ["Low", "max"])
        #expect(button.action("max")?.state == .on)
    }

    @Test func referencePickerOffersTheEmptyChoiceAndMarksAMissingReference() throws {
        let recorder = CellRecorder()
        let control = LeoConfigControl.referencePicker(collection: "environments", names: ["prod", "dev"], emptyLabel: "No environment")
        let button = try #require(
            CellHarness.view(CellHarness.row(control, value: .string("gone")), recorder: recorder).control as? UIButton
        )
        #expect(button.actions.map(\.title) == ["No environment", "prod", "dev", "gone (missing)"])
        #expect(button.action("gone (missing)")?.state == .on)

        button.choose("prod")
        button.choose("No environment")

        #expect(recorder.edits.map(\.value) == [.string("prod"), .string("")])
    }

    @Test func suggestionsMenuFillsTheField() throws {
        let recorder = CellRecorder()
        let view = CellHarness.view(
            CellHarness.row(.suggestions(["opus", "sonnet"], placeholder: nil), value: .string("x")), recorder: recorder
        )
        let menu = try #require(view.subview("field.suggestions") as? UIButton)
        #expect(menu.actions.map(\.title) == ["opus", "sonnet"])

        menu.choose("sonnet")

        #expect(recorder.lastValue == .string("sonnet"))
        #expect(try #require(view.control as? UITextField).text == "sonnet")
    }

    // MARK: cron

    @Test func cronShowsTheDaemonsReadingOrWhyItIsInvalid() throws {
        let valid = CellHarness.view(CellHarness.row(.cron, value: .string("0 9 * * *")), cron: .valid("Every day at 9:00"), recorder: CellRecorder())
        let invalid = CellHarness.view(CellHarness.row(.cron, value: .string("nope")), cron: .invalid("expected 5 fields"), recorder: CellRecorder())
        let none = CellHarness.view(CellHarness.row(.cron), recorder: CellRecorder())

        let validLabel = try #require(valid.subview("field.cronPreview") as? UILabel)
        #expect(validLabel.text == "Every day at 9:00")
        #expect(validLabel.textColor == .secondaryLabel)
        let invalidLabel = try #require(invalid.subview("field.cronPreview") as? UILabel)
        #expect(invalidLabel.text == "expected 5 fields")
        #expect(invalidLabel.textColor == .systemRed)
        #expect(none.subview("field.cronPreview")?.isHidden == true)
    }

    // MARK: secret

    @Test func secretMenuFollowsTheState() throws {
        let cases: [(LeoConfigSecretState, String, [String])] = [
            (.set, "Set", ["Replace…", "Clear"]),
            (.notSet, "Not set", ["Set…"]),
            (.replacing, "Will be replaced", ["Undo"]),
            (.clearing, "Will be cleared", ["Undo"]),
        ]
        for (state, summary, titles) in cases {
            let button = try #require(
                CellHarness.view(CellHarness.row(.secret(state)), recorder: CellRecorder()).control as? UIButton
            )
            #expect(button.configuration?.title == summary, "\(state)")
            #expect(button.actions.map(\.title) == titles, "\(state)")
        }
    }

    @Test func replaceAsksForTheValueAndEmitsIt() throws {
        let recorder = CellRecorder()
        recorder.secretAnswer = "hunter2"
        let button = try #require(
            CellHarness.view(CellHarness.row(.secret(.set), label: "API key"), recorder: recorder).control as? UIButton
        )

        button.choose("Replace…")

        #expect(recorder.secretPrompts == ["API key"])
        #expect(recorder.lastValue == .secretReplace("hunter2"))
    }

    @Test func cancellingTheSecretPromptEmitsNothing() throws {
        let recorder = CellRecorder()
        let button = try #require(CellHarness.view(CellHarness.row(.secret(.notSet)), recorder: recorder).control as? UIButton)

        button.choose("Set…")

        #expect(recorder.secretPrompts.count == 1)
        #expect(recorder.edits.isEmpty)
    }

    @Test func aBlankSecretIsNotSent() throws {
        let recorder = CellRecorder()
        recorder.secretAnswer = ""
        let button = try #require(CellHarness.view(CellHarness.row(.secret(.set)), recorder: recorder).control as? UIButton)

        button.choose("Replace…")

        #expect(recorder.edits.isEmpty)
    }

    @Test func clearEmitsClearAndUndoReverts() throws {
        let recorder = CellRecorder()
        let set = try #require(CellHarness.view(CellHarness.row(.secret(.set)), recorder: recorder).control as? UIButton)
        let pending = try #require(CellHarness.view(CellHarness.row(.secret(.clearing), path: "token"), recorder: recorder).control as? UIButton)

        set.choose("Clear")
        pending.choose("Undo")

        #expect(recorder.lastValue == .secretClear)
        #expect(recorder.reverts == ["token"])
    }

    // MARK: pushed editors

    @Test func listKeyValueAndTextControlsPushTheirEditor() throws {
        let recorder = CellRecorder()
        let list = CellHarness.row(.list, value: .list([.string("a"), .string("b")]))
        let env = CellHarness.row(.keyValue, value: .object(["A": .string("1")]))
        let notes = CellHarness.row(.multiline, value: .string("line one\nline two"))
        let yaml = CellHarness.row(.yaml, value: .string("a: 1"))

        for row in [list, env, notes, yaml] {
            try #require(CellHarness.view(row, recorder: recorder).control as? UIButton)
                .sendActions(for: .primaryActionTriggered)
        }

        #expect(recorder.pushes == [.list(list), .keyValue(env), .text(notes), .text(yaml)])
        #expect(recorder.pushes.map(\.isMonospaced) == [false, false, false, true])
    }

    @Test func selectingTheRowPushesTheEditorLikeItsChevron() throws {
        let recorder = CellRecorder()
        let list = CellHarness.row(.list, value: .list([.string("a")]))
        let env = CellHarness.row(.keyValue, value: .object(["A": .string("1")]))
        let notes = CellHarness.row(.multiline, value: .string("line one"))
        let yaml = CellHarness.row(.yaml, value: .string("a: 1"))

        for row in [list, env, notes, yaml] {
            try #require(CellHarness.view(row, recorder: recorder) as? SchemaFieldContentView).activate()
        }

        #expect(recorder.pushes == [.list(list), .keyValue(env), .text(notes), .text(yaml)])
    }

    @Test func aMenuRowLaysItsMenuOverTheWholeRow() throws {
        let rows = [
            CellHarness.row(.triState, value: .bool(true)),
            CellHarness.row(.picker(options: [LeoConfigOption(value: "a", label: "A")]), value: .string("a")),
            CellHarness.row(.referencePicker(collection: "templates", names: ["coder"], emptyLabel: "None")),
            CellHarness.row(.secret(.notSet)),
        ]
        for row in rows {
            let view = CellHarness.view(row, recorder: CellRecorder())
            let button = try #require(view.control as? UIButton)
            let overlay = try #require(view.subview("field.rowMenu") as? UIButton)
            #expect(overlay.frame == view.bounds)
            #expect(overlay.showsMenuAsPrimaryAction)
            let titles = { (menu: UIMenu?) in menu?.children.map { $0.title } }
            #expect(titles(overlay.menu) == titles(button.menu))
            #expect(!overlay.isAccessibilityElement)
        }
        #expect(CellHarness.view(CellHarness.row(.list), recorder: CellRecorder()).subview("field.rowMenu") == nil)
    }

    @Test func pushedControlsSummariseTheirValue() throws {
        func summary(_ row: LeoConfigFormRow) throws -> String? {
            try #require(CellHarness.view(row, recorder: CellRecorder()).control as? UIButton).configuration?.title
        }

        #expect(try summary(CellHarness.row(.list, value: .list([.string("a"), .string("b")]))) == "2 items")
        #expect(try summary(CellHarness.row(.list, value: .list([.string("a")]))) == "1 item")
        #expect(try summary(CellHarness.row(.list)) == "None")
        #expect(try summary(CellHarness.row(.keyValue, value: .object(["A": .string("1"), "B": .secret(isSet: true)]))) == "2 variables")
        #expect(try summary(CellHarness.row(.multiline, value: .string("line one\nline two"))) == "line one")
        #expect(try summary(CellHarness.row(.yaml)) == "Empty")
    }

    // MARK: unknown

    @Test func unknownIsReadOnlyAndLinksOnlyWithAURL() throws {
        let recorder = CellRecorder()
        let url = try #require(URL(string: "https://leo.example.com/config/templates/x"))
        let linked = CellHarness.view(CellHarness.row(.readOnlyUnknown(typeName: "blob", webLink: url)), recorder: recorder)
        let unlinked = CellHarness.view(CellHarness.row(.readOnlyUnknown(typeName: "blob", webLink: nil)), recorder: recorder)

        #expect(linked.control is UILabel)
        #expect(unlinked.control is UILabel)
        #expect(unlinked.subview("field.webLink") == nil)
        try #require(linked.subview("field.webLink") as? UIButton).sendActions(for: .primaryActionTriggered)

        #expect(recorder.opened == [url])
        #expect(recorder.edits.isEmpty)
    }
}

/// The same sizing check over the rows a real template form lays out.
@MainActor
struct SchemaFormGoldenSizingTests {
    @Test func everyRowOfARealTemplateFormSizesItself() async throws {
        let client = try ConfigGolden.client()
        var core = LeoConfigCollectionState(resource: "templates", autoSelectsFirst: false)
        core.loaded(await LeoConfigCollectionOps.load(resource: "templates", client: client, references: [:]))
        core.selectNow("coder")

        var unsized: [String] = []
        let targets = [
            CGSize(width: 370, height: UIView.layoutFittingCompressedSize.height),
            CGSize(width: 370, height: UIView.layoutFittingExpandedSize.height),
        ]
        for row in core.sections.flatMap(\.rows) {
            let view = CellHarness.view(row, recorder: CellRecorder())
            for target in targets {
                let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                if !(size.height > 0 && size.height < 2_000) { unsized.append("\(row.path) \(target.height): \(size.height)") }
            }
        }

        #expect(unsized.isEmpty, "\(unsized)")
    }
}

@MainActor
struct KeyValueEditorTests {
    private static func undoButton(
        value: LeoConfigValue, base: LeoConfigValue, recorder: CellRecorder
    ) throws -> (editor: KeyValueEditorViewController, button: UIButton) {
        let row = CellHarness.row(.keyValue, value: value, base: base)
        let editor = KeyValueEditorViewController(row: row, handlers: recorder.handlers)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        editor.tableView.layoutIfNeeded()
        let cell = try #require(editor.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        return (editor, try #require(cell.accessoryView as? UIButton))
    }

    @Test(arguments: [LeoConfigSecretState.notSet, .set])
    func undoRestoresTheSecretToWhatItWasBeforeTheEdit(original: LeoConfigSecretState) throws {
        let recorder = CellRecorder()
        let was = LeoConfigValue.secret(isSet: original == .set)
        let (editor, button) = try Self.undoButton(
            value: .object(["TOKEN": .secretReplace("x")]), base: .object(["TOKEN": was]), recorder: recorder
        )

        button.choose("Undo")
        withExtendedLifetime(editor) {}

        #expect(recorder.lastValue == .object(["TOKEN": was]))
    }
}
