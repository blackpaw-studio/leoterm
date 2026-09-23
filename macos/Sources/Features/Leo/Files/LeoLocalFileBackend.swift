import Darwin
import Foundation

/// `LeoFileAccessBackend` over the local filesystem: FileManager for
/// listings, POSIX calls where the contract needs exact semantics
/// (`O_EXCL` temp creation, `fchmod`, `fsync`, atomic `rename(2)`,
/// nanosecond `stat` times).
struct LeoLocalFileBackend: LeoFileAccessBackend {
    private static let readChunkSize = 64 * 1024

    func stat(_ path: String) async throws -> LeoFileStat {
        try Self.status(of: path, followingLinks: true)
    }

    func lstat(_ path: String) async throws -> LeoFileStat {
        try Self.status(of: path, followingLinks: false)
    }

    func realpath(_ path: String) async throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw Self.error(errno, path: path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func homeDirectory() async throws -> String {
        NSHomeDirectory()
    }

    func entries(of directory: String) async throws -> [LeoFileEntry] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            throw Self.error(error, path: directory)
        }
        return try names.compactMap { name in
            let path = (directory as NSString).appendingPathComponent(name)
            do {
                let stat = try Self.status(of: path, followingLinks: false)
                return LeoFileEntry(name: name, kind: stat.kind, size: stat.size, modified: stat.modified)
            } catch LeoFileAccessError.notFound {
                return nil // Removed between the listing and its lstat.
            }
        }
    }

    func contents(of path: String, limit: UInt64) async throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.error(errno, path: path) }
        defer { Darwin.close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: Self.readChunkSize)
        while UInt64(data.count) <= limit {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.error(errno, path: path)
            }
            data.append(buffer, count: count)
        }
        return data
    }

    /// Opened `0600` when `permissions` will be applied afterwards (so the
    /// file is never briefly more open than the original), otherwise `0666`
    /// filtered by the umask like any new file.
    func create(_ path: String, data: Data, permissions: UInt16?) async throws {
        let initialMode: mode_t = permissions == nil ? 0o666 : 0o600
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, initialMode)
        guard descriptor >= 0 else { throw Self.error(errno, path: path) }
        do {
            try Self.writeAll(data, to: descriptor, path: path)
            if let permissions, fchmod(descriptor, mode_t(permissions)) != 0 { throw Self.error(errno, path: path) }
            if fsync(descriptor) != 0 { throw Self.error(errno, path: path) }
        } catch {
            Darwin.close(descriptor)
            unlink(path)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            let failure = Self.error(errno, path: path)
            unlink(path)
            throw failure
        }
    }

    func remove(_ path: String) async throws {
        guard unlink(path) == 0 else { throw Self.error(errno, path: path) }
    }

    func replace(_ destination: String, with source: String) async throws {
        guard Darwin.rename(source, destination) == 0 else {
            let failure = Self.error(errno, path: destination)
            unlink(source)
            throw failure
        }
    }

    // MARK: - POSIX helpers

    private static func status(of path: String, followingLinks: Bool) throws -> LeoFileStat {
        var info = Darwin.stat()
        // fstatat, not stat(2): in Swift `stat(...)` resolves to the struct.
        let flags = followingLinks ? 0 : AT_SYMLINK_NOFOLLOW
        guard fstatat(AT_FDCWD, path, &info, flags) == 0 else { throw error(errno, path: path) }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return LeoFileStat(
            kind: LeoFileKind(mode: UInt32(info.st_mode)),
            size: UInt64(max(0, info.st_size)),
            modified: Date(timeIntervalSince1970: modified),
            permissions: UInt16(info.st_mode & 0o7777)
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw error(errno, path: path)
                }
                offset += written
            }
        }
    }

    /// Mirrors OpenSSH sftp-server's `errno_to_portable`, so a local failure
    /// and the same failure over SFTP surface as the same case.
    static func error(_ code: Int32, path: String) -> LeoFileAccessError {
        switch code {
        case ENOENT, ENOTDIR, ELOOP, EBADF: .notFound(path: path)
        case EACCES, EPERM: .permissionDenied(path: path)
        case EISDIR: .isADirectory(path: path)
        default: .failed(path: path, reason: "\(verbatim: String(cString: strerror(code)))")
        }
    }

    /// Foundation's description embeds the raw file name, so it is
    /// untrusted.
    static func error(_ error: Error, path: String) -> LeoFileAccessError {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Self.error(Int32(underlying.code), path: path)
        }
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound(path: path)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permissionDenied(path: path)
        default: return .failed(path: path, reason: .untrusted(nsError.localizedDescription))
        }
    }
}
