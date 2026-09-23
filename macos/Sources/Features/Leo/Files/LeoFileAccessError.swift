import Foundation

/// Every failure `LeoFileAccess` reports, local or remote. The UI shows
/// `localizedDescription` (and `recoverySuggestion`, when present) as is.
enum LeoFileAccessError: Error, Equatable, Sendable {
    case notFound(path: String)
    case permissionDenied(path: String)
    /// The file changed on disk since the version the caller read.
    case conflict(path: String)
    case tooLarge(path: String, size: UInt64, limit: UInt64)
    case notADirectory(path: String)
    case isADirectory(path: String)
    /// Not an absolute path (or contains a NUL byte).
    case invalidPath(String)
    /// The SFTP session ended (or could not start): the tunnel is down or
    /// the server exited.
    case disconnected
    /// The server spoke something other than well-formed SFTP v3.
    case protocolError(String)
    /// Any other operating-system or server failure (disk full, read-only
    /// volume, an SFTP "Failure" or an operation the server doesn’t support).
    case failed(path: String, reason: String)
    /// File access can't work for this host at all, though its tunnel may
    /// (e.g. the tunnel runs without the ControlMaster SFTP needs).
    case unavailable(reason: String)

    /// The same error about `path` instead -- used when an operation on an
    /// internal temp file fails, so the user sees the file they saved.
    func retargeted(to path: String) -> LeoFileAccessError {
        switch self {
        case .notFound: .notFound(path: path)
        case .permissionDenied: .permissionDenied(path: path)
        case .conflict: .conflict(path: path)
        case let .tooLarge(_, size, limit): .tooLarge(path: path, size: size, limit: limit)
        case .notADirectory: .notADirectory(path: path)
        case .isADirectory: .isADirectory(path: path)
        case let .failed(_, reason): .failed(path: path, reason: reason)
        case .invalidPath, .disconnected, .protocolError, .unavailable: self
        }
    }

    /// Wraps anything that is not already a `LeoFileAccessError`.
    static func wrapping(_ error: Error, path: String) -> LeoFileAccessError {
        (error as? LeoFileAccessError) ?? .failed(path: path, reason: error.localizedDescription)
    }
}

extension LeoFileAccessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .notFound(path): "“\(Self.displayName(path))” couldn’t be found."
        case let .permissionDenied(path): "You don’t have permission to access “\(Self.displayName(path))”."
        case let .conflict(path): "“\(Self.displayName(path))” changed on disk after it was opened."
        case let .tooLarge(path, size, limit):
            "“\(Self.displayName(path))” is too large to open (\(Self.bytes(size)); the limit is \(Self.bytes(limit)))."
        case let .notADirectory(path): "“\(Self.displayName(path))” isn’t a folder."
        case let .isADirectory(path): "“\(Self.displayName(path))” is a folder."
        case let .invalidPath(path): "“\(path)” isn’t an absolute path."
        case .disconnected: "The connection to the host was lost."
        case let .protocolError(detail): "The file server sent an unexpected response (\(detail))."
        case let .failed(path, reason): "Couldn’t access “\(Self.displayName(path))”: \(reason)."
        case let .unavailable(reason): "File access unavailable: \(reason)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .conflict: "Reload to see the current version, or save again to replace it."
        case .disconnected: "Reconnect to the host, then try again."
        case .unavailable: "The host’s agents still work; only browsing and editing its files is affected."
        default: nil
        }
    }

    private static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
