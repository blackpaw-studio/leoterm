import Foundation
import LeoKit
import UniformTypeIdentifiers

/// Picks the preview kind for a chat attachment: the filename extension as
/// the editor does, then the attachment's MIME type. Nil when neither knows it.
enum LeoChatViewerKind {
    private static let explicitMime: [String: LeoFilePreviewKind] = [
        "text/markdown": .rendered(.markdown),
        "text/x-markdown": .rendered(.markdown),
        "image/svg+xml": .rendered(.svg),
    ]

    static func known(filename: String, mime: String) -> LeoFilePreviewKind? {
        if let byExtension = LeoFilePreviewKind.known(path: filename) { return byExtension }
        let essence = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !essence.isEmpty else { return nil }
        if let explicit = explicitMime[essence] { return explicit }
        guard let ext = UTType(mimeType: essence)?.preferredFilenameExtension else { return nil }
        return LeoFilePreviewKind.known(path: "x." + ext)
    }
}

/// A downloaded attachment resolved for the in-app viewer.
struct LeoChatViewerDocument: Equatable {
    enum Body: Equatable {
        /// Fetched kinds (image, movie, Quick Look): shown straight from the file.
        case file(LeoFilePreviewKind)
        case text(String, LeoFilePreviewKind)
    }

    let attachmentID: String
    let filename: String
    let url: URL
    let body: Body

    var content: LeoEditorPaneContent {
        switch body {
        case .file(let kind):
            LeoEditorPresentation().content(kind: kind, preview: .ready(url), textLength: 0)
        case let .text(text, kind):
            LeoEditorPresentation().content(kind: kind, preview: nil, textLength: text.utf16.count)
        }
    }

    /// Nil when the viewer can't show the file: it is binary, not UTF-8,
    /// too large, or unreadable, so the click opens the default app instead.
    static func load(
        attachment: LeoChatAttachment,
        url: URL,
        access: any LeoFileAccess = LeoFileAccessor.local(),
        policy: LeoEditorContentPolicy = .default
    ) async -> LeoChatViewerDocument? {
        let known = LeoChatViewerKind.known(filename: attachment.filename, mime: attachment.mime)
        func document(_ body: Body) -> LeoChatViewerDocument {
            LeoChatViewerDocument(attachmentID: attachment.id, filename: attachment.filename, url: url, body: body)
        }
        if let known, known.isFetched { return document(.file(known)) }
        guard let contents = try? await access.read(url.path, maxBytes: policy.readLimit) else { return nil }
        let evaluated = policy.evaluate(contents.data)
        switch evaluated.readOnlyReason {
        case .binary?, .notUTF8?: return nil
        case .tooLarge?, nil: return document(.text(evaluated.text, known ?? .text))
        }
    }
}
