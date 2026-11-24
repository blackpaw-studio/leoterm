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
    @ObservedObject var control: LeoAgentControlModel
    let contentWidth: CGFloat
    @ViewBuilder let terminal: () -> Terminal
    /// The width under the pointer mid-drag; the session stores it on release.
    @State private var dragWidth: CGFloat?

    var body: some View {
        let row = LeoSidebarSelection.shownRow(model: model, terminals: terminals)
        let layout = session.chatLayout(for: row, contentWidth: contentWidth)
        let preferred = dragWidth ?? session.preferredChatWidth
        let sideBySideChatWidth = layout == .sideBySide ? layout.chatWidth(in: contentWidth, preferred: preferred) : 0
        ZStack(alignment: .topLeading) {
            terminal()
                .frame(maxHeight: .infinity)
                .frame(width: layout.terminalWidth(in: contentWidth, preferred: preferred))
                .frame(maxHeight: .infinity)
                .accessibilityHidden(!layout.isTerminalVisible)
                // Over the terminal's own column only (never the chat pane's
                // composer), and an overlay: no height change, no tmux reflow.
                .overlay(alignment: .bottom) {
                    if LeoControlFeedbackPlacement(layout: layout) == .overTerminal, let row {
                        LeoControlFeedbackBanner(row: row, control: control)
                    }
                }
            if layout.showsChat, let row {
                HStack(spacing: 0) {
                    if layout == .sideBySide { divider(layout, preferred: preferred) }
                    LeoChatPane(
                        row: row, chat: chat, session: session, viewer: session.chatViewer,
                        feedbackControl: LeoControlFeedbackPlacement(layout: layout) == .aboveComposer ? control : nil,
                        close: { session.choose(.terminal, for: row.id) },
                        start: { model.startRequested(row) { _ in } }
                    )
                    // The detail column starts at the toolbar's bottom edge (the real
                    // safe area, as for the terminal), but a `ScrollView` draws
                    // outside its frame at the top: the thread scrolled up under
                    // the toolbar. Clip the pane, not the HStack: the divider's
                    // resize handle reaches 3 pt left of the pane.
                    .clipped()
                }
                .frame(width: layout.chatWidth(in: contentWidth, preferred: preferred))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .onAppear {
            session.setObservedContentWidth(contentWidth)
            session.setSideBySideChatWidth(sideBySideChatWidth)
        }
        .onChange(of: sideBySideChatWidth) { session.setSideBySideChatWidth($0) }
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
        guard !layout.isTerminalVisible, session.isTerminalFocused() else { return }
        session.requestChatFocus()
    }
}

/// One agent's Leo Chat thread and composer.
struct LeoChatPane: View {
    let row: LeoAgentRow
    @ObservedObject var chat: LeoChatPaneModel
    @ObservedObject var session: LeoWindowSession
    @ObservedObject var viewer: LeoChatViewerModel
    /// Set when Chat replaces the terminal: control feedback then shows here,
    /// above the composer.
    var feedbackControl: LeoAgentControlModel?
    let close: () -> Void
    /// Starts the agent when it isn't running (B-369: its history is
    /// readable meanwhile; starting is this one explicit action).
    let start: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        let document = viewer.document(for: row.id)
        VStack(spacing: 0) {
            // The thread's own header moved to the toolbar (name, task
            // filter) and the switcher (Close Chat); the file viewer keeps its.
            if let document {
                viewerHeader(document)
                Divider()
            }
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
            if let feedbackControl { LeoControlFeedbackBanner(row: row, control: feedbackControl) }
            if document == nil {
                if let prompt = LeoChatStartBar.prompt(for: row.status, movedTo: row.movedTo) {
                    Divider()
                    startBar(prompt)
                }
                Divider()
                LeoChatComposer(
                    chat: chat, agent: row.id, agentName: row.displayName, agentStatus: row.status, movedTo: row.movedTo,
                    focusRequest: session.chatFocusRequest, takeFocusRequest: session.takeChatFocusRequest
                )
            }
        }
        .environment(\.openChatAttachment) { attachment, fullWindow, gallery in
            let agent = row.id
            Task {
                await viewer.open(
                    attachment, for: agent, fullWindow: fullWindow, gallery: gallery,
                    download: { await chat.downloadedFile(attachment) },
                    downloadGalleryItem: { await chat.downloadedFile($0) }
                )
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

    private func startBar(_ prompt: LeoChatStartBar) -> some View {
        HStack(spacing: 8) {
            Text("\(row.displayName) \(prompt.message)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if prompt.offersStart { Button("Start", action: start).controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
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

/// B-371: whether the composer may send to an agent. The daemon starts a
/// stopped agent when it gets a message, so the Mac refuses up front
/// instead: nothing starts by itself (B-369) and typed text is never
/// dropped silently. Returns the refusal to show, or nil to send.
/// B-442: an agent moved to another host can't be started here (the daemon
/// refuses), so whatever its status, the refusal names the host it went to.
enum LeoChatSendGate {
    static func refusal(for status: LeoAgentStatus, agentName: String, movedTo: String? = nil) -> String? {
        if let movedTo { return "\(agentName) moved to \(movedTo), so this wasn\u{2019}t sent." }
        return switch status {
        case .running, .starting: nil
        case .stopped, .unknown:
            "\(agentName) isn\u{2019}t running, so this wasn\u{2019}t sent. Start it, then send again."
        case .restoring:
            "\(agentName) is still starting, so this wasn\u{2019}t sent. Send again once it\u{2019}s running."
        }
    }

    /// The composer field's placeholder: "Start" only where Start is on offer.
    static func placeholder(for status: LeoAgentStatus, agentName: String, movedTo: String?) -> String {
        if let movedTo { return "\(agentName) moved to \(movedTo)" }
        return refusal(for: status, agentName: agentName) == nil ? "Message \(agentName)" : "Start \(agentName) to send a message"
    }

    /// The send button's tooltip.
    static func sendHelp(for status: LeoAgentStatus, agentName: String, movedTo: String?) -> String {
        if let movedTo { return "\(agentName) moved to \(movedTo)" }
        return refusal(for: status, agentName: agentName) == nil ? "Send (Return)" : "Start \(agentName) to send"
    }
}

/// B-369: what the chat shows above its composer for an agent that isn't
/// running. Reading history never waits on this; Start is one explicit,
/// non-blocking action, and nothing starts by itself.
struct LeoChatStartBar: Equatable {
    let message: String
    let offersStart: Bool

    /// B-324: an agent moved to another host can't run here, so the bar says
    /// where it went and offers no Start, whatever its status.
    static func prompt(for status: LeoAgentStatus, movedTo: String? = nil) -> LeoChatStartBar? {
        if let movedTo { return LeoChatStartBar(message: "moved to \(movedTo).", offersStart: false) }
        return switch status {
        case .running: nil
        case .starting, .restoring: LeoChatStartBar(message: "is starting\u{2026}", offersStart: false)
        case .stopped, .unknown: LeoChatStartBar(message: "isn\u{2019}t running.", offersStart: true)
        }
    }
}
