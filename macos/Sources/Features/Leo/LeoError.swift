import Foundation

/// Errors surfaced by the Leo daemon integration layer.
enum LeoError: Error, Equatable, LocalizedError {
    /// The daemon socket could not be reached (not running, wrong path, refused).
    case daemonUnreachable
    /// The daemon returned an `{ok:false}` envelope or non-2xx status.
    case daemon(message: String)
    /// The response body could not be decoded into the expected shape.
    case decode(detail: String)

    var errorDescription: String? {
        switch self {
        case .daemonUnreachable: return "The Leo daemon is not reachable."
        case .daemon(let message): return "Leo daemon error: \(message)"
        case .decode(let detail): return "Could not read the daemon response: \(detail)"
        }
    }
}
