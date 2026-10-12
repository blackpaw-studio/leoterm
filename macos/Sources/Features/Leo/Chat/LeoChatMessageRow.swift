import AppKit
import LeoKit
import SwiftUI

/// One message: a bubble (yours on the right, the agent's on the left), a
/// task card, or a centred system note; with its attachments, prompt
/// buttons and delivery state.
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
            if message.answerInput != nil { LeoChatPromptButtons(message: message, chat: chat) }
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

/// An `ask`'s options or a permission's Allow/Deny while open; the
/// recorded answer once closed.
struct LeoChatPromptButtons: View {
    let message: LeoChatMessage
    @ObservedObject var chat: LeoChatPaneModel

    var body: some View {
        if message.isOpen {
            let isAnswering = chat.answering.contains(message.id)
            LeoChatFlowLayout(spacing: 6) {
                ForEach(message.answerInput?.options ?? [], id: \.value) { choice in
                    Button(choice.label) { Task { await chat.answer(messageID: message.id, value: choice.value) } }
                        .buttonStyle(.bordered)
                        .tint(choice.value == "deny" ? .red : nil)
                        .disabled(isAnswering)
                }
                if isAnswering { ProgressView().controlSize(.small) }
            }
        } else if let summary = message.answerSummary {
            Label("Answered: \(summary)", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
        } else if message.state == "expired" {
            Label("Expired", systemImage: "clock.badge.xmark").font(.callout).foregroundStyle(.secondary)
        }
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
