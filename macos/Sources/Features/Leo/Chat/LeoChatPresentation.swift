import Foundation
import LeoKit
import UniformTypeIdentifiers

/// Pure display rules for the chat pane.
enum LeoChatPresentation {
    /// Replies longer than this collapse behind "Show more".
    static let collapsedCharacters = 600
    static let collapsedLines = 12

    static func isLong(_ text: String) -> Bool {
        text.count > collapsedCharacters || text.split(separator: "\n", omittingEmptySubsequences: false).count > collapsedLines
    }

    /// The name used when neither a name nor its fallback leaves anything.
    static let lastResortFilename = "file"

    /// A file name that stays inside the folder it is written to: the last
    /// path component, trimmed, without leading dots. When nothing is left,
    /// `fallback` sanitized the same way, then `lastResortFilename`.
    static func safeFilename(_ name: String, fallback: String) -> String {
        sanitizedComponent(name) ?? sanitizedComponent(fallback) ?? lastResortFilename
    }

    private static func sanitizedComponent(_ name: String) -> String? {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        let undotted = String(last.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "." })
        let trimmed = undotted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `url` when its standardized path lies strictly inside `folder`.
    static func contained(_ url: URL, in folder: URL) -> URL? {
        let root = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? url.standardizedFileURL : nil
    }

    static func mime(forFilename name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The one line a collapsed task card shows.
    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }
}
