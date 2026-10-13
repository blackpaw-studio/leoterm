import Foundation
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
