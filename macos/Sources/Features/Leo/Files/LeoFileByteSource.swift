import Darwin
import Foundation

/// Bytes a create pulls in bounded pieces, so uploading a large file never
/// holds more than a chunk (or an SFTP window of chunks) in memory.
protocol LeoFileByteSource: Sendable {
    /// Up to `count` bytes starting at `offset`; empty means end of source.
    /// Blocking: callers run it off the main actor.
    func read(at offset: UInt64, upTo count: Int) throws -> Data
}

extension Data: LeoFileByteSource {
    func read(at offset: UInt64, upTo count: Int) throws -> Data {
        guard offset < UInt64(self.count), count > 0 else { return Data() }
        let lower = startIndex + Int(offset)
        return subdata(in: lower..<(lower + Swift.min(count, endIndex - lower)))
    }
}

/// A regular file read by `pread` from a descriptor opened exactly once
/// without following a final symlink, so a path swapped after the open can't
/// change the bytes. Owns the descriptor and closes it on deinit.
final class LeoFileDescriptorSource: LeoFileByteSource, @unchecked Sendable {
    private let descriptor: Int32

    enum OpenError: LocalizedError, Equatable {
        case notRegularFile
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notRegularFile: "Only files can be uploaded."
            case .unreadable(let reason): "This file couldn’t be read: \(LeoSFTPServerText.sanitized(reason))."
            }
        }
    }

    /// `O_NONBLOCK` so a FIFO swapped in is rejected rather than blocking
    /// the open; anything but a regular file is `.notRegularFile`.
    init(path: String) throws {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw OpenError.notRegularFile }
            throw OpenError.unreadable(String(cString: strerror(errno)))
        }
        var status = Darwin.stat()
        guard fstat(descriptor, &status) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw OpenError.unreadable(reason)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw OpenError.notRegularFile
        }
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    func read(at offset: UInt64, upTo count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        while true {
            let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
            if read >= 0 {
                data.count = read
                return data
            }
            if errno != EINTR { throw OpenError.unreadable(String(cString: strerror(errno))) }
        }
    }
}
