import Foundation
import Testing

@testable import LeoKit

struct LeoChatQuestionsDraftTests {
    static let questions = [
        LeoChatQuestion(
            id: "q1", header: "Library", question: "Which library?",
            options: [LeoChatOption(value: "Swift", label: "Swift"), LeoChatOption(value: "Zig", label: "Zig")]
        ),
        LeoChatQuestion(
            id: "q2", header: "Scope", question: "Which scopes?", multi: true,
            options: [LeoChatOption(value: "A", label: "A"), LeoChatOption(value: "B", label: "B"), LeoChatOption(value: "C", label: "C")]
        ),
    ]

    static var draft: LeoChatQuestionsDraft { LeoChatQuestionsDraft(questions: questions) }

    @Test func choosingOnASingleSelectQuestionReplacesTheValueAndClearsTheText() {
        let draft = Self.draft.choosing("Swift", question: "q1").withText("Go", question: "q1").choosing("Zig", question: "q1")

        #expect(draft.values(for: "q1") == ["Zig"])
        #expect(draft.text(for: "q1") == "")
    }

    @Test func choosingTheSelectedSingleSelectOptionAgainChangesNothing() {
        let once = Self.draft.choosing("Swift", question: "q1")
        #expect(once.choosing("Swift", question: "q1") == once)
    }

    @Test func typingNonBlankTextOnASingleSelectQuestionClearsTheOption() {
        let draft = Self.draft.choosing("Swift", question: "q1").withText("Go", question: "q1")

        #expect(draft.values(for: "q1").isEmpty)
        #expect(draft.text(for: "q1") == "Go")
    }

    @Test func blankTextKeepsTheOption() {
        let draft = Self.draft.choosing("Swift", question: "q1").withText("   ", question: "q1")

        #expect(draft.values(for: "q1") == ["Swift"])
    }

    @Test func multiSelectTogglesInOptionOrderAndKeepsTheText() {
        let draft = Self.draft
            .choosing("C", question: "q2").choosing("A", question: "q2").withText("docs", question: "q2")
            .choosing("B", question: "q2").choosing("C", question: "q2")

        #expect(draft.values(for: "q2") == ["A", "B"])
        #expect(draft.text(for: "q2") == "docs")
    }

    @Test func unknownValuesAndQuestionIDsAreIgnored() {
        let draft = Self.draft.choosing("Nope", question: "q1").choosing("Swift", question: "q9").withText("x", question: "q9")

        #expect(draft == Self.draft)
        #expect(draft.values(for: "q9").isEmpty)
        #expect(draft.text(for: "q9") == "")
    }

    @Test func aQuestionThatTakesNoTextIgnoresTyping() {
        let noText = LeoChatQuestion(id: "q1", question: "?", allowsText: false, options: [LeoChatOption(value: "a", label: "a")])
        let draft = LeoChatQuestionsDraft(questions: [noText]).choosing("a", question: "q1").withText("x", question: "q1")

        #expect(draft.values(for: "q1") == ["a"])
        #expect(draft.text(for: "q1") == "")
    }

    @Test(arguments: [
        (LeoChatQuestionsDraftTests.draft, false),
        (LeoChatQuestionsDraftTests.draft.choosing("Swift", question: "q1"), false),
        (LeoChatQuestionsDraftTests.draft.choosing("Swift", question: "q1").withText("   ", question: "q2"), false),
        (LeoChatQuestionsDraftTests.draft.choosing("Swift", question: "q1").withText(String(repeating: "x", count: 4001), question: "q2"), false),
        (LeoChatQuestionsDraftTests.draft.choosing("Swift", question: "q1").choosing("A", question: "q2"), true),
        (LeoChatQuestionsDraftTests.draft.choosing("Swift", question: "q1").withText("why", question: "q2"), true),
        (LeoChatQuestionsDraftTests.draft.withText("Go", question: "q1").withText(String(repeating: "x", count: 4000), question: "q2"), true),
    ])
    func isCompleteNeedsEveryQuestionAnswered(draft: LeoChatQuestionsDraft, expected: Bool) {
        #expect(draft.isComplete == expected)
    }

    @Test func thePayloadTrimsTextAndDropsBlankText() {
        let draft = Self.draft.choosing("Swift", question: "q1").withText("  why \n", question: "q2")
        let blank = Self.draft.choosing("Swift", question: "q1").withText("  ", question: "q1").choosing("A", question: "q2")

        #expect(draft.answersPayload == ["q1": .choice("Swift"), "q2": LeoChatAnswer(values: [], text: "why")])
        #expect(blank.answersPayload == ["q1": .choice("Swift"), "q2": .choice("A")])
    }
}
