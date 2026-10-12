import AppKit
import LeoKit
import SwiftUI

/// The composer: the reply target, attached files, a growing text field
/// (Return sends, Option-Return adds a line), attach, mic and send.
struct LeoChatComposer: View {
    @ObservedObject var chat: LeoChatPaneModel
    let agent: LeoAgentID
    let agentName: String

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
        .padding(10)
        .background(.bar)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button(action: pickFiles) { Image(systemName: "paperclip").imageScale(.large) }
                .buttonStyle(.borderless)
                .help("Attach Files…")
                .accessibilityLabel("Attach Files")
            TextField("Message \(agentName)", text: Binding(get: { draft.text }, set: { chat.setText($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit(send)
            Button { Task { await chat.toggleRecording() } } label: { Image(systemName: "mic").imageScale(.large) }
                .buttonStyle(.borderless)
                .disabled(isSending || chat.recording == .requesting)
                .help("Record a Voice Note")
                .accessibilityLabel("Record a Voice Note")
            Button(action: send) {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large)
                }
            }
            .buttonStyle(.borderless)
            .disabled(!chat.canSend)
            .help("Send (Return)")
            .accessibilityLabel("Send")
        }
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
