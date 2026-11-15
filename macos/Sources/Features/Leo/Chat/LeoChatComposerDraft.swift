import Foundation
import LeoKit

/// A file waiting in the composer: picked, dropped, or a recorded voice note.
struct LeoChatOutgoingFile: Equatable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let mime: String
    let isVoiceNote: Bool
}

/// What one send carries: a snapshot of the draft when Send was pressed.
struct LeoChatOutgoing: Equatable, Sendable {
    let text: String
    let files: [LeoChatOutgoingFile]
    let replyTo: String?
}

/// One agent's unsent message.
struct LeoChatComposerDraft: Equatable, Sendable {
    var text = ""
    var files: [LeoChatOutgoingFile] = []
    /// The message (usually a task card) the next send replies to.
    var replyTo: String?

    static let empty = LeoChatComposerDraft()

    /// What Send would send; nil when there is nothing.
    var outgoing: LeoChatOutgoing? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else { return nil }
        return LeoChatOutgoing(text: trimmed, files: files, replyTo: replyTo)
    }

    /// After a successful send: drops what was sent, keeping text edited and
    /// files attached while it was in flight.
    func finishing(_ sent: LeoChatOutgoing) -> LeoChatComposerDraft {
        let sentFiles = Set(sent.files.map(\.id))
        return LeoChatComposerDraft(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines) == sent.text ? "" : text,
            files: files.filter { !sentFiles.contains($0.id) },
            replyTo: replyTo == sent.replyTo ? nil : replyTo
        )
    }
}

enum LeoChatFileError: Error, Equatable, LocalizedError {
    case directory(String)
    case tooLarge(String, bytes: Int, limit: Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .directory(let name):
            "\(name) is a folder. Attach files instead."
        case .tooLarge(let name, let bytes, let limit):
            "\(name) is \(LeoChatPresentation.byteCount(bytes)), over the \(LeoChatPresentation.byteCount(limit)) upload limit."
        case .unreadable(let name):
            "\(name) couldn't be read."
        }
    }
}

/// A downloaded attachment's local copy.
enum LeoChatAttachmentFile: Equatable, Sendable {
    case loading
    case loaded(URL)
    case failed(String)
}

/// The mic button's state.
enum LeoChatRecording: Equatable, Sendable {
    case idle
    /// Waiting for the microphone permission.
    case requesting
    case recording(url: URL, agent: LeoAgentID, startedAt: Date)
}
