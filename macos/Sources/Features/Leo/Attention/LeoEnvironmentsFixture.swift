#if DEBUG
import Foundation

/// DEBUG builds only: the `"environments"` key of the `LEO_ATTENTION_FIXTURE`
/// file (B-283), so named environments can be seen before leo PR #251 ships:
///
///     {"environments": {
///       "names": ["aws", "prod"],                      // GET /environments
///       "templates": {"claude": ["aws"]},              // GET /templates defaults
///       "agents": {"alpha": {"environments": ["prod"], "environments_source": "override",
///                            "environment_error": null}},   // overlaid on /state
///       "set": "ok" | {"code": "persistent_task", "error": "…", "status": 409},
///       "spawn_error": {"code": "unknown_environment", "error": "…"}
///     }}
///
/// Hello advertises `agent_environments`. The environment routes and spawn
/// are answered here and never reach a daemon: `set` defaults to ok, and a
/// spawn without `spawn_error` is refused, so pressing Create is safe.
struct LeoEnvironmentsFixture: Equatable, Sendable {
    struct Reply: Equatable, Sendable {
        let status: Int
        let body: Data

        static let ok = Reply(status: 200, body: Data(#"{"ok":true}"#.utf8))
        static let spawnRefused = Reply.error(code: "fixture", message: "Spawning is disabled by the environments fixture")

        static func error(code: String, message: String, status: Int? = nil) -> Reply {
            let object = ["ok": false, "code": code, "error": message] as [String: Any]
            let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return Reply(status: status ?? defaultStatus(code), body: body)
        }

        static func defaultStatus(_ code: String) -> Int {
            switch code {
            case "persistent_task", "harness_mismatch": 409
            case "forbidden": 403
            case "internal": 500
            default: 400
            }
        }
    }

    let names: [String]
    let templates: [String: [String]]
    let agents: [String: LeoAgentEnvironments]
    let set: Reply
    let spawn: Reply
}

extension LeoEnvironmentsFixture: Decodable {
    private struct FixtureError: Decodable {
        let code: String?
        let error: String?
        let status: Int?
        var reply: Reply { .error(code: code ?? "fixture", message: error ?? "Refused by the environments fixture", status: status) }
    }

    /// A per-agent entry, read by the app's one wire decoder.
    private struct Agent: Decodable {
        let value: LeoAgentEnvironments?
        init(from decoder: any Decoder) throws { value = LeoEnvironmentsWire.agent(from: decoder) }
    }

    private enum Keys: String, CodingKey {
        case names, templates, agents, set
        case spawnError = "spawn_error"
    }

    /// Every part is lenient: a malformed one reads as absent.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        names = (try? container.decode([String].self, forKey: .names)) ?? []
        templates = (try? container.decode([String: [String]].self, forKey: .templates)) ?? [:]
        agents = ((try? container.decode([String: Agent].self, forKey: .agents)) ?? [:]).compactMapValues(\.value)
        set = (try? container.decode(FixtureError.self, forKey: .set))?.reply ?? .ok
        spawn = (try? container.decode(FixtureError.self, forKey: .spawnError))?.reply ?? .spawnRefused
    }

    func response(to request: LeoHTTPRequest) -> LeoHTTPResponse? {
        let reply: Reply
        switch (request.method, request.path) {
        case ("GET", LeoEnvironmentsWire.catalogRoute):
            reply = Self.data(names.map { ["name": $0] })
        case ("GET", LeoEnvironmentsWire.templatesRoute):
            reply = Self.data(templates.keys.sorted().map { ["name": $0, LeoEnvironmentsWire.namesKey: templates[$0] ?? []] })
        case ("POST", "/agents/spawn"):
            reply = spawn
        case ("POST", let path) where path.hasPrefix("/agents/") && path.hasSuffix("/" + LeoEnvironmentsWire.agentAction):
            reply = set
        default:
            return nil
        }
        return LeoHTTPResponse(status: reply.status, body: reply.body)
    }

    private static func data(_ value: Any) -> Reply {
        let body = (try? JSONSerialization.data(withJSONObject: ["ok": true, "data": value], options: [.sortedKeys])) ?? Data()
        return Reply(status: 200, body: body)
    }
}

struct LeoEnvironmentsFixtureTransport: LeoDaemonTransport {
    let base: any LeoDaemonTransport
    let fixture: LeoEnvironmentsFixture

    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        if let response = fixture.response(to: request) { return response }
        return try await base.send(request, socketPath: socketPath, timeout: timeout)
    }
}
#endif
