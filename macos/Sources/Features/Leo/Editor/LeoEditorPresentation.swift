import Foundation

/// The view a tab's content row shows (B-278).
enum LeoEditorPaneContent: Equatable {
    /// The editable (or read-only) text view.
    case text
    case markdown
    /// The SVG's source, drawn as an image.
    case svg
    case loading(fraction: Double?)
    case image(URL)
    case movie(URL)
    case quickLook(URL)
    /// "Can’t Preview …", with `message` when the fetch failed.
    case unavailable(typeName: String, message: String?)
    /// Nothing: the document is closing.
    case empty
}

/// A tab's Rendered/Raw choice (per tab, never saved) and what it shows.
/// Markdown and SVG open rendered; a `:line` open shows Raw, since the
/// line is in the source. Markdown too big to render is Raw only.
struct LeoEditorPresentation: Equatable {
    /// Bigger Markdown (UTF-16 units) shows only as text.
    static let renderLimit = 5_000_000

    private(set) var isRaw = false

    func toggled() -> LeoEditorPresentation { LeoEditorPresentation(isRaw: !isRaw) }

    func revealing() -> LeoEditorPresentation { LeoEditorPresentation(isRaw: true) }

    /// Whether View ▸ Show Raw / Show Rendered applies.
    static func canToggleRaw(kind: LeoFilePreviewKind, textLength: Int, isPreview: Bool) -> Bool {
        guard case .rendered = kind, !isPreview else { return false }
        return textLength <= renderLimit
    }

    /// File ▸ Show in Finder for this Mac's files, Download for a remote host's.
    static func revealTitle(for host: LeoHostID) -> String {
        host == .local ? "Show in Finder" : "Download"
    }

    func content(kind: LeoFilePreviewKind, preview: LeoFilePreview.State?, typeName: String = "This File", textLength: Int) -> LeoEditorPaneContent {
        if let preview { return Self.content(kind: kind, preview: preview, typeName: typeName) }
        guard case .rendered(let format) = kind, !isRaw, textLength <= Self.renderLimit else { return .text }
        switch format {
        case .markdown: return .markdown
        case .svg: return .svg
        }
    }

    private static func content(kind: LeoFilePreviewKind, preview: LeoFilePreview.State, typeName: String) -> LeoEditorPaneContent {
        switch preview {
        case .loading(let fraction): return .loading(fraction: fraction)
        case .unsupported(let name): return .unavailable(typeName: name, message: nil)
        case .failed(let message): return .unavailable(typeName: typeName, message: message)
        case .closed: return .empty
        case .ready(let url):
            switch kind {
            case .movie: return .movie(url)
            case .quickLook: return .quickLook(url)
            case .image, .text, .rendered: return .image(url)
            }
        }
    }
}
