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

    /// A file name that stays inside the folder it is written to: the last
    /// path component, without leading dots; `fallback` when nothing is left.
    static func safeFilename(_ name: String, fallback: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        let trimmed = String(last.drop { $0 == "." }).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
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
