import Foundation
import Testing

@testable import LeoKit

/// The answer rules from leo `docs/configuration/chat.md` ("Ask inputs"),
/// one row per rule: a draft becomes an answer only when the daemon would
/// accept it.
struct LeoChatAskDraftTests {
    static let abc = ["a", "b", "c"].map { LeoChatOption(value: $0, label: $0.uppercased()) }

    static func input(
        _ kind: LeoChatInput.Kind, allowsText: Bool = false, min: Int = 0, max: Int? = nil
    ) throws -> LeoChatInput {
        try LeoChatInput(kind: kind, options: kind == .text ? [] : abc, allowsText: allowsText, min: min, max: max)
    }

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let input: @Sendable () throws -> LeoChatInput
        let selected: [String]
        let text: String
        let expected: LeoChatAnswer?

        var testDescription: String { name }
    }

    static let rows: [Row] = [
        // buttons/radio: exactly one known value
        Row(name: "radio, one value", input: { try input(.radio) }, selected: ["b"], text: "", expected: .choice("b")),
        Row(name: "buttons, one value", input: { try input(.buttons) }, selected: ["a"], text: "", expected: .choice("a")),
        Row(name: "radio, nothing chosen", input: { try input(.radio) }, selected: [], text: "", expected: nil),
        Row(name: "radio, unknown value", input: { try input(.radio) }, selected: ["z"], text: "", expected: nil),
        // ...or, with allow_text, no value and non-empty text
        Row(name: "radio allow_text, text only", input: { try input(.radio, allowsText: true) }, selected: [], text: " other ",
            expected: LeoChatAnswer(values: [], text: "other")),
        Row(name: "radio allow_text, value and text", input: { try input(.radio, allowsText: true) }, selected: ["a"], text: "why",
            expected: LeoChatAnswer(values: ["a"], text: "why")),
        Row(name: "radio allow_text, nothing", input: { try input(.radio, allowsText: true) }, selected: [], text: "  ", expected: nil),
        // text is refused on a choice type without allow_text
        Row(name: "radio, text without allow_text", input: { try input(.radio) }, selected: ["a"], text: "why", expected: nil),
        // checkboxes: min <= count <= max
        Row(name: "checkboxes, within bounds", input: { try input(.checkboxes, min: 1, max: 2) }, selected: ["a", "c"], text: "",
            expected: LeoChatAnswer(values: ["a", "c"])),
        Row(name: "checkboxes, too many", input: { try input(.checkboxes, min: 1, max: 2) }, selected: ["a", "b", "c"], text: "", expected: nil),
        Row(name: "checkboxes, too few", input: { try input(.checkboxes, min: 1, max: 2) }, selected: [], text: "", expected: nil),
        Row(name: "checkboxes min 0, empty is an answer", input: { try input(.checkboxes) }, selected: [], text: "",
            expected: LeoChatAnswer(values: [])),
        // with allow_text, text may replace the selection, even if min > 0
        Row(name: "checkboxes min 1 allow_text, text only", input: { try input(.checkboxes, allowsText: true, min: 1) }, selected: [],
            text: "none fit", expected: LeoChatAnswer(values: [], text: "none fit")),
        Row(name: "checkboxes allow_text, text alongside", input: { try input(.checkboxes, allowsText: true, min: 2) }, selected: ["a", "b"],
            text: "and more", expected: LeoChatAnswer(values: ["a", "b"], text: "and more")),
        Row(name: "checkboxes allow_text, text cannot rescue too few", input: { try input(.checkboxes, allowsText: true, min: 2) },
            selected: ["a"], text: "and more", expected: nil),
        // text: no values, non-empty text
        Row(name: "text, trimmed", input: { try input(.text) }, selected: [], text: "\n ship it \n", expected: LeoChatAnswer(values: [], text: "ship it")),
        Row(name: "text, whitespace only", input: { try input(.text) }, selected: [], text: " \n\t", expected: nil),
        // text is at most 4000 characters
        Row(name: "text, 4000 scalars", input: { try input(.text) }, selected: [], text: String(repeating: "é", count: 4000),
            expected: LeoChatAnswer(values: [], text: String(repeating: "é", count: 4000))),
        Row(name: "text, 4001 scalars", input: { try input(.text) }, selected: [], text: String(repeating: "é", count: 4001), expected: nil),
    ]

    @Test(arguments: rows)
    func aDraftAnswersOnlyWhatTheDaemonAccepts(row: Row) throws {
        let draft = LeoChatAskDraft(selected: row.selected, text: row.text)
        #expect(draft.answer(for: try row.input()) == row.expected)
    }

    @Test func radioReplacesTheSelection() throws {
        let radio = try Self.input(.radio)
        let draft = LeoChatAskDraft().choosing("c", in: radio).choosing("a", in: radio)
        #expect(draft.selected == ["a"])
    }

    @Test func checkboxesToggleAndKeepOptionOrder() throws {
        let boxes = try Self.input(.checkboxes)
        let draft = LeoChatAskDraft().choosing("c", in: boxes).choosing("a", in: boxes).choosing("b", in: boxes).choosing("c", in: boxes)
        #expect(draft.selected == ["a", "b"])
    }

    @Test func anUnknownValueIsNotChosen() throws {
        #expect(LeoChatAskDraft().choosing("z", in: try Self.input(.checkboxes)).selected.isEmpty)
    }

    @Test func withTextKeepsTheSelection() throws {
        let draft = LeoChatAskDraft().choosing("a", in: try Self.input(.radio)).withText("note")
        #expect(draft == LeoChatAskDraft(selected: ["a"], text: "note"))
    }

    @Test func remainingTextCountsUnicodeScalars() {
        #expect(LeoChatAskDraft().remainingTextScalars == 4000)
        #expect(LeoChatAskDraft(text: "é👍🏽").remainingTextScalars == 3997)
        #expect(LeoChatAskDraft(text: String(repeating: "x", count: 4001)).remainingTextScalars == -1)
    }
}
