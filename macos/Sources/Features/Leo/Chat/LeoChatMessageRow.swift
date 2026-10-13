import AppKit
import LeoKit
import SwiftUI

/// One message: a bubble (yours on the right, the agent's on the left), a
/// task card, or a centred system note; with its attachments, ask
/// controls and delivery state.
struct LeoChatMessageRow: View {
    let message: LeoChatMessage
    @ObservedObject var chat: LeoChatPaneModel

    private var isMine: Bool { message.direction == .inbound }
    private var isExpanded: Bool { chat.expanded.contains(message.id) }

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.displayText).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        case .task:
            LeoChatTaskCard(message: message, chat: chat)
        default:
            bubbleRow
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .bottom) {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                bubble
                footer
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.kind == .voice {
                LeoChatVoiceNote(message: message, chat: chat)
            } else if !message.displayText.isEmpty {
                LeoChatExpandableText(text: message.displayText, id: message.id, chat: chat)
            }
            ForEach(message.attachments.filter { message.kind != .voice || !$0.isAudio }) { attachment in
                LeoChatAttachmentView(attachment: attachment, chat: chat)
            }
            if message.answerInput != nil { LeoChatAskControls(message: message, chat: chat) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isMine ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(isMine ? 0 : 0.6))
        )
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if message.isFailed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text("Not delivered")
            } else if message.isPending {
                Text("Sending…")
            }
            Text(message.ts, format: .dateTime.hour().minute())
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// Long text collapsed behind "Show more"; Markdown inline styles kept.
struct LeoChatExpandableText: View {
    let text: String
    let id: String
    @ObservedObject var chat: LeoChatPaneModel

    var body: some View {
        let isLong = LeoChatPresentation.isLong(text)
        let isExpanded = chat.expanded.contains(id)
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.attributed(text))
                .lineLimit(isLong && !isExpanded ? LeoChatPresentation.collapsedLines : nil)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isLong {
                Button(isExpanded ? "Show less" : "Show more") { chat.toggleExpanded(id) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A scheduled task's output: labelled with the task and time, collapsed
/// to one line until clicked; a reply carries the run's context.
struct LeoChatTaskCard: View {
    let message: LeoChatMessage
    @ObservedObject var chat: LeoChatPaneModel

    var body: some View {
        let isExpanded = chat.expanded.contains(message.id)
        VStack(alignment: .leading, spacing: 6) {
            Button { chat.toggleExpanded(message.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                    Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary)
                    Text(message.task ?? "Task").font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(message.ts, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                if !message.displayText.isEmpty {
                    Text(LeoChatExpandableText.attributed(message.displayText))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(message.attachments) { LeoChatAttachmentView(attachment: $0, chat: chat) }
                Button { chat.setReply(to: message.id) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    .buttonStyle(.link)
                    .font(.callout)
            } else {
                Text(LeoChatPresentation.firstLine(message.displayText)).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}

/// An open `ask` or permission prompt's input, by type: buttons that
/// answer at once, a radio group or checkboxes then Submit, a text field
/// (also under the choices with `allow_text`); the recorded answer once
/// closed.
struct LeoChatAskControls: View {
    let message: LeoChatMessage
    @ObservedObject var chat: LeoChatPaneModel

    var body: some View {
        if message.isOpen, let input = message.answerInput {
            LeoChatOpenAsk(message: message, input: input, chat: chat)
        } else if message.isAnsweredInTerminal {
            Label("Answered in terminal", systemImage: "terminal").font(.callout).foregroundStyle(.secondary)
        } else if let summary = message.answerSummary {
            Label("Answered: \(summary)", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if message.state == "expired" {
            Label("Expired", systemImage: "clock.badge.xmark").font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct LeoChatOpenAsk: View {
    let message: LeoChatMessage
    let input: LeoChatInput
    @ObservedObject var chat: LeoChatPaneModel
    @FocusState private var isTextFocused: Bool

    private var draft: LeoChatAskDraft { chat.askDraft(for: message.id) }
    private var isAnswering: Bool { chat.answering.contains(message.id) }
    private var takesText: Bool { input.kind == .text || input.allowsText }
    /// Buttons answer on click; Submit is only for their free text.
    private var needsSubmit: Bool { input.kind != .buttons || input.allowsText }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            choices
            if let hint = Self.selectionHint(input) { Text(hint).font(.caption).foregroundStyle(.secondary) }
            if takesText { textField }
            if needsSubmit { submitRow }
        }
        .disabled(isAnswering)
    }

    @ViewBuilder private var choices: some View {
        switch input.kind {
        case .buttons:
            LeoChatFlowLayout(spacing: 6) {
                ForEach(input.options, id: \.value) { option in
                    Button(option.label) { choose(option.value) }
                        .buttonStyle(.bordered)
                        .tint(message.kind == .permission && option.value == "deny" ? .red : nil)
                        .accessibilityIdentifier("chat.ask.option.\(option.value)")
                }
                if isAnswering && !needsSubmit { ProgressView().controlSize(.small) }
            }
        case .radio:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(input.options, id: \.value) { option in
                    let isSelected = draft.selected.contains(option.value)
                    Button { choose(option.value) } label: {
                        Label {
                            Text(option.label).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("chat.ask.option.\(option.value)")
                }
            }
        case .checkboxes:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(input.options, id: \.value) { option in
                    Toggle(isOn: Binding(get: { draft.selected.contains(option.value) }, set: { _ in choose(option.value) })) {
                        Text(option.label).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("chat.ask.option.\(option.value)")
                }
            }
        case .text:
            EmptyView()
        }
    }

    private var textField: some View {
        let placeholder = input.placeholder ?? (input.kind == .text ? "Type an answer" : "Or type an answer")
        return TextField(placeholder, text: Binding(get: { draft.text }, set: { chat.setAskText(messageID: message.id, $0) }), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...6)
            .focused($isTextFocused)
            .accessibilityIdentifier("chat.ask.text")
    }

    private var submitRow: some View {
        HStack(spacing: 8) {
            Button("Submit") { Task { await chat.submitAsk(messageID: message.id) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                // ⌘↩ submits from this ask's own field, never from the composer.
                .keyboardShortcut(isTextFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .disabled(chat.askAnswer(for: message.id) == nil)
                .help("Submit (⌘↩)")
                .accessibilityIdentifier("chat.ask.submit")
            if isAnswering { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if takesText, !draft.text.isEmpty { counter }
        }
    }

    private var counter: some View {
        let remaining = draft.remainingTextScalars
        return Text("\(LeoChatAnswer.maxTextScalars - remaining)/\(LeoChatAnswer.maxTextScalars)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(remaining < 0 ? Color.red : Color.secondary)
    }

    private func choose(_ value: String) {
        Task { await chat.choose(messageID: message.id, value: value) }
    }

    /// "Choose 2", "Choose up to 3", "Choose 1–2": only when checkboxes
    /// limit the count.
    static func selectionHint(_ input: LeoChatInput) -> String? {
        guard input.kind == .checkboxes, input.min > 0 || input.max < input.options.count else { return nil }
        if input.min == input.max { return "Choose \(input.min)" }
        if input.min == 0 { return "Choose up to \(input.max)" }
        return "Choose \(input.min)–\(input.max)"
    }
}

/// Wraps buttons onto as many lines as they need.
struct LeoChatFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var y: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
