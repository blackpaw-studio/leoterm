import Foundation
import UniformTypeIdentifiers

/// One workspace file `browser_upload` sets on a page's file input.
public struct LeoBrowserUploadFile: Equatable, Sendable {
    /// The file's own name, as the page sees it.
    public let name: String
    /// From the name's extension; `application/octet-stream` when unknown.
    public let mimeType: String
    public let data: Data
    /// Relative to the workspace, e.g. `docs/a.pdf`.
    public let workspacePath: String

    public init(name: String, mimeType: String, data: Data, workspacePath: String) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.workspacePath = workspacePath
    }

    /// The MIME type a page sees for a file called `name`.
    public static func mimeType(forName name: String) -> String {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else { return fallbackMIMEType }
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? fallbackMIMEType
    }

    static let fallbackMIMEType = "application/octet-stream"
}

/// Reads the files `browser_upload` names from the agent's workspace through
/// the machine's file backend (local filesystem or SFTP), so uploads work the
/// same on every machine. Paths are workspace-relative or absolute inside the
/// workspace; anything that leaves it, lexically, is refused. Every failure is
/// a `LeoBrowserError`: `no_such_file` for a missing file, `invalid_args` for a
/// path outside the workspace, a folder or too many bytes, and `file_error`
/// when the backend can't read one.
///
/// The check is lexical: a symlink inside the workspace that points out of it
/// is followed. The agent owns its workspace and can read those files anyway.
public struct LeoBrowserUploadReader: Sendable {
    /// A fresh file access for the browser's machine; each read closes its own.
    public typealias MakeAccess = @Sendable () async throws -> any LeoFileAccess
    public typealias Workspace = @MainActor @Sendable () -> String?

    /// The most bytes one call uploads, all files together. They travel to the
    /// page as base64 in one script call.
    public static let defaultMaximumTotalBytes: UInt64 = 25 * 1024 * 1024

    /// A reader for a browser with no workspace: every read fails clearly.
    public static let noWorkspace = LeoBrowserUploadReader(
        makeAccess: { throw LeoFileAccessError.unavailable(reason: "no workspace") }, workspace: { nil }
    )

    private let makeAccess: MakeAccess
    private let workspace: Workspace
    private let maximumTotalBytes: UInt64

    /// `workspace` is read on every call (an agent reports it late).
    public init(makeAccess: @escaping MakeAccess, workspace: @escaping Workspace, maximumTotalBytes: UInt64 = defaultMaximumTotalBytes) {
        self.makeAccess = makeAccess
        self.workspace = workspace
        self.maximumTotalBytes = maximumTotalBytes
    }

    /// Every file, in order. Checks every path, then every file's kind and the
    /// total size, before reading a byte.
    public func read(_ paths: [String]) async throws -> [LeoBrowserUploadFile] {
        guard let root = await workspace().flatMap(LeoWorkspacePath.init) else {
            throw LeoBrowserError(.noSuchFile, "This agent has no workspace, so there are no files to upload")
        }
        let resolved = try paths.map { try root.resolve($0) }
        let access = try await Self.mapped(path: nil) { try await makeAccess() }
        do {
            let files = try await read(resolved, access: access)
            await access.close()
            return files
        } catch {
            await access.close()
            throw error
        }
    }

    private func read(_ paths: [LeoWorkspacePath.Resolved], access: any LeoFileAccess) async throws -> [LeoBrowserUploadFile] {
        var total: UInt64 = 0
        for path in paths {
            let stat = try await Self.mapped(path: path) { try await access.stat(path.absolute) }
            switch stat.kind {
            case .file: break
            case .directory: throw LeoBrowserError.invalidArgs("\(path.requested) is a folder; folder uploads aren't supported")
            case .symlink, .other: throw LeoBrowserError.invalidArgs("\(path.requested) isn't a regular file")
            }
            total += stat.size
            guard total <= maximumTotalBytes else { throw tooLarge() }
        }
        var files: [LeoBrowserUploadFile] = []
        var remaining = maximumTotalBytes
        for path in paths {
            let contents = try await Self.mapped(path: path) { try await access.read(path.absolute, maxBytes: remaining) }
            remaining -= min(remaining, UInt64(contents.data.count))
            files.append(LeoBrowserUploadFile(
                name: path.name, mimeType: LeoBrowserUploadFile.mimeType(forName: path.name),
                data: contents.data, workspacePath: path.workspacePath
            ))
        }
        return files
    }

