import Darwin
import Foundation

/// One ordered Finder drop into an agent workspace. Source bytes are read
/// locally and every destination is created exclusively through
/// `LeoFileAccess`, so local and SFTP hosts have identical collision and
/// cleanup semantics.
enum LeoFileDrop {
    struct Uploaded: Equatable, Sendable {
        let name: String
        /// Absolute path in the agent workspace, never the Finder source.
        let path: String
    }

    struct Failure: Equatable, Sendable {
        let name: String
        let message: String
    }

    struct Result: Equatable, Sendable {
        let uploaded: [Uploaded]
        let failures: [Failure]

        /// Text inserted into an attached terminal: only successful remote
        /// workspace paths, shell escaped in Finder order.
        var shellText: String {
            uploaded.map { Ghostty.Shell.escape($0.path) }.joined(separator: " ")
        }

        var errorMessage: String {
            failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")
        }
    }

    static func upload(
        _ sources: [URL],
        to directory: String,
        access: any LeoFileAccess,
        beforeSourceOpen: @escaping @Sendable (URL) throws -> Void = { _ in },
        beforeSourceRead: @escaping @Sendable (URL) async throws -> Void = { _ in }
    ) async -> Result {
        var uploaded: [Uploaded] = []
        var failures: [Failure] = []
        for source in sources {
            if Task.isCancelled { break }
            let name = displayName(for: source)
            do {
                let item = try await read(source, beforeOpen: beforeSourceOpen, beforeRead: beforeSourceRead)
                try Task.checkCancellation()
                let destination = append(item.name, to: directory)
                try await access.create(item.data, at: destination)
                uploaded.append(Uploaded(name: item.name, path: destination))
            } catch is CancellationError {
                break
            } catch {
                failures.append(Failure(name: name, message: message(for: error)))
            }
        }
        return Result(uploaded: uploaded, failures: failures)
    }

    private struct Source: Sendable {
        let name: String
        let data: Data
    }

    /// Open exactly once without following a final symlink, then validate
    /// and read that descriptor. A Finder path may be replaced after it is
    /// dropped; pathname metadata followed by `Data(contentsOf:)` would let
    /// that replacement choose the bytes uploaded (or block on a FIFO).
    private static func read(
        _ url: URL,
        beforeOpen: @escaping @Sendable (URL) throws -> Void,
        beforeRead: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> Source {
        try await withThrowingTaskGroup(of: Source.self) { group in
            group.addTask(priority: .userInitiated) {
                try Task.checkCancellation()
                guard url.isFileURL else { throw SourceError.invalid }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                guard isSingleComponent(name) else { throw SourceError.invalid }
                try beforeOpen(url)
                let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
                guard descriptor >= 0 else {
                    if errno == ELOOP { throw SourceError.notRegularFile }
                    throw SourceError.unreadable(String(cString: strerror(errno)))
                }
                defer { Darwin.close(descriptor) }
                var status = Darwin.stat()
                guard fstat(descriptor, &status) == 0 else {
                    throw SourceError.unreadable(String(cString: strerror(errno)))
                }
                guard status.st_mode & S_IFMT == S_IFREG else { throw SourceError.notRegularFile }
                try await beforeRead(url)
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    try Task.checkCancellation()
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw SourceError.unreadable(String(cString: strerror(errno)))
                    }
                    data.append(buffer, count: count)
                }
                return Source(name: name, data: data)
            }
            return try await group.next()!
        }
    }

    private enum SourceError: LocalizedError {
        case invalid
        case notRegularFile
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .invalid: "This item doesn’t have a valid file name."
            case .notRegularFile: "Only files can be uploaded."
            case .unreadable(let reason): "This file couldn’t be read: \(LeoSFTPServerText.sanitized(reason))."
            }
        }
    }

    private static func append(_ name: String, to directory: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    private static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func displayName(for url: URL) -> String {
        let sanitized = LeoSFTPServerText.sanitized(url.lastPathComponent)
        return sanitized.isEmpty ? "File" : sanitized
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LeoFileAccessError {
            if case .conflict = error { return "A file with this name already exists." }
            return error.localizedDescription
        }
        return LeoSFTPServerText.sanitized(error.localizedDescription)
    }
}
