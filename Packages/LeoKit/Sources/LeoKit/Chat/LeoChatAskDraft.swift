import Foundation

/// An answer being put together for an open `ask`: the chosen values (in
/// option order) and the free text as typed. `answer(for:)` applies the
/// daemon's `validAnswerFor` rules, so a submit button can stay disabled
/// until the daemon would accept what it sends.
public struct LeoChatAskDraft: Equatable, Hashable, Sendable {
    public let selected: [String]
    public let text: String

    public init(selected: [String] = [], text: String = "") {
        self.selected = selected
        self.text = text
    }

    /// The draft after tapping `value`: `radio` (and `buttons`) replace
    /// the selection, and tapping the selected radio choice clears it (so
    /// an `allow_text` ask can be answered with text alone); `checkboxes`
    /// toggle it. Values not in `input` are ignored.
    public func choosing(_ value: String, in input: LeoChatInput) -> LeoChatAskDraft {
        guard input.options.contains(where: { $0.value == value }) else { return self }
        if input.kind == .radio, selected == [value] { return LeoChatAskDraft(text: text) }
        guard input.kind == .checkboxes else { return LeoChatAskDraft(selected: [value], text: text) }
        let toggled = selected.contains(value) ? selected.filter { $0 != value } : selected + [value]
        let order = input.options.map(\.value)
        return LeoChatAskDraft(selected: order.filter(toggled.contains), text: text)
    }

    public func withText(_ text: String) -> LeoChatAskDraft {
        LeoChatAskDraft(selected: selected, text: text)
    }

    /// How many more characters the text field takes; negative once over.
    public var remainingTextScalars: Int {
        LeoChatAnswer.maxTextScalars - text.unicodeScalars.count
    }

    /// The answer to send, with the text trimmed, or nil while the daemon
    /// would refuse it.
    public func answer(for input: LeoChatInput) -> LeoChatAnswer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count <= LeoChatAnswer.maxTextScalars else { return nil }
        let answer = LeoChatAnswer(values: selected, text: trimmed)
        return Self.isValid(answer, for: input) ? answer : nil
    }

    /// The daemon's `validAnswerFor` (leo `internal/chat/input.go`).
    static func isValid(_ answer: LeoChatAnswer, for input: LeoChatInput) -> Bool {
        let hasText = answer.text != nil
        guard input.kind != .text else { return answer.values.isEmpty && hasText }
        if hasText, !input.allowsText { return false }
        let known = Set(input.options.map(\.value))
        guard answer.values.allSatisfy(known.contains), Set(answer.values).count == answer.values.count else { return false }
        if answer.values.isEmpty, input.allowsText { return hasText }
        if input.kind == .checkboxes { return (input.min...input.max).contains(answer.values.count) }
        return answer.values.count == 1
    }
}
