import Darwin
import Foundation

/// A directory this process reserves atomically with `mkdtemp` -- created
/// fresh and owner-only, so it is never one another run or worker already
/// uses -- and the only directory `removeIfReserved` will ever remove.
final class LeoReservedTestDirectory: @unchecked Sendable {
    /// A path ending in `X`s, which `mkdtemp` replaces.
    let template: String
    private let lock = NSLock()
    private var reserved: URL?

    init(template: String) {
        self.template = template
    }

    /// Reserves the directory on first call; later calls return it.
    func reserve() throws -> URL {
        try lock.withLock {
            if let reserved { return reserved }
            var path = Array(template.utf8CString)
            guard mkdtemp(&path) != nil else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            reserved = directory
            return directory
        }
    }

    /// Removes the reserved directory, if this instance reserved one.
    func removeIfReserved() {
        lock.withLock {
            guard let reserved else { return }
            try? FileManager.default.removeItem(at: reserved)
            self.reserved = nil
        }
    }
}
