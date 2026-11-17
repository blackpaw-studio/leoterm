import Foundation

/// What a page capture is saved as.
public enum LeoBrowserCaptureKind: String, Equatable, Sendable {
    case pdf
    case png

    public var pathExtension: String { rawValue }
}

/// Where a capture is saved: a folder relative to the workspace and a file
/// name, before any clash numbering.
public struct LeoBrowserCaptureTarget: Equatable, Sendable {
    /// Relative to the workspace, `/`-separated; empty for the workspace itself.
    public let folder: String
    /// One safe path component ending in the capture's extension.
    public let name: String

    public init(folder: String, name: String) {
        self.folder = folder
        self.name = name
    }

    public var workspacePath: String { folder.isEmpty ? name : folder + "/" + name }
}

/// The rules for the `path` of `browser_pdf` / `browser_screenshot` and the
/// Mac save sheet. A path is relative to the workspace, or absolute inside
/// it. A trailing `/` means "this folder, default name"; a missing
/// extension is appended; a different extension, an empty, `.` or `..`
/// component, or a control character is `invalid_args`. Missing folders are
/// created when the capture is saved. The name is made safe as a download's
/// is (`LeoBrowserDownloadName`).
///
/// The agent chooses this path, so nothing may climb out of the workspace.
/// A symlinked folder inside it is followed (the agent has a shell there).
public enum LeoBrowserCapturePath {
    /// Where a capture goes when no path is given.
    public static let defaultFolder = LeoBrowserDownloadSaver.folderName
    /// The name stem when the page has neither a title nor a host.
    public static let fallbackStem = "page"
    /// An extension is only a real one when it is this short and alphanumeric
    /// ("Node.js — Docs" has none; "notes.v2" has `v2`).
    private static let maximumExtensionLength = 8

    /// The default file name: the page title made safe, else the host, else
    /// `page`, with the kind's extension (not doubled when the title already
    /// ends in it).
    public static func defaultName(title: String, host: String?, kind: LeoBrowserCaptureKind) -> String {
        let stem = [title, host ?? ""].lazy
            .map { LeoBrowserDownloadName.sanitized($0, fallback: "") }
            .first { !$0.isEmpty } ?? fallbackStem
        let named = hasExtension(stem, kind) ? stem : stem + "." + kind.pathExtension
        return LeoBrowserDownloadName.sanitized(named)
    }

    /// Checks what can be checked without the workspace: the relative form
    /// and the extension. An absolute path passes here and is checked
    /// against the workspace by `resolve`. Throws `invalid_args`.
    public static func validate(_ path: String, kind: LeoBrowserCaptureKind) throws {
        do { _ = try checkedForm(path, kind: kind) } catch { throw error.browserError }
    }

    /// Resolves `path` (nil for `downloads/<defaultName>`) against the
    /// absolute `workspace`. Throws `invalid_args`.
    public static func resolve(
        _ path: String?, workspace: String, kind: LeoBrowserCaptureKind, defaultName: String
    ) throws -> LeoBrowserCaptureTarget {
        guard let path else { return LeoBrowserCaptureTarget(folder: defaultFolder, name: defaultName) }
        do {
            return try resolved(path, workspace: workspace, kind: kind, defaultName: defaultName)
        } catch {
            throw error.browserError
        }
    }

    /// What is wrong with `path`, as a sentence for the person typing it
    /// ("The path must end in .pdf."), or nil when it is fine. Without a
    /// workspace only the form is checked.
    public static func problem(with path: String, kind: LeoBrowserCaptureKind, workspace: String?) -> String? {
        do {
            if let workspace {
                _ = try resolved(path, workspace: workspace, kind: kind, defaultName: "page." + kind.pathExtension)
            } else {
                _ = try checkedForm(path, kind: kind)
            }
            return nil
        } catch {
            return "The path \(error.problem)."
        }
    }

    // MARK: - Helpers

    /// What is wrong with a path; `invalid_args` for the agent.
    private struct Problem: Error {
        let path: String
        let problem: String

        var browserError: LeoBrowserError {
            .invalidArgs("path \(LeoSFTPServerText.isolated(path).debugDescription) \(problem)")
        }
    }

    private static func checkedForm(_ path: String, kind: LeoBrowserCaptureKind) throws(Problem) -> LeoBrowserCaptureTarget {
        guard !path.isEmpty else { throw Problem(path: path, problem: "is empty") }
        let relative = path.hasPrefix("/") ? String(path.drop { $0 == "/" }) : path
        return try target(relative: relative, kind: kind, defaultName: "page." + kind.pathExtension, shown: path)
    }

    private static func resolved(
        _ path: String, workspace: String, kind: LeoBrowserCaptureKind, defaultName: String
    ) throws(Problem) -> LeoBrowserCaptureTarget {
        guard path.hasPrefix("/") else {
            guard !path.isEmpty else { throw Problem(path: path, problem: "is empty") }
            return try target(relative: path, kind: kind, defaultName: defaultName, shown: path)
        }
        let root = workspace.count > 1 && workspace.hasSuffix("/") ? String(workspace.dropLast()) : workspace
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { throw Problem(path: path, problem: "is outside the workspace (\(root))") }
        return try target(relative: String(path.dropFirst(prefix.count)), kind: kind, defaultName: defaultName, shown: path)
    }

    /// `relative` has the workspace (and its `/`) removed; empty is the
    /// workspace itself, which takes the default name like a trailing `/`.
    private static func target(
        relative: String, kind: LeoBrowserCaptureKind, defaultName: String, shown: String
    ) throws(Problem) -> LeoBrowserCaptureTarget {
        guard !relative.isEmpty else { return LeoBrowserCaptureTarget(folder: "", name: defaultName) }
        let isFolder = relative.hasSuffix("/")
        let parts = (isFolder ? String(relative.dropLast()) : relative)
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts where !LeoFileName.isSafeComponent(part) {
            throw Problem(path: shown, problem: componentProblem(part))
        }
        let folders = isFolder ? parts : Array(parts.dropLast())
        let name = isFolder ? defaultName : try fileName(parts[parts.count - 1], kind: kind, shown: shown)
        return LeoBrowserCaptureTarget(folder: folders.joined(separator: "/"), name: name)
    }

    private static func componentProblem(_ part: String) -> String {
        switch part {
        case "": "has an empty component"
        case ".", "..": "may not contain . or .. components"
        default: "may not contain control characters"
        }
    }

    private static func fileName(_ raw: String, kind: LeoBrowserCaptureKind, shown: String) throws(Problem) -> String {
        guard !LeoFileName.isStagingName(raw) else { throw Problem(path: shown, problem: "is a name Leo reserves") }
        if hasExtension(raw, kind) { return LeoBrowserDownloadName.sanitized(raw) }
        let pathExtension = (raw as NSString).pathExtension
        if isRealExtension(pathExtension) { throw Problem(path: shown, problem: "must end in .\(kind.pathExtension)") }
        return LeoBrowserDownloadName.sanitized(raw + "." + kind.pathExtension)
    }

    private static func hasExtension(_ name: String, _ kind: LeoBrowserCaptureKind) -> Bool {
        (name as NSString).pathExtension.lowercased() == kind.pathExtension
    }

    private static func isRealExtension(_ text: String) -> Bool {
        (1...maximumExtensionLength).contains(text.count) && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }
}
