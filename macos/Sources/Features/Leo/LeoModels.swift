import Foundation

/// Lifecycle status of an agent as reported by the daemon. Activity status
/// (working/idle/needs-you) is a Phase 5 concept derived from the cell's tmux
/// stream, not from here.
enum AgentStatus: String, Codable, Sendable, Equatable {
    case running
    case stopped

    /// Decode tolerantly: any unrecognized status is treated as stopped so a
    /// future daemon value never crashes the sidebar.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .stopped
    }
}

/// A Leo agent as enumerated by `GET /agents/list`.
struct Agent: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let template: String
    let repo: String
    let workspace: String
    let status: AgentStatus
    let startedAt: String
    let env: [String: String]

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, template, repo, workspace, status, env
        case startedAt = "started_at"
    }
}

/// A spawn template from `leo template list --json`.
struct Template: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let workspace: String
    var id: String { name }
}

/// The daemon's response envelope: `{ "ok": bool, "error": string?, "data": T? }`.
struct LeoEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let data: T?

    /// Decode an envelope from raw bytes, mapping JSON failures to `LeoError.decode`.
    static func decode(_ bytes: Data) throws(LeoError) -> LeoEnvelope<T> {
        do {
            return try JSONDecoder().decode(LeoEnvelope<T>.self, from: bytes)
        } catch {
            throw LeoError.decode(detail: String(describing: error))
        }
    }

    /// Unwrap `data`, throwing `LeoError.daemon` when `ok == false` and
    /// `LeoError.decode` when `ok == true` but `data` is missing.
    func value() throws(LeoError) -> T {
        guard ok else { throw LeoError.daemon(message: error ?? "unknown daemon error") }
        guard let data else { throw LeoError.decode(detail: "missing data field") }
        return data
    }

    /// Assert the daemon reported success; ignore `data`. For void endpoints
    /// (stop/prune) that may legitimately omit `data`.
    func expectOK() throws(LeoError) {
        guard ok else { throw LeoError.daemon(message: error ?? "unknown daemon error") }
    }
}
