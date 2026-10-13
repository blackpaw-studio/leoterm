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
    /// The width under the pointer mid-drag; the session stores it on release.
    @State private var dragWidth: CGFloat?

    var body: some View {
        let row = terminals.selection == nil ? model.actionableSelection : nil
        let layout = session.chatLayout(for: row, contentWidth: contentWidth)
        let preferred = dragWidth ?? session.preferredChatWidth
        ZStack(alignment: .topLeading) {
            terminal()
                .frame(width: layout.terminalWidth(in: contentWidth, preferred: preferred))
                .frame(maxHeight: .infinity)
                .accessibilityHidden(!layout.isTerminalVisible)
            if layout.showsChat, let row {
                HStack(spacing: 0) {
                    if layout == .sideBySide { divider(layout, preferred: preferred) }
                    LeoChatPane(
                        row: row, chat: chat, session: session, viewer: session.chatViewer,
                        close: { session.choose(.terminal, for: row.id) }
                    )
                }
                .frame(width: layout.chatWidth(in: contentWidth, preferred: preferred))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .onAppear { session.setObservedContentWidth(contentWidth) }
        .onChange(of: contentWidth) { session.setObservedContentWidth($0) }
        .onChange(of: layout) { _ in handBackHiddenTerminalFocus(layout) }
        .onChange(of: row?.id) {
            session.chatViewer.agentChanged(to: $0)
            handBackHiddenTerminalFocus(layout)
        }
    }

    /// The thin line between terminal and chat, with a wider grab area over it.
    private func divider(_ layout: LeoChatLayout, preferred: CGFloat?) -> some View {
        let displayed = { layout.chatWidth(in: contentWidth, preferred: preferred) }
        return Divider().overlay {
            LeoChatResizeHandle(
                currentWidth: displayed,
                onDrag: { dragWidth = $0 },
                onDragEnd: {
                    // Store what the layout shows, so a drag past the limit keeps the limit.
                    if let dragWidth { session.setPreferredChatWidth(layout.chatWidth(in: contentWidth, preferred: dragWidth)) }
                    dragWidth = nil
                },
                onReset: {
                    dragWidth = nil
                    session.resetPreferredChatWidth()
                }
            )
            .frame(width: LeoChatResizeHandle.hitWidth)
        }
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
    @ObservedObject var viewer: LeoChatViewerModel
    let close: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        let document = viewer.document(for: row.id)
        VStack(spacing: 0) {
            if let document { viewerHeader(document) } else { header }
            Divider()
            if let notice = chat.notice { noticeBanner(notice) }
            // The thread stays mounted under the viewer, so Back finds it
            // at the same scroll position.
            ZStack {
                LeoChatThreadView(chat: chat)
                    .opacity(document == nil ? 1 : 0)
                    .disabled(document != nil)
                    .accessibilityHidden(document != nil)
                // One viewer view per window: while the file is full window the
                // overlay holds it, so there is a single Escape monitor.
                if let document, !viewer.isFullWindow { fileViewer(document) }
            }
            if document == nil {
                Divider()
                LeoChatComposer(
                    chat: chat, agent: row.id, agentName: row.name,
                    focusRequest: session.chatFocusRequest, takeFocusRequest: session.takeChatFocusRequest
                )
            }
        }
        .environment(\.openChatAttachment) { attachment, fullWindow in
            let agent = row.id
            Task {
                await viewer.open(attachment, for: agent, fullWindow: fullWindow, download: { await chat.downloadedFile(attachment) })
            }
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
            LeoChatViewerIconButton(systemImage: "xmark", title: "Close Chat", action: close)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
    }

    private func viewerHeader(_ document: LeoChatViewerDocument) -> some View {
        HStack(spacing: 8) {
            LeoChatViewerIconButton(systemImage: "chevron.backward", title: "Back to Chat", action: session.closeChatViewer)
            Text(document.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            LeoChatViewerIconButton(
                systemImage: "arrow.up.left.and.arrow.down.right", title: "Open Full Window", action: viewer.enterFullWindow
            )
            LeoChatViewerIconButton(
                systemImage: "arrow.up.forward.app", title: "Open in Default App", action: { NSWorkspace.shared.open(document.url) }
            )
            LeoChatViewerIconButton(systemImage: "xmark", title: "Close Chat", action: close)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
    }

    private func fileViewer(_ document: LeoChatViewerDocument) -> some View {
        LeoChatFileViewerRepresentable(document: document, onBack: session.closeChatViewer, openExternally: { NSWorkspace.shared.open($0) })
            .id(document.attachmentID)
            .background(Color(nsColor: .textBackgroundColor))
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
            LeoChatViewerIconButton(systemImage: "xmark", title: "Dismiss", action: chat.dismissNotice)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        // Files dropped under the viewer would join a draft nobody can see.
        guard viewer.document(for: row.id) == nil, !viewer.isFullWindow else { return false }
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
