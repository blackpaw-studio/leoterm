import Foundation
import UniformTypeIdentifiers

/// How the editor pane shows a file (B-278), by extension. An allowlist
/// rather than UTType conformance: `.ts` (TypeScript, not MPEG-TS) and
/// `.key` (a private key, not Keynote) stay text.
enum LeoFilePreviewKind: Equatable, Sendable {
    /// Text kept editable that also has a rendered presentation.
    enum Rendered: Equatable, Sendable {
        case markdown
        case svg
    }

    case text
    case rendered(Rendered)
    case image
    case movie
    /// PDFs and Office/iWork documents, through Quick Look.
    case quickLook

    private static let byExtension: [String: LeoFilePreviewKind] = {
        var table: [String: LeoFilePreviewKind] = ["md": .rendered(.markdown), "markdown": .rendered(.markdown), "svg": .rendered(.svg)]
        for ext in ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"] { table[ext] = .image }
        for ext in ["mp4", "mov", "m4v"] { table[ext] = .movie }
        for ext in ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "rtf"] { table[ext] = .quickLook }
        return table
    }()

    init(path: String) {
        self = Self.byExtension[Self.pathExtension(of: path)] ?? .text
    }

    /// Streamed into the preview cache instead of read as text.
    var isFetched: Bool {
        switch self {
        case .image, .movie, .quickLook: true
        case .text, .rendered: false
        }
    }

    /// What "Can’t Preview …" names: the system's description of the type,
    /// or "This File" when there's none.
    static func typeName(forPath path: String) -> String {
        let ext = pathExtension(of: path)
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic,
              let description = type.localizedDescription, !description.isEmpty else { return "This File" }
        return description
    }

    /// Lowercased; empty for a dotfile (".png" has no extension).
    private static func pathExtension(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") || name.dropFirst().contains(".") else { return "" }
        return (name as NSString).pathExtension.lowercased()
    }
}
