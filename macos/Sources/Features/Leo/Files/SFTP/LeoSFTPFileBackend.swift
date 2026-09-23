import Foundation

struct LeoSFTPOptions: Sendable {
    /// Bytes per READ/WRITE request. 32 KiB is the size every SFTP server
    /// must accept.
    let chunkSize: Int
    /// Requests kept in flight at once while streaming a file.
    let maxRequestsInFlight: Int
    /// Use `posix-rename@openssh.com` for an atomic replace when the server
    /// offers it. `false` forces the REMOVE + RENAME fallback (tests).
    let usesPosixRename: Bool

    init(chunkSize: Int = 32 * 1024, maxRequestsInFlight: Int = 16, usesPosixRename: Bool = true) {
        precondition(chunkSize > 0 && chunkSize <= Int(UInt32.max), "chunkSize must fit a READ length")
        precondition(maxRequestsInFlight > 0, "at least one request must be allowed in flight")
        self.chunkSize = chunkSize
        self.maxRequestsInFlight = maxRequestsInFlight
        self.usesPosixRename = usesPosixRename
    }
}

/// `LeoFileAccessBackend` over SFTP v3. Reads and writes are pipelined: up
/// to `maxRequestsInFlight` chunk requests are outstanding at once.
struct LeoSFTPFileBackend: LeoFileAccessBackend {
    let session: LeoSFTPSession
    let options: LeoSFTPOptions

    func stat(_ path: String) async throws -> LeoFileStat {
        Self.fileStat(try await client().stat(path))
    }

    func lstat(_ path: String) async throws -> LeoFileStat {
        Self.fileStat(try await client().lstat(path))
    }

    func realpath(_ path: String) async throws -> String {
        try await client().realpath(path)
    }

    /// sshd starts the SFTP subsystem in the user's home directory, so
    /// `.` is home.
    func homeDirectory() async throws -> String {
        try await client().realpath(".")
    }

    func entries(of directory: String) async throws -> [LeoFileEntry] {
        let client = try await client()
        let handle = try await client.openDirectory(directory)
        return try await closing(handle, path: directory, client: client) {
            var entries: [LeoFileEntry] = []
            while let names = try await client.readDirectory(handle, path: directory) {
                entries += names.map { name in
                    let stat = Self.fileStat(name.attributes)
                    return LeoFileEntry(name: name.filename, kind: stat.kind, size: stat.size, modified: stat.modified)
                }
            }
            return entries
        }
    }

    func contents(of path: String, limit: UInt64) async throws -> Data {
        let client = try await client()
        let handle = try await client.open(path, flags: [.read])
        return try await closing(handle, path: path, client: client) {
            var data = Data()
            while UInt64(data.count) <= limit {
                let window = try await readWindow(handle, from: UInt64(data.count), path: path, client: client)
                data.append(window.data)
                if window.reachedEnd { break }
            }
            return data
        }
    }

    /// Opened `0600` when `permissions` will be applied (never briefly more
    /// open than the original); FSETSTAT then sets them exactly, since the
    /// mode passed to OPEN is filtered by the server's umask.
    func create(_ path: String, data: Data, permissions: UInt16?) async throws {
        let client = try await client()
        let initial = permissions == nil ? LeoSFTPAttributes() : LeoSFTPAttributes(permissions: 0o600)
        let handle = try await client.open(path, flags: [.write, .create, .exclusive], attributes: initial)
        do {
            try await writeChunks(of: data, to: handle, path: path, client: client)
            if let permissions {
                try await client.setAttributes(handle, LeoSFTPAttributes(permissions: UInt32(permissions)), path: path)
            }
            try await client.close(handle, path: path)
        } catch {
            try? await client.close(handle, path: path)
            try? await client.remove(path)
            throw error
        }
    }

    func remove(_ path: String) async throws {
        try await client().remove(path)
    }

