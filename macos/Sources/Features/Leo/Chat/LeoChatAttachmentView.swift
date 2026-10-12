import AppKit
import AVFoundation
import LeoKit
import SwiftUI

/// An attachment: images inline, anything else a row that opens the file
/// in its default app once downloaded.
struct LeoChatAttachmentView: View {
    let attachment: LeoChatAttachment
    @ObservedObject var chat: LeoChatPaneModel

    var body: some View {
        if !attachment.available {
            fileRow(subtitle: "No longer available", isEnabled: false)
        } else if attachment.isImage {
            image
        } else {
            fileRow(subtitle: subtitle, isEnabled: true)
        }
    }

    private var state: LeoChatAttachmentFile? { chat.attachmentFiles[attachment.id] }

    @ViewBuilder private var image: some View {
        switch state {
        case .loaded(let url):
            LeoChatImage(url: url)
                .onTapGesture { NSWorkspace.shared.open(url) }
                .help(attachment.filename)
        case .failed:
            fileRow(subtitle: subtitle, isEnabled: true)
        case .loading, nil:
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 200, height: 120)
                .overlay { ProgressView().controlSize(.small) }
                .task { await chat.loadAttachment(attachment) }
        }
    }

    private var subtitle: String {
        switch state {
        case .failed(let reason): reason
        case .loading: "Downloading…"
        case .loaded, nil: LeoChatPresentation.byteCount(attachment.bytes)
        }
    }

    private func fileRow(subtitle: String, isEnabled: Bool) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(for: .init(mimeType: attachment.mime) ?? .data))
                    .resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? "Open \(attachment.filename)" : "")
    }

    private func open() {
        Task {
            await chat.loadAttachment(attachment)
            if case .loaded(let url) = chat.attachmentFiles[attachment.id] { NSWorkspace.shared.open(url) }
        }
    }
}

/// A downloaded image, decoded off the main thread.
struct LeoChatImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 200, height: 120)
            }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

/// A voice note: a player for its audio and the transcript under it.
struct LeoChatVoiceNote: View {
    let message: LeoChatMessage
    @ObservedObject var chat: LeoChatPaneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let audio = message.attachments.first(where: \.isAudio) {
                LeoChatAudioPlayer(attachment: audio, chat: chat)
            }
            if let transcript = message.transcript {
                LeoChatExpandableText(text: transcript, id: message.id, chat: chat)
            } else {
                Text(message.isPending ? "Transcribing…" : "No transcript").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Play/pause and progress for one audio attachment.
struct LeoChatAudioPlayer: View {
    let attachment: LeoChatAttachment
    @ObservedObject var chat: LeoChatPaneModel
    @StateObject private var player = LeoChatAudioPlayback()

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(!attachment.available || chat.attachmentFiles[attachment.id] == .loading)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                ProgressView(value: player.progress).frame(width: 140)
            }
            Text(player.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func toggle() {
        Task {
            await chat.loadAttachment(attachment)
            guard case .loaded(let url) = chat.attachmentFiles[attachment.id] else { return }
            player.toggle(url: url)
        }
    }
}

@MainActor final class LeoChatAudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    var progress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    var durationText: String {
        guard let player else { return "" }
        return Duration.seconds(player.duration).formatted(.time(pattern: .minuteSecond))
    }

    func toggle(url: URL) {
        if let player, player.isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if player?.url != url { player = try? AVAudioPlayer(contentsOf: url) }
        player?.delegate = self
        isPlaying = player?.play() ?? false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
