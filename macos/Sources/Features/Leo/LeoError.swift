import Foundation

/// Errors surfaced by the Leo daemon integration layer.
enum LeoError: Error, Equatable, LocalizedError {
    /// The daemon socket could not be reached (not running, wrong path, refused).
    case daemonUnreachable
    /// The daemon returned an `{ok:false}` envelope or non-2xx status. `code`
    /// is the daemon's structured error identifier (`not_found`, `ambiguous`,
    /// `agent_still_running`, …) when present, so callers can branch on it
    /// without parsing the human-readable message.
    case daemon(message: String, code: String? = nil)
    /// The response body could not be decoded into the expected shape.
    case decode(detail: String)
    /// An agent name failed local validation before a request path was built
    /// from it (defense against path traversal via unescaped separators).
    case invalidAgentName(String)

    var errorDescription: String? {
        switch self {
        case .daemonUnreachable: return "The Leo daemon is not reachable."
        case .daemon(let message, _): return "Leo daemon error: \(message)"
        case .decode(let detail): return "Could not read the daemon response: \(detail)"
        case .invalidAgentName(let name): return "Invalid agent name: \(name)"
        }
    }

    /// The daemon's structured error identifier, when this is a `.daemon`
    /// error and the daemon reported one.
    var code: String? {
        guard case .daemon(_, let code) = self else { return nil }
        return code
    }
}