    /// Atomic via `posix-rename@openssh.com` when available. Otherwise v3
    /// RENAME, which OpenSSH refuses over an existing file, so the target is
    /// removed first: for that instant the file does not exist, and if the
    /// RENAME then fails the new contents are kept at `source` rather than
    /// deleted -- the only non-atomic window in the SFTP backend.
    func replace(_ destination: String, with source: String) async throws {
        let client = try await client()
        if options.usesPosixRename, client.server.supportsPosixRename {
            do {
                try await client.posixRename(source, to: destination)
            } catch {
                try? await client.remove(source)
                throw error
            }
            return
        }
        do {
            try await client.remove(destination)
        } catch LeoFileAccessError.notFound {
            // Nothing to replace.
        } catch {
            try? await client.remove(source)
            throw error
        }
        do {
            try await client.rename(source, to: destination)
        } catch {
            let kept = (source as NSString).lastPathComponent
            throw LeoFileAccessError.failed(
                path: destination,
                reason: "the original was removed but the new contents couldn’t be moved into place; they were kept as “\(kept)”"
            )
        }
    }

    func close() async {
        await session.close()
    }

    // MARK: - Pipelining

    private func client() async throws -> LeoSFTPClient {
        try await session.client()
    }

    /// One window of `maxRequestsInFlight` consecutive chunk reads, stitched
    /// in order. Stops at the first short chunk (the next window resumes from
    /// wherever it ended) or at end of file.
    private func readWindow(_ handle: Data, from start: UInt64, path: String, client: LeoSFTPClient) async throws -> (data: Data, reachedEnd: Bool) {
        let chunkSize = options.chunkSize
        let chunks = try await withThrowingTaskGroup(of: (Int, Data?).self) { group in
            for index in 0..<options.maxRequestsInFlight {
                let offset = start + UInt64(index * chunkSize)
                group.addTask { (index, try await client.read(handle, offset: offset, length: UInt32(chunkSize), path: path)) }
            }
            return try await group.reduce(into: [Int: Data?]()) { $0[$1.0] = $1.1 }
        }
        var data = Data()
        for index in 0..<options.maxRequestsInFlight {
            guard let chunk = chunks[index] ?? nil, !chunk.isEmpty else { return (data, true) }
            data.append(chunk)
            if chunk.count < chunkSize { return (data, false) }
        }
        return (data, false)
    }

    private func writeChunks(of data: Data, to handle: Data, path: String, client: LeoSFTPClient) async throws {
        let chunkSize = options.chunkSize
        let limit = options.maxRequestsInFlight
        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for offset in stride(from: 0, to: data.count, by: chunkSize) {
                if inFlight == limit {
                    try await group.next()
                    inFlight -= 1
                }
                let lower = data.startIndex + offset
                let chunk = data.subdata(in: lower..<min(lower + chunkSize, data.endIndex))
                group.addTask { try await client.write(handle, offset: UInt64(offset), data: chunk, path: path) }
                inFlight += 1
            }
            try await group.waitForAll()
        }
    }

    /// Runs `body`, then closes `handle` whether or not it threw. A failed
    /// close after a successful body is ignored: nothing was lost.
    private func closing<T>(_ handle: Data, path: String, client: LeoSFTPClient, _ body: () async throws -> T) async throws -> T {
        do {
            let result = try await body()
            try? await client.close(handle, path: path)
            return result
        } catch {
            try? await client.close(handle, path: path)
            throw error
        }
    }

    private static func fileStat(_ attributes: LeoSFTPAttributes) -> LeoFileStat {
        LeoFileStat(
            kind: attributes.kind,
            size: attributes.size ?? 0,
            modified: Date(timeIntervalSince1970: TimeInterval(attributes.times?.modified ?? 0)),
            permissions: UInt16(truncatingIfNeeded: (attributes.permissions ?? 0) & 0o7777)
        )
    }
}

extension LeoFileAccessor where Backend == LeoSFTPFileBackend {
    /// SFTP through whatever `launcher` starts -- in the app, `ssh -s <host>
    /// sftp` multiplexed over the tunnel's ControlMaster.
    static func sftp(launcher: any LeoSFTPLaunching, options: LeoSFTPOptions = .init()) -> LeoFileAccessor<LeoSFTPFileBackend> {
        LeoFileAccessor(backend: LeoSFTPFileBackend(session: LeoSFTPSession(launcher: launcher), options: options))
    }
}
