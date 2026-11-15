import Foundation
import Testing

import LeoKit
@testable import Ghostty

@MainActor
struct LeoPluginFormModelTests {
    private struct Emitted: Equatable {
        let action: LeoPluginAction
        let origin: LeoPluginGesture.Origin?
    }

    @MainActor private final class Box { var emitted: [Emitted] = [] }

    private func makeModel(_ form: LeoPluginNode.Form) -> (LeoPluginFormModel, Box) {
        let box = Box()
        let model = LeoPluginFormModel(
            form: form,
            mint: LeoPluginGestureMint(now: { Date(timeIntervalSince1970: 1) }),
            handler: { box.emitted.append(Emitted(action: $0, origin: $1?.origin)) })
        return (model, box)
    }

    private let form = LeoPluginNode.Form(id: "pr", title: "Create PR", fields: [
        .init(id: "title", type: .text, label: "Title", value: "Draft"),
        .init(id: "body", type: .textArea, label: "Body"),
        .init(id: "base", type: .picker, label: "Base", options: [.init(value: "main", title: "main"), .init(value: "dev", title: "dev")]),
        .init(id: "draft", type: .checkbox, label: "Draft", checked: true),
        .init(id: "go", type: .submit, label: "Create", action: .callback(id: "create", payload: .string("p"))),
    ])

    @Test func valuesStartFromFieldDefaults() {
        let (model, _) = makeModel(form)
        #expect(model.values == [
            "title": .string("Draft"), "body": .string(""), "base": .string("main"), "draft": .bool(true),
        ])
    }

    @Test func editedValuesAreSubmittedWithTheCallbackAndAKeyboardOrClickGesture() {
        let (model, box) = makeModel(form)
        model.setText("Fix bug", for: "title")
        model.setText("Why", for: "body")
        model.setChoice("dev", for: "base")
        model.setChecked(false, for: "draft")
        #expect(model.submit(fieldID: "go", origin: .click))

        let expected = LeoPluginAction.callback(id: "create", payload: .object([
            "formId": .string("pr"),
            "payload": .string("p"),
            "values": .object([
                "title": .string("Fix bug"), "body": .string("Why"), "base": .string("dev"), "draft": .bool(false),
            ]),
        ]))
        #expect(box.emitted == [Emitted(action: expected, origin: .click)])
    }

    @Test func aPickerRejectsAValueThatIsNotAnOption() {
        let (model, _) = makeModel(form)
        model.setChoice("evil", for: "base")
        #expect(model.values["base"] == .string("main"))
    }

    @Test func unknownFieldsAreIgnored() {
        let (model, _) = makeModel(form)
        model.setText("x", for: "nope")
        #expect(model.values["nope"] == nil)
    }

    @Test func nonCallbackSubmitActionsPassThroughUnchanged() {
        let copy = LeoPluginAction.copy("hi")
        let f = LeoPluginNode.Form(id: "f", fields: [.init(id: "go", type: .submit, label: "Go", action: copy)])
        let (model, box) = makeModel(f)
        #expect(model.submit(fieldID: "go", origin: .keyboard))
        #expect(box.emitted == [Emitted(action: copy, origin: .keyboard)])
    }

    @Test func submitWithoutAnActionOrOnANonSubmitFieldDoesNothing() {
        let f = LeoPluginNode.Form(id: "f", fields: [
            .init(id: "t", type: .text), .init(id: "go", type: .submit, label: "Go"),
        ])
        let (model, box) = makeModel(f)
        #expect(!model.submit(fieldID: "go", origin: .click))
        #expect(!model.submit(fieldID: "t", origin: .click))
        #expect(box.emitted.isEmpty)
    }

    @Test func reapplyingAnUnchangedFormKeepsTheUsersEdits() {
        let (model, _) = makeModel(form)
        model.setText("typing", for: "title")
        model.apply(form: form)
        #expect(model.values["title"] == .string("typing"))
    }

    @Test func reapplyingAChangedFormDropsValuesOfRemovedFieldsAndKeepsTheRest() {
        let (model, _) = makeModel(form)
        model.setText("typing", for: "title")
        var smaller = form
        smaller.fields.removeAll { $0.id == "body" }
        smaller.fields.append(.init(id: "extra", type: .text, value: "e"))
        model.apply(form: smaller)
        #expect(model.values["body"] == nil)
        #expect(model.values["title"] == .string("typing"))
        #expect(model.values["extra"] == .string("e"))
    }
}
