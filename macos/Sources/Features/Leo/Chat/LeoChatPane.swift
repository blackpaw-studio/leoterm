import AppKit
import LeoKit
import SwiftUI
import UniformTypeIdentifiers

/// Observes what decides whether the chat pane shows and which agent it
/// follows, then hosts it beside the terminal column. Nothing here when the
/// window hasn't opened chat, or no agent row is selected.
struct LeoChatPaneHost: View {
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var chat: LeoChatPaneModel
    @ObservedObject var terminals: LeoWindowTerminals
    @ObservedObject var session: LeoWindowSession

    var body: some View {
        let row = terminals.selection == nil ? model.actionableSelection : nil
        if session.isChatVisible, let row {
            HStack(spacing: 0) {
                Divider()
                LeoChatPane(row: row, chat: chat, close: { session.setChatVisible(false) })
                    .frame(width: LeoChatPane.width)
            }
        }
    }
}

/// One agent's Leo Chat thread and composer.
struct LeoChatPane: View {
    static let width: CGFloat = 380

    let row: LeoAgentRow
    @ObservedObject var chat: LeoChatPaneModel
    let close: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = chat.notice { noticeBanner(notice) }
            LeoChatThreadView(chat: chat)
            Divider()
            LeoChatComposer(chat: chat, agent: row.id, agentName: row.name)
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
