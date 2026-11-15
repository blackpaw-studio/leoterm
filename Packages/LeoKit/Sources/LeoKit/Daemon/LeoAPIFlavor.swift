import Foundation

/// The API surface a daemon on a given socket speaks. Detected once per
/// socket from `GET /health`'s `data.version`, semver-tolerantly: anything
/// `>= 0.29.0` (or any `1.x+`) speaks `.socketEvents` (unix-socket
/// `/events` SSE + `/state`); anything older, or a daemon that doesn't
/// answer with a parseable version at all, is treated as `.legacy` (TCP
/// observability, if configured, or poll-only).
public enum LeoAPIFlavor: Equatable, Sendable {
    case legacy
    case socketEvents

    public static func select(version: String) -> Self {
        guard let parsed = LeoDaemonVersion(parsing: version) else { return .legacy }
        return parsed.major > 0 || parsed.minor >= 29 ? .socketEvents : .legacy
    }
}
