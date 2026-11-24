import LeoKit
import SwiftUI

/// The selected item: a chat ask answered inline (context bubble and the
/// chat's own ask/questions controls, with this inbox's drafts); a terminal
/// permission prompt or question as text with Go to Agent; a finished
/// item's result.
struct LeoInboxDetail: View {
    @ObservedObject var model: LeoInboxModel
    let item: LeoInboxItem
    let actions: LeoInboxActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
                if item.moreCount > 0 {
                    Text("\(item.moreCount) more waiting from this agent")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let notice = model.notice {
                    HStack(spacing: 6) {
                        Text(notice).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        Button("Dismiss") { model.dismissNotice() }.buttonStyle(.link)
                    }
                }
                hints
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            LeoInboxSymbol(item: item)
                .font(.system(size: 18))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.agent).font(.title2.weight(.bold)).lineLimit(1)
                HStack(spacing: 5) {
                    LeoInboxMeta(item: item)
                    if let when = whenLine { Text("·"); Text(when) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if isChatAsk {
                    Button { actions.openChat(item.id) } label: { Label("Open Chat", systemImage: "bubble.left") }
                        .accessibilityIdentifier("inbox.openChat")
                }
                goToAgentButton
            }
        }
    }

    @ViewBuilder private var goToAgentButton: some View {
        let button = Button { actions.goToAgent(item.id) } label: { Label("Go to Agent", systemImage: "arrow.up.forward.square") }
        if isChatAsk {
            button.accessibilityIdentifier("inbox.goToAgent")
        } else {
            button.buttonStyle(.borderedProminent).accessibilityIdentifier("inbox.goToAgent")
        }
    }

    private var isChatAsk: Bool {
        if case .chatAsk = item.kind { true } else { false }
    }

    private var tint: Color {
        switch item.kind {
        case .finished: item.isError ? .red : .green
        default: .orange
        }
    }

    private var whenLine: String? {
        guard let age = LeoInboxPresentation.age(of: item.at, now: Date()) else { return nil }
        let ago = age == "now" ? "just now" : "\(age) ago"
        switch item.kind {
        case .chatAsk: return "asked \(ago)"
        case .permission, .question: return "waiting since \(ago)"
        case .finished: return item.isError ? "failed \(ago)" : "finished \(ago)"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .chatAsk(let message): chatAsk(message)
        case .permission(let tool, let detail): permission(tool: tool, detail: detail)
        case .question(let text): question(text)
        case .finished(let result): finished(result)
        }
    }

    @ViewBuilder private func chatAsk(_ message: LeoChatMessage) -> some View {
        if let context = item.context {
            Text(context)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: 560, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.1)))
        }
        panel(accent: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                if message.input?.kind == .questions {
                    LeoChatQuestionsCard(message: message, chat: model)
                } else {
                    Text(message.displayText).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    LeoChatAskControls(message: message, chat: model)
                }
            }
        }
    }

    private func permission(tool: String?, detail: String?) -> some View {
        panel(accent: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Permission").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.orange.opacity(0.14)))
                    if let tool, !tool.isEmpty {
                        (Text("The agent wants to use ") + Text(tool).bold()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let detail, !detail.isEmpty { codeBlock(detail) }
                terminalNote("Answer in the agent's terminal. Leo shows the prompt but never answers it for you.")
            }
        }
    }

    private func question(_ text: String?) -> some View {
        panel(accent: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text ?? "The agent is waiting for your input.").font(.system(size: 14)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                terminalNote("Answer in the agent's terminal.")
            }
        }
    }

    private func finished(_ result: String?) -> some View {
        panel(accent: item.isError ? .red : .green) {
            Text(LeoInboxPresentation.headline(item))
                .font(.system(size: 14))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func panel<Content: View>(accent: Color, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
            .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.12)))
    }

    private func terminalNote(_ text: String) -> some View {
        Label(text, systemImage: "terminal")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("↑↓", "move")
            if isChatAsk { hint("↩", "submit") }
            hint("⌘↩", "go to agent")
            if !item.isBlocked { hint("⌫", "clear") }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 8)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
            Text(label)
        }
    }
}
