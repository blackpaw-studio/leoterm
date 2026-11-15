import Foundation

/// The answers being put together for an open questions card: per question,
/// the chosen values (in option order) and the free text as typed.
/// `isComplete` applies the daemon's `validQuestionAnswer` rules, so Submit
/// can stay disabled until the daemon would accept `answersPayload`.
public struct LeoChatQuestionsDraft: Equatable, Hashable, Sendable {
    private struct Entry: Equatable, Hashable, Sendable {
        var selected: [String] = []
        var text = ""
    }

    public let questions: [LeoChatQuestion]
    private let entries: [String: Entry]

    public init(questions: [LeoChatQuestion]) {
        self.init(questions: questions, entries: [:])
    }

    private init(questions: [LeoChatQuestion], entries: [String: Entry]) {
        self.questions = questions
        self.entries = entries
    }

    public func values(for questionID: String) -> [String] { entries[questionID]?.selected ?? [] }

    public func text(for questionID: String) -> String { entries[questionID]?.text ?? "" }

    /// The draft after tapping `value` of a question: a single-select
    /// question takes it (and drops its text; tapping the chosen one again
    /// changes nothing), a multi-select question toggles it. Unknown
    /// questions and values are ignored.
    public func choosing(_ value: String, question questionID: String) -> LeoChatQuestionsDraft {
        guard let question = question(questionID), question.options.contains(where: { $0.value == value }) else { return self }
        let entry = entries[questionID] ?? Entry()
        guard question.multi else {
            guard entry.selected != [value] else { return self }
            return updating(questionID, Entry(selected: [value]))
        }
        let toggled = entry.selected.contains(value) ? entry.selected.filter { $0 != value } : entry.selected + [value]
        return updating(questionID, Entry(selected: question.options.map(\.value).filter(toggled.contains), text: entry.text))
    }

    /// The draft with a question's free text set. Non-blank text on a
    /// single-select question drops its option; blank text keeps it.
    /// Ignored for a question that takes no text.
    public func withText(_ text: String, question questionID: String) -> LeoChatQuestionsDraft {
        guard let question = question(questionID), question.allowsText else { return self }
        let entry = entries[questionID] ?? Entry()
        let clearsOption = !question.multi && !Self.isBlank(text)
        return updating(questionID, Entry(selected: clearsOption ? [] : entry.selected, text: text))
    }

    /// Every question has a value or non-blank text, and no text is over the cap.
    public var isComplete: Bool {
        questions.allSatisfy { question in
            let entry = entries[question.id] ?? Entry()
            let trimmed = Self.trimmed(entry.text)
            return trimmed.unicodeScalars.count <= LeoChatAnswer.maxTextScalars && (!entry.selected.isEmpty || !trimmed.isEmpty)
        }
    }

    /// The `answers` body: values and trimmed text per question id, blank
    /// text dropped.
    public var answersPayload: [String: LeoChatAnswer] {
        Dictionary(uniqueKeysWithValues: questions.map { question in
            let entry = entries[question.id] ?? Entry()
            return (question.id, LeoChatAnswer(values: entry.selected, text: Self.trimmed(entry.text)))
        })
    }

    private func question(_ id: String) -> LeoChatQuestion? { questions.first { $0.id == id } }

    private func updating(_ id: String, _ entry: Entry) -> LeoChatQuestionsDraft {
        LeoChatQuestionsDraft(questions: questions, entries: entries.merging([id: entry]) { _, new in new })
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func isBlank(_ text: String) -> Bool { trimmed(text).isEmpty }
}
