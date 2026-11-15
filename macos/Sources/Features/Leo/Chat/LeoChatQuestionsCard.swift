import LeoKit
import SwiftUI

/// An AskUserQuestion card: every question with its options (radio rows, or
/// checkboxes for a multi-select question) and an "Other…" field, then
/// Submit and "Answer in terminal"; once settled, what was answered, or
/// that it moved to the terminal, timed out or expired.
struct LeoChatQuestionsCard: View {
    let message: LeoChatMessage
    @ObservedObject var chat: LeoChatPaneModel

    var body: some View {
        switch message.questionsCard {
        case .open:
            if let input = message.input {
                LeoChatOpenQuestions(messageID: message.id, questions: input.questions, chat: chat)
            }
        case .answered(let lines):
            LeoChatSettledQuestions(lines: lines)
        case .inTerminal:
            Label("Answered in terminal", systemImage: "terminal").font(.callout).foregroundStyle(.secondary)
        case .timedOut:
            Label("Timed out", systemImage: "clock.badge.xmark").font(.callout).foregroundStyle(.secondary)
        case .expired:
            Label("Expired", systemImage: "clock.badge.xmark").font(.callout).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}

/// What an answered card recorded: one line per question, its header
/// leading in bold.
private struct LeoChatSettledQuestions: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Answered", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(Self.attributed(line)).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `header: answer` with the header semibold; a line without the
    /// separator stays plain.
    static func attributed(_ line: String) -> AttributedString {
        var text = AttributedString(line)
        guard let separator = line.range(of: ": "),
              let header = AttributedString(line).range(of: line[..<separator.lowerBound]) else { return text }
        text[header].font = .callout.weight(.semibold)
        return text
    }
}

private struct LeoChatOpenQuestions: View {
    let messageID: String
    let questions: [LeoChatQuestion]
    @ObservedObject var chat: LeoChatPaneModel

    private var draft: LeoChatQuestionsDraft { chat.questionsDraft(for: messageID) ?? LeoChatQuestionsDraft(questions: questions) }
    private var isAnswering: Bool { chat.answering.contains(messageID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(questions) { question in
                LeoChatQuestionSection(
                    messageID: messageID, question: question, draft: draft, chat: chat
                )
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isAnswering)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = chat.questionsErrors[messageID] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.questions.error")
            }
            HStack(spacing: 8) {
                Button("Answer in terminal") { Task { await chat.dismissQuestions(messageID: messageID) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("chat.questions.dismiss")
                Spacer(minLength: 8)
                if isAnswering { ProgressView().controlSize(.small) }
                Button("Submit") { Task { await chat.submitQuestions(messageID: messageID) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!draft.isComplete)
                    .accessibilityIdentifier("chat.questions.submit")
            }
        }
    }
}

private struct LeoChatQuestionSection: View {
    let messageID: String
    let question: LeoChatQuestion
    let draft: LeoChatQuestionsDraft
    @ObservedObject var chat: LeoChatPaneModel

    private var isTooLong: Bool {
        draft.text(for: question.id).trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > LeoChatAnswer.maxTextScalars
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            Text(question.question).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(question.options, id: \.value) { option in
                    optionRow(option)
                        .accessibilityIdentifier("chat.questions.\(question.id).option.\(option.value)")
                }
            }
            .padding(.top, 1)
            if question.allowsText { otherField }
        }
    }

    @ViewBuilder private func optionRow(_ option: LeoChatOption) -> some View {
        let isSelected = draft.values(for: question.id).contains(option.value)
        if question.multi {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in choose(option.value) })) { optionLabel(option) }
                .toggleStyle(.checkbox)
        } else {
            Button { choose(option.value) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    optionLabel(option)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func optionLabel(_ option: LeoChatOption) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(option.label).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let description = option.description {
                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var otherField: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(
                "Other…",
                text: Binding(
                    get: { draft.text(for: question.id) },
                    set: { chat.setQuestionText(messageID: messageID, questionID: question.id, $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .controlSize(.small)
            .accessibilityIdentifier("chat.questions.\(question.id).text")
            if isTooLong {
                Text(verbatim: "Too long — \(LeoChatAnswer.maxTextScalars) characters max").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func choose(_ value: String) {
        chat.chooseQuestion(messageID: messageID, questionID: question.id, value: value)
    }
}
