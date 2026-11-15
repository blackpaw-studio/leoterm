import AppKit
import LeoKit
import SwiftUI

/// The composer: the reply target, attached files, a growing text field
/// (Return sends, Option-Return adds a line), attach, mic and send.
struct LeoChatComposer: View {
    @ObservedObject var chat: LeoChatPaneModel
    let agent: LeoAgentID
    let agentName: String
    /// Bumped when something asks for the text field's focus.
    let focusRequest: Int
    /// Consumes a pending focus request (true once per request).
    let takeFocusRequest: () -> Bool
    @FocusState private var isTextFocused: Bool

    /// The field's inset from the pane's edges.
    private static let edgeInset: CGFloat = 12
    private static let fieldCornerRadius: CGFloat = 18

    private var draft: LeoChatComposerDraft { chat.draft(for: agent) }
    private var isSending: Bool { chat.isSending(agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTo = draft.replyTo { replyBanner(replyTo) }
            if !draft.files.isEmpty { attachments }
            if case .recording(_, _, let startedAt) = chat.recording {
                recordingBar(since: startedAt)
            } else {
                inputRow
            }
        }
        .padding(.horizontal, Self.edgeInset)
        .padding(.vertical, Self.edgeInset)
        .background(LeoChatPasteMonitor(isActive: isTextFocused) { chat.attachPaste(to: agent) })
        .onAppear(perform: takeFocus)
        .onChange(of: focusRequest) { _ in takeFocus() }
    }

    private func takeFocus() {
        guard takeFocusRequest() else { return }
        // On the next pass: a field that appeared with the request isn't
        // in the window yet.
        DispatchQueue.main.async { isTextFocused = true }
    }

    /// A rounded field with attach, mic and send inside it, growing with the text.
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            fieldButton("paperclip", "Attach Files…", label: "Attach Files", action: pickFiles)
            TextField("Message \(agentName)", text: Binding(get: { draft.text }, set: { chat.setText($0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($isTextFocused)
                .onSubmit(send)
                .padding(.vertical, 2)
            fieldButton("mic", "Record a Voice Note", label: "Record a Voice Note") { Task { await chat.toggleRecording() } }
                .disabled(isSending || chat.recording == .requesting)
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(fieldShape.fill(.quaternary))
        .overlay(fieldShape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.fieldCornerRadius, style: .continuous)
    }

    private func fieldButton(_ symbol: String, _ help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).imageScale(.large).foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(label)
    }

    private var sendButton: some View {
        Button(action: send) {
            if isSending {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(chat.canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
        }
        .buttonStyle(.borderless)
        .disabled(!chat.canSend)
        .help("Send (Return)")
        .accessibilityLabel("Send")
    }

    private func recordingBar(since start: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle").foregroundStyle(.red)
            TimelineView(.periodic(from: start, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(start))
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.body.monospacedDigit())
            }
            Text("of 10:00").foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { chat.cancelRecording() }
                .keyboardShortcut(.cancelAction)
            Button { Task { await chat.toggleRecording() } } label: { Label("Send", systemImage: "stop.circle.fill") }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Stop and Send")
        }
    }

    private func replyBanner(_ id: String) -> some View {
        let target = chat.timeline.message(id: id)
        return HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
            Text(target?.task.map { "Replying to \($0)" } ?? "Replying").font(.callout.weight(.medium))
            if let target {
                Text(LeoChatPresentation.firstLine(target.displayText)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { chat.setReply(to: nil) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Don't Reply")
                .accessibilityLabel("Cancel Reply")
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(draft.files) { file in
                    HStack(spacing: 4) {
                        Image(systemName: file.isVoiceNote ? "waveform" : "doc")
                        Text(file.filename).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                        Button { chat.removeFile(file.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .disabled(isSending)
                            .accessibilityLabel("Remove \(file.filename)")
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
                }
            }
        }
    }

    private func send() {
        guard chat.canSend else { return }
        Task { await chat.send() }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        // The picked files belong to the agent the panel opened for.
        let target = agent
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            chat.attach(panel.urls, to: target)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}
