import Darwin
import Foundation

/// Where a streaming read pushes a file's bytes: the push counterpart of
/// `LeoFileByteSource`. A read pushes each bounded piece once, in order, so
/// downloading a large file never holds more than a window in memory.
protocol LeoFileByteSink: Sendable {
    /// Keeps `data`, which starts `offset` bytes into the file. Pushes
    /// arrive in order and never overlap.
    func write(_ data: Data, at offset: UInt64) async throws
}

/// A local file written by `pwrite` through a descriptor it owns, closed on
/// `finish` or, failing that, on deinit. Errors name `path` -- the file the
/// user sees, not a staging name.
final class LeoFileDescriptorSink: LeoFileByteSink, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private let path: String

    init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    deinit {
        if let descriptor { Darwin.close(descriptor) }
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        try lock.withLock {
            guard let descriptor else { throw LeoFileAccessError.closed }
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var written = 0
                while written < buffer.count {
                    let count = pwrite(descriptor, buffer.baseAddress! + written, buffer.count - written, off_t(offset) + off_t(written))
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw LeoLocalFileBackend.error(errno, path: path)
                    }
                    written += count
                }
            }
        }
    }

    /// Sets exactly `permissions`, flushes the bytes to disk and closes the
    /// descriptor, so a file published after this is complete.
    func finish(permissions: UInt16) throws {
        try lock.withLock {
            guard let descriptor else { throw LeoFileAccessError.closed }
            self.descriptor = nil
            var failure: Int32?
            if fchmod(descriptor, mode_t(permissions)) != 0 { failure = errno }
            if failure == nil, fsync(descriptor) != 0 { failure = errno }
            if Darwin.close(descriptor) != 0, failure == nil { failure = errno }
            if let failure { throw LeoLocalFileBackend.error(failure, path: path) }
        }
    }
}
