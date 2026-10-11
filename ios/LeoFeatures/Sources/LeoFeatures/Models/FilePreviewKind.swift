import Foundation
import UniformTypeIdentifiers

/// How a surfaced file is shown, from its name: QuickLook for images, PDF,
/// audio/video and office documents; rendered Markdown; a text view for
/// text and code. `unknown` is decided after download by sniffing.
public enum FilePreviewKind: Equatable, Sendable {
    case quickLook
    case markdown
    case text
    case unknown

    /// QuickLook previews download whole, up to this.
    public static let quickLookCap: Int64 = 100 << 20
    /// Text previews show at most this much of the file (a `Range` read).
    public static let textPreviewCap: Int64 = 1 << 20
    /// How far `decodeText` looks for a NUL byte.
    static let sniffLength = 8192

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    private static let documentExtensions: Set<String> = [
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf", "rtfd", "usdz",
    ]

    public init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) { self = .markdown; return }
        if Self.documentExtensions.contains(ext) { self = .quickLook; return }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else {
            self = .unknown
            return
        }
        if [.image, .pdf, .audiovisualContent, .presentation, .spreadsheet].contains(where: type.conforms) {
            self = .quickLook
        } else if [.text, .sourceCode, .json, .xml, .yaml, .propertyList].contains(where: type.conforms) {
            self = .text
        } else {
            self = .unknown
        }
    }

    /// Text previews may be cut at the cap; QuickLook needs the whole file.
    public var maxBytes: Int64 { self == .quickLook ? Self.quickLookCap : Self.textPreviewCap }
    public var truncates: Bool { self != .quickLook }
    public var readsText: Bool { self != .quickLook }

    /// UTF-8 text (invalid sequences replaced, so a cut mid-character is
    /// fine), or nil when the start of the data holds a NUL (binary).
    public static func decodeText(_ data: Data) -> String? {
        guard !data.prefix(sniffLength).contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
