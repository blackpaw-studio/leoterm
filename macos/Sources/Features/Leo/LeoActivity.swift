import Foundation
import os

/// Per-agent activity signal, as reported by the Leo daemon's local
/// observability endpoint (`GET /api/v1/state`, `GET /api/v1/events`).
/// This is orthogonal to `AgentStatus` (running/stopped/starting): a running
/// agent can be `.working` or `.idle`, and a stopped/unreachable agent is
/// always `.unknown`.
enum AgentActivity: String, Codable, Sendable, Equatable {
    case working
    case idle
    case unknown

    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-activity")

    /// Decode tolerantly: any unrecognized activity value is treated as
    /// `.unknown` so a future daemon value never crashes the sidebar. The
    /// unknown raw value is logged so it doesn't disappear silently.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = AgentActivity(rawValue: raw) {
            self = known
        } else {
            Self.logger.warning("unknown agent activity \(raw, privacy: .public); treating as unknown")
            self = .unknown
        }
    }
}
