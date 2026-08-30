import Foundation
import os

/// Lifecycle status of an agent as reported by the daemon. Activity status
/// (working/idle/needs-you) is a Phase 5 concept derived from the cell's tmux
/// stream, not from here. `starting` is transient during spawn (leo v0.19+).
enum AgentStatus: String, Codable, Sendable, Equatable {
    case running
    case stopped
    case starting

    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-models")

    /// Decode tolerantly: any unrecognized status is treated as stopped so a
    /// future daemon value never crashes the sidebar. The unknown raw value is
    /// logged so it doesn't disappear silently.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = AgentStatus(rawValue: raw) {
            self = known
        } else {
            Self.logger.warning("unknown agent status \(raw, privacy: .public); treating as stopped")
            self = .stopped
        }
    }
}

/// A Leo agent as enumerated by `GET /agents/list`.
///
/// As of leo v0.19, records no longer carry `env`, and `repo` is omitted for
/// workspace-only agents (no linked git repo). Decoding tolerates the absence
/// of any of these so a leaner daemon payload never crashes the roster.
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

    init(name: String,
         template: String,
         repo: String,
         workspace: String,
         status: AgentStatus,
         startedAt: String,
         env: [String: String] = [:]) {
        self.name = name
        self.template = template
        self.repo = repo
        self.workspace = workspace
        self.status = status
        self.startedAt = startedAt
        self.env = env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        template = try container.decode(String.self, forKey: .template)
        repo = try container.decodeIfPresent(String.self, forKey: .repo) ?? ""
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace) ?? ""
        status = try container.decodeIfPresent(AgentStatus.self, forKey: .status) ?? .stopped
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

extension Agent {
    private static let rosterLogger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-models")

    /// Decode an `/agents/list` envelope tolerantly at the per-record level:
    /// one malformed agent record is skipped (with a warning) instead of
    /// failing the whole roster. Envelope-level failures (`ok:false`, a
    /// non-object envelope, a missing `data` array) still throw.
    static func decodeRoster(from bytes: Data) throws(LeoError) -> [Agent] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: bytes)
        } catch {
            throw LeoError.decode(detail: String(describing: error))
        }
        guard let envelope = object as? [String: Any] else {
            throw LeoError.decode(detail: "envelope is not a JSON object")
        }
        guard let ok = envelope["ok"] as? Bool, ok else {
            throw LeoError.daemon(message: envelope["error"] as? String ?? "unknown daemon error",
                                   code: envelope["code"] as? String)
        }
        // `data` absent entirely is a malformed envelope; `data: null` (which
        // Go's json.Marshal can emit for a nil slice) is a legitimate empty
        // roster, not a decode failure.
        guard let rawData = envelope["data"] else {
            throw LeoError.decode(detail: "missing data field")
        }
        if rawData is NSNull { return [] }
        guard let records = rawData as? [Any] else {
            throw LeoError.decode(detail: "data field is not an array")
        }
        return records.compactMap { record in
            guard JSONSerialization.isValidJSONObject(record),
                  let recordData = try? JSONSerialization.data(withJSONObject: record) else {
                rosterLogger.warning("skipping malformed agent record: not a JSON object")
                return nil
            }
            do {
                return try JSONDecoder().decode(Agent.self, from: recordData)
            } catch {
                rosterLogger.warning("skipping malformed agent record: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }
}

/// A spawn template from `leo template list --json`.
struct Template: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let workspace: String
    var id: String { name }
}

/// The daemon's response envelope: `{ "ok": bool, "error": string?, "code": string?, "data": T? }`.
/// `code` is a structured error identifier (`not_found`, `ambiguous`,
/// `agent_still_running`, …) present on error responses since leo v0.19.
struct LeoEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let code: String?
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
        guard ok else { throw LeoError.daemon(message: error ?? "unknown daemon error", code: code) }
        guard let data else { throw LeoError.decode(detail: "missing data field") }
        return data
    }

    /// Assert the daemon reported success; ignore `data`. For void endpoints
    /// (stop/delete) that may legitimately omit `data`.
    func expectOK() throws(LeoError) {
        guard ok else { throw LeoError.daemon(message: error ?? "unknown daemon error", code: code) }
    }
}
