import AppKit
import LeoKit
import SwiftUI
import UniformTypeIdentifiers

/// Lays out the terminal column and the selected agent's chat by the
/// Terminal | Chat switch and the content area's width (`LeoChatLayout`).
/// The terminal is never removed: replaced, it keeps its full width under
/// the chat, so the same surface comes back with tmux unchanged. The chat
/// pane keeps one identity across replace and side-by-side, so resizing
/// across the threshold keeps its scroll position and the draft.
struct LeoChatLayoutHost<Terminal: View>: View {
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var chat: LeoChatPaneModel
    @ObservedObject var terminals: LeoWindowTerminals
    @ObservedObject var session: LeoWindowSession
    let contentWidth: CGFloat
    @ViewBuilder let terminal: () -> Terminal

    var body: some View {
        let row = terminals.selection == nil ? model.actionableSelection : nil
        let layout = session.chatLayout(for: row, contentWidth: contentWidth)
        ZStack(alignment: .topLeading) {
            terminal()
                .frame(width: layout.terminalWidth(in: contentWidth))
                .frame(maxHeight: .infinity)
                .accessibilityHidden(!layout.isTerminalVisible)
            if layout.showsChat, let row {
                HStack(spacing: 0) {
                    if layout == .sideBySide { Divider() }
                    LeoChatPane(row: row, chat: chat, session: session, close: { session.choose(.terminal, for: row.id) })
                }
                .frame(width: layout.chatWidth(in: contentWidth))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .onAppear { session.setObservedContentWidth(contentWidth) }
        .onChange(of: contentWidth) { session.setObservedContentWidth($0) }
        .onChange(of: layout) { _ in handBackHiddenTerminalFocus(layout) }
        .onChange(of: row?.id) { _ in handBackHiddenTerminalFocus(layout) }
    }

    /// A terminal hidden behind the chat must not keep the keyboard: a
    /// keystroke would land in an agent nobody can see.
    private func handBackHiddenTerminalFocus(_ layout: LeoChatLayout) {
        guard !layout.isTerminalVisible, session.window?.firstResponder is Ghostty.SurfaceView else { return }
        session.requestChatFocus()
    }
}

/// One agent's Leo Chat thread and composer.
struct LeoChatPane: View {
    let row: LeoAgentRow
    @ObservedObject var chat: LeoChatPaneModel
    @ObservedObject var session: LeoWindowSession
    let close: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = chat.notice { noticeBanner(notice) }
            LeoChatThreadView(chat: chat)
            Divider()
            LeoChatComposer(
                chat: chat, agent: row.id, agentName: row.name,
                focusRequest: session.chatFocusRequest, takeFocusRequest: session.takeChatFocusRequest
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: drop)
        .task(id: row.id) { await chat.show(row.id) }
        .onAppear { Task { await chat.setOnScreen(true) } }
        .onDisappear { Task { await chat.setOnScreen(false) } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
            Text(row.name).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            taskFilterMenu
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close Chat")
                .accessibilityLabel("Close Chat")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
    }

    @ViewBuilder private var taskFilterMenu: some View {
        let tasks = chat.timeline.knownTasks.sorted()
        if !tasks.isEmpty || chat.timeline.taskFilter != nil {
            Menu {
                Button("All Messages") { Task { await chat.setTaskFilter(nil) } }
                Divider()
                ForEach(tasks, id: \.self) { task in
                    Button(task) { Task { await chat.setTaskFilter(task) } }
                }
            } label: {
                Label(chat.timeline.taskFilter ?? "All Messages", systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Show one task's cards")
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { chat.dismissNotice() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        // The drop belongs to the agent shown now, even if the selection
        // moves before the URLs arrive.
        let agent = row.id
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in chat.attach([url], to: agent) }
            }
        }
        return true
    }
}

extension LeoChatPaneModel {
    /// Attaches from the UI: a refusal is shown as the pane's notice.
    func attach(_ urls: [URL], to agent: LeoAgentID) {
        do {
            try addFiles(urls, to: agent)
        } catch {
            showNotice(error.localizedDescription)
        }
    }
}
