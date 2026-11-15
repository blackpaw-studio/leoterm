import Darwin
import Foundation
import LeoKit

/// One fetched preview: its private folder and the file in it, plus the
/// `stat` taken before reading (the version the preview shows).
struct LeoFilePreviewFetch: Equatable, Sendable {
    let folder: URL
    let file: URL
    let stat: LeoFileStat
}

/// Where previews of images, movies and documents live while shown
/// (B-278): `$TMPDIR/<bundle id>.previews/<uuid>/<name>`, each fetch in a
/// private (0700) folder of its own. The bytes stream through
/// `LeoFileAccess` -- local files too, so both backends take one path --
/// via `LeoFileExport`'s staging, so a failed or cancelled fetch leaves
/// nothing behind. Only `discard` removes a fetched folder, and only one
/// directly under `root`; macOS clears anything a crash leaves in $TMPDIR.
struct LeoFilePreviewCache: Sendable {
    /// Bigger files get Can't Preview (with Download) instead.
    static let fetchLimit: UInt64 = 2_000_000_000
    /// The file name used when the real one isn't a safe path component.
    static let fallbackName = "preview"

    static let shared = LeoFilePreviewCache(root: defaultRoot)

    static var defaultRoot: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "studio.blackpaw.leo"
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleID).previews", isDirectory: true)
    }

    let root: URL
    var fetchLimit: UInt64 = Self.fetchLimit

    /// Streams the regular file at `path` into a fresh folder. `progress`
    /// runs before each chunk is written, with its offset; cancellation
    /// ends the fetch (`CancellationError`). Files over `fetchLimit` fail
    /// with `.tooLarge` before a byte is read, and one that grows past it
    /// meanwhile as soon as it does.
    func fetch(
        _ path: String,
        access: any LeoFileAccess,
        progress: @escaping @Sendable (UInt64) async throws -> Void = { _ in }
    ) async throws -> LeoFilePreviewFetch {
        let stat = try await access.stat(path)
        guard stat.size <= fetchLimit else { throw LeoFileAccessError.tooLarge(path: path, size: stat.size, limit: fetchLimit) }
        let folder = try makeFolder()
        do {
            let destination = folder.appendingPathComponent(Self.storedName(for: path), isDirectory: false)
            let fetched = try await LeoFileExport.fetch(remotePath: path, to: destination, access: access, maxBytes: fetchLimit) { offset in
                try Task.checkCancellation()
                try await progress(offset)
            }
            try Task.checkCancellation()
            return LeoFilePreviewFetch(folder: folder, file: fetched.url, stat: fetched.stat)
        } catch {
            remove(folder)
            throw error
        }
    }

    /// Deletes the fetch's folder, if it is one of ours.
    func discard(_ fetch: LeoFilePreviewFetch) {
        remove(fetch.folder)
    }

    /// The file's own name when safe (its extension is what decoders and
    /// Quick Look go by), else `preview.<ext>`.
    static func storedName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if LeoFileName.isSafeComponent(name) { return name }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty || !LeoFileName.isSafeComponent(ext) ? fallbackName : "\(fallbackName).\(ext)"
    }

    // MARK: - Folders

    private func makeFolder() throws -> URL {
        try ensureRoot()
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { throw LeoLocalFileBackend.error(errno, path: folder.path) }
        return folder
    }

    /// Creates `root` (0700) if missing; refuses one that is a symlink or
    /// not ours.
    private func ensureRoot() throws {
        let path = root.path
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            if errno == ENOENT {
                try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                return try ensureRoot()
            }
            throw LeoLocalFileBackend.error(errno, path: path)
        }
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw LeoLocalFileBackend.error(errno, path: path) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw LeoFileAccessError.failed(path: path, reason: "it isn’t a private folder")
        }
        if info.st_mode & 0o777 != 0o700 { chmod(path, 0o700) }
    }

    /// Removes `folder` only when it is a UUID-named directory directly
    /// under `root` (resolving symlinks on both sides).
    private func remove(_ folder: URL) {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == resolvedRoot, UUID(uuidString: folder.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
