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
            do {
                uploaded.append(try await upload(source, to: directory, access: access, beforeOpen: beforeSourceOpen, beforeRead: beforeSourceRead))
            } catch is CancellationError {
                break
            } catch {
                failures.append(Failure(name: displayName(for: source), message: message(for: error)))
            }
        }
        return Result(uploaded: uploaded, failures: failures)
    }

    /// Opens the source exactly once without following a final symlink and
    /// streams that descriptor into an exclusive create. A Finder path may
    /// be replaced after it is dropped; reading by pathname would let that
    /// replacement choose the bytes uploaded (or block on a FIFO). Runs in a
    /// task-group child so the blocking open and reads never run on the
    /// caller's actor (the main actor for a drop).
    private static func upload(
        _ url: URL,
        to directory: String,
        access: any LeoFileAccess,
        beforeOpen: @escaping @Sendable (URL) throws -> Void,
        beforeRead: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> Uploaded {
        try await withThrowingTaskGroup(of: Uploaded.self) { group in
            group.addTask(priority: .userInitiated) {
                try Task.checkCancellation()
                guard url.isFileURL else { throw SourceError.invalid }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                // A NUL anywhere would truncate the C path at `open` and read
                // a different file than the one dropped.
                let path = url.path(percentEncoded: false)
                guard isSingleComponent(name), !path.contains("\0") else { throw SourceError.invalid }
                try beforeOpen(url)
                let source = try LeoFileDescriptorSource(path: path)
                try await beforeRead(url)
                try Task.checkCancellation()
                let destination = append(name, to: directory)
                try await access.create(at: destination, from: source)
                return Uploaded(name: name, path: destination)
            }
            return try await group.next()!
        }
    }

    private enum SourceError: LocalizedError {
        case invalid

        var errorDescription: String? { "This item doesn’t have a valid file name." }
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
