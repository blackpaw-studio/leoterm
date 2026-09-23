import Foundation

/// An absolute path on the agent's host, plus where to put the caret.
struct LeoEditorLocation: Equatable, Sendable {
    let path: String
    let line: Int?
    let column: Int?

    init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

enum LeoEditorLinkError: Error, Equatable, Sendable {
    case empty
    /// Not something that names a file (a pathless URL, a NUL byte).
    case invalid(String)
    /// A relative path, but the agent reported no workspace.
    case noWorkspace
}

extension LeoEditorLinkError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty: "Enter the path of a file to open."
        case let .invalid(text): "“\(LeoSFTPServerText.sanitized(text))” isn’t a file path."
        case .noWorkspace: "This agent has no workspace, so a relative path can’t be opened. Use an absolute path."
        }
    }
}

/// A file reference surfaced in an agent's terminal -- a ⌘-clicked path or
/// OSC 8 `file://` link, or text typed into Open File in Editor… -- before
/// it is resolved to an absolute path on the agent's host. Paths are
/// normalized lexically (never through the local filesystem: the file may
/// live on a remote host).
struct LeoEditorLink: Equatable, Sendable {
    /// The largest line or column a link names: positions come from
    /// terminal output, which is untrusted, and larger ones are clamped.
    static let positionLimit = 1_000_000

    enum Base: Equatable, Sendable {
        /// `path` is absolute.
        case root
        /// `path` is relative to the host user's home (`~/…`).
        case home
        /// `path` is relative to the agent's workspace.
        case workspace
    }

    let base: Base
    let path: String
    let line: Int?
    let column: Int?

    init(base: Base, path: String, line: Int? = nil, column: Int? = nil) {
        self.base = base
        self.path = path
        self.line = line
        self.column = column
    }

    /// Whether `resolve` needs the host's home directory (a remote host's
    /// home costs a round trip, so it is only fetched when needed).
    var needsHome: Bool { base == .home }

    /// The text of a link Ghostty was asked to open that the editor should
    /// take instead, or nil to leave it to Ghostty. Ghostty's link
    /// detection reports scheme URLs and bare paths; OSC 8 targets are
    /// URIs, so only their `file:` ones are taken.
    static func fileReference(inOpenURL url: String, isOSC8: Bool) -> String? {
        guard !url.isEmpty else { return nil }
        if let scheme = scheme(of: url) { return scheme == "file" ? url : nil }
        return isOSC8 ? nil : url
    }

    static func parse(_ text: String) throws -> LeoEditorLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LeoEditorLinkError.empty }
        guard !trimmed.contains("\0") else { throw LeoEditorLinkError.invalid(trimmed) }
        if scheme(of: trimmed) == "file" { return try parseFileURL(trimmed) }
        let (path, line, column) = splitPosition(trimmed)
        return reference(to: path, line: line, column: column)
    }

    func resolve(workspace: String?, home: String?) throws -> LeoEditorLocation {
        let absolute: String
        switch base {
        case .root:
            absolute = path
        case .home:
            guard let home, home.hasPrefix("/") else { throw LeoEditorLinkError.invalid("~/\(path)") }
            absolute = Self.normalize(Self.join(home, path))
        case .workspace:
            guard let workspace, workspace.hasPrefix("/") else { throw LeoEditorLinkError.noWorkspace }
            absolute = Self.normalize(Self.join(workspace, path))
        }
        return LeoEditorLocation(path: absolute, line: line, column: column)
    }

    // MARK: - Parsing

    /// The lowercased URL scheme, if `text` starts with one (RFC 3986:
    /// a letter, then letters, digits, `+`, `-` or `.`, then `:`). A path
    /// like `src/a.swift:12` has a `/` before its colon, so it has none.
    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":"), colon > text.startIndex else { return nil }
        let candidate = text[..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        return candidate.lowercased()
    }

    /// `file:` URLs name an exact path (percent-decoded, no line suffix).
    /// The host is ignored: the link came from the agent's own terminal, so
    /// it names the agent's host whatever it calls it.
    private static func parseFileURL(_ text: String) throws -> LeoEditorLink {
        guard let components = URLComponents(string: text) else { throw LeoEditorLinkError.invalid(text) }
        let path = components.path
        guard !path.isEmpty, !path.contains("\0") else { throw LeoEditorLinkError.invalid(text) }
        return reference(to: path, line: nil, column: nil)
    }

    private static func reference(to path: String, line: Int?, column: Int?) -> LeoEditorLink {
        if path.hasPrefix("/") { return LeoEditorLink(base: .root, path: normalize(path), line: line, column: column) }
        if path == "~" { return LeoEditorLink(base: .home, path: "", line: line, column: column) }
        if path.hasPrefix("~/") { return LeoEditorLink(base: .home, path: relative(String(path.dropFirst(2))), line: line, column: column) }
        return LeoEditorLink(base: .workspace, path: relative(path), line: line, column: column)
    }

    /// Splits a trailing `:line` or `:line:column` (and a stray final `:`),
    /// as compilers and agents print them. Line and column start at 1, and
    /// stop at `positionLimit` (digits past `Int.max` included).
    private static func splitPosition(_ text: String) -> (String, Int?, Int?) {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        func number(_ part: String) -> Int? {
            guard !part.isEmpty, part.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            let value = Int(part) ?? Int.max
            return value > 0 ? min(value, positionLimit) : nil
        }
        if parts.count > 2, let line = number(parts[parts.count - 2]), let column = number(parts[parts.count - 1]) {
            return (parts.dropLast(2).joined(separator: ":"), line, column)
        }
        if parts.count > 1, let line = number(parts[parts.count - 1]) {
            return (parts.dropLast().joined(separator: ":"), line, nil)
        }
        return (text, nil, nil)
    }

    // MARK: - Paths

    /// A relative path with `.` segments and empty segments dropped (`..`
    /// is kept: it may climb out of the workspace, which is allowed).
    private static func relative(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }

    private static func join(_ base: String, _ path: String) -> String {
        path.isEmpty ? base : base + "/" + path
    }

    /// Resolves `.`, `..` and repeated slashes without touching any
    /// filesystem; `..` at the root stays at the root.
    static func normalize(_ absolute: String) -> String {
        var segments: [Substring] = []
        for segment in absolute.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": _ = segments.popLast()
            default: segments.append(segment)
            }
        }
        return "/" + segments.joined(separator: "/")
    }
}