    private func tooLarge() -> LeoBrowserError {
        .invalidArgs("The files come to more than \(maximumTotalBytes / (1024 * 1024)) MB; upload fewer or smaller files")
    }

    /// File-access failures become browser errors naming the path the agent passed.
    private static func mapped<T>(path: LeoWorkspacePath.Resolved?, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as LeoBrowserError {
            throw error
        } catch let error as LeoFileAccessError {
            throw browserError(error, path: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw browserError(.wrapping(error, path: path?.absolute ?? ""), path: path)
        }
    }

    private static func browserError(_ error: LeoFileAccessError, path: LeoWorkspacePath.Resolved?) -> LeoBrowserError {
        let requested = path?.requested ?? ""
        switch error {
        case .notFound, .notADirectory:
            return LeoBrowserError(.noSuchFile, "No file at \(requested) in the workspace")
        case .isADirectory:
            return .invalidArgs("\(requested) is a folder; folder uploads aren't supported")
        case .tooLarge:
            return .invalidArgs("The files come to more than the upload limit; upload fewer or smaller files")
        default:
            let detail = LeoSFTPServerText.sanitized(error.localizedDescription)
            return LeoBrowserError(.fileError, path == nil ? "Couldn't reach the workspace: \(detail)" : "Couldn't read \(requested): \(detail)")
        }
    }
}

/// An absolute workspace folder, normalised, and the paths resolved in it.
struct LeoWorkspacePath: Equatable {
    struct Resolved: Equatable {
        /// What the agent passed, for messages.
        let requested: String
        let absolute: String
        let workspacePath: String
        var name: String { (absolute as NSString).lastPathComponent }
    }

    let components: [String]

    /// Nil for anything but an absolute path without NUL.
    init?(_ path: String) {
        guard path.hasPrefix("/"), !path.contains("\0"), let components = Self.normalized(path.split(separator: "/").map(String.init)) else { return nil }
        self.components = components
    }

    var absolute: String { "/" + components.joined(separator: "/") }

    /// `path` relative to the workspace, or absolute; `.` and `..` collapse
    /// lexically. Anything that ends up outside the workspace, or at the
    /// workspace folder itself, is `invalid_args`.
    func resolve(_ path: String) throws -> Resolved {
        let outside = LeoBrowserError.invalidArgs("\(path) is outside the workspace (\(absolute)); upload files from inside it")
        guard !path.contains("\0") else { throw LeoBrowserError.invalidArgs("Paths can't contain NUL") }
        let joined = path.hasPrefix("/") ? path.split(separator: "/").map(String.init) : components + path.split(separator: "/").map(String.init)
        guard let normalized = Self.normalized(joined), Array(normalized.prefix(components.count)) == components else { throw outside }
        guard normalized.count > components.count else {
            throw LeoBrowserError.invalidArgs("\(path) is the workspace folder; folder uploads aren't supported")
        }
        return Resolved(
            requested: path, absolute: "/" + normalized.joined(separator: "/"),
            workspacePath: normalized.dropFirst(components.count).joined(separator: "/")
        )
    }

    /// Drops empty and `.` components and applies `..`; nil when `..` climbs
    /// above the root.
    private static func normalized(_ components: [String]) -> [String]? {
        var result: [String] = []
        for component in components where !component.isEmpty && component != "." {
            if component == ".." {
                guard !result.isEmpty else { return nil }
                result.removeLast()
            } else {
                result.append(component)
            }
        }
        return result
    }
}
