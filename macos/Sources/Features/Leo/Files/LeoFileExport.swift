import Darwin
import Foundation

/// Downloads one workspace file into a local folder (a drag out to Finder).
/// The bytes stream through `LeoFileAccess` into a private staging file
/// beside the destination, which is published only once complete and never
/// over anything already there: a clash keeps both, Finder style ("a 2.txt").
/// Any failure or cancellation removes the staging file -- it is local, so
/// it is always ours to remove -- leaving no partial file behind.
enum LeoFileExport {
    /// Numbered names tried, the plain name included, before giving up.
    static let keepBothLimit = 100
    /// A downloaded file is readable by everyone, as a Finder copy is.
    static let permissions: UInt16 = 0o644

    enum ExportError: LocalizedError, Equatable {
        case invalidName
        case noFreeName

        var errorDescription: String? {
            switch self {
            case .invalidName: "This item doesn’t have a valid file name."
            case .noFreeName: "Too many files with this name already exist in the destination."
            }
        }
    }

    /// Downloads the regular file at `remotePath` to `destination`, or to
    /// a numbered name beside it when that is taken. Returns where the file
    /// was written. `beforeWrite` (tests) runs before each chunk is written,
    /// with its offset. `CancellationError` passes through unchanged.
    @discardableResult
    static func download(
        remotePath: String,
        to destination: URL,
        access: any LeoFileAccess,
        beforeWrite: @escaping @Sendable (UInt64) async throws -> Void = { _ in }
    ) async throws -> URL {
        let name = destination.lastPathComponent
        let folderURL = destination.deletingLastPathComponent()
        let folderPath = folderURL.path(percentEncoded: false)
        guard destination.isFileURL, !destination.hasDirectoryPath, LeoFileName.isSafeComponent(name),
              !folderPath.contains("\0") else { throw ExportError.invalidName }
        try requireRegularFile(try await access.stat(remotePath), path: remotePath)

        let shownPath = (folderPath as NSString).appendingPathComponent(name)
        let folder = try LocalFolder(path: folderPath, shownPath: shownPath)
        let staging = try folder.createStaging(for: name)
        do {
            let sink = LeoFileDescriptorSink(descriptor: staging.descriptor, path: shownPath)
            try await access.read(remotePath, into: HookedSink(base: sink, beforeWrite: beforeWrite))
            try sink.finish(permissions: permissions)
            try Task.checkCancellation()
            let published = try folder.publish(staging.name, as: name)
            return folderURL.appendingPathComponent(published, isDirectory: false)
        } catch {
            folder.remove(staging.name)
            throw error
        }
    }

    /// One line for the browser's footer and Finder: a `LeoFileAccessError`
    /// or the export's own error as it renders itself, anything else
    /// treated like a server's text.
    static func message(for error: Error) -> String {
        guard error is LeoFileAccessError || error is ExportError else {
            return LeoSFTPServerText.isolated(error.localizedDescription)
        }
        return error.localizedDescription
    }

    /// "a.txt" -> "a 2.txt"; a name without an extension (".env",
    /// "Makefile") gets the number at its end.
    static func numbered(_ name: String, _ number: Int) -> String {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else { return "\(name) \(number)" }
        return "\((name as NSString).deletingPathExtension) \(number).\(pathExtension)"
    }

    private static func requireRegularFile(_ stat: LeoFileStat, path: String) throws {
        switch stat.kind {
        case .file: return
        case .directory: throw LeoFileAccessError.isADirectory(path: path)
        case .symlink, .other: throw LeoFileAccessError.failed(path: path, reason: "it isn’t a regular file")
        }
    }

    private struct HookedSink: LeoFileByteSink {
        let base: any LeoFileByteSink
        let beforeWrite: @Sendable (UInt64) async throws -> Void

        func write(_ data: Data, at offset: UInt64) async throws {
            try await beforeWrite(offset)
            try await base.write(data, at: offset)
        }
    }

    /// The destination folder, opened once: staging, publication and
    /// cleanup all happen relative to this descriptor, so a folder path
    /// swapped mid-download can't redirect any of them.
    private final class LocalFolder {
        private let descriptor: Int32
        /// What errors name: the file the user dropped, never staging.
        private let shownPath: String

        init(path: String, shownPath: String) throws {
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw LeoLocalFileBackend.error(errno, path: path) }
            self.descriptor = descriptor
            self.shownPath = shownPath
        }

        deinit {
            Darwin.close(descriptor)
        }

        /// A private (0600) hidden file, created exclusively and never
        /// through a symlink.
        func createStaging(for name: String) throws -> (name: String, descriptor: Int32) {
            let staging = (LeoFileAccessor<LeoLocalFileBackend>.temporarySibling(of: "/" + name) as NSString).lastPathComponent
            let file = openat(descriptor, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw LeoLocalFileBackend.error(errno, path: shownPath) }
            return (staging, file)
        }

        /// Moves `staging` to `name`, or the first free numbered name, never
        /// replacing anything (`RENAME_EXCL`): an existing file or symlink
        /// is left exactly as it was.
        func publish(_ staging: String, as name: String) throws -> String {
            for number in 1...LeoFileExport.keepBothLimit {
                let candidate = number == 1 ? name : LeoFileExport.numbered(name, number)
                if renameatx_np(descriptor, staging, descriptor, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
                guard errno == EEXIST else { throw LeoLocalFileBackend.error(errno, path: shownPath) }
            }
            throw ExportError.noFreeName
        }

        func remove(_ name: String) {
            unlinkat(descriptor, name, 0)
        }
    }
}
