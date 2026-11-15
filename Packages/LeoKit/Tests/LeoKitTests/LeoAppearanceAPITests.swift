import Foundation
import Testing

@testable import LeoKit

/// The appearance routes over both transports: the socket serves them bare,
/// the web listener under `/api/v1`. Replies are the daemon's goldens.
struct LeoAppearanceAPITests {
    static let prefixes = ["", "/api/v1"]

    /// A golden `{status, body}` as a canned reply.
    private static func transport(golden name: String) throws -> ConfigRecordingTransport {
        let object = try #require(try JSONSerialization.jsonObject(with: try LeoAppearanceWireTests.fixture(name)) as? [String: Any])
        let status = try #require(object["status"] as? Int)
        let body = try JSONSerialization.data(withJSONObject: try #require(object["body"]))
        return ConfigRecordingTransport(body: String(bytes: body, encoding: .utf8) ?? "", status: status)
    }

    private static func json(_ request: LeoHTTPRequest) throws -> NSDictionary {
        let body = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }

    @Test(arguments: prefixes)
    func readsRulesWithGet(prefix: String) async throws {
        let transport = try Self.transport(golden: "appearance-rules")
        let document = try await LeoConfigHTTPClient(prefix: prefix, transport: transport).appearanceRules()

        #expect(document.rules.map(\.summary) == ["environments contains prod", "name matches alfred-*", "template is coder"])
        #expect(document.errors.map(\.index) == [2])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "\(prefix)/appearance/rules")
        #expect(request.headers.isEmpty && request.body == nil)
    }

    @Test(arguments: prefixes)
    func replacesRulesWithIfMatch(prefix: String) async throws {
        let transport = try Self.transport(golden: "appearance-rules")
        let rules = [
            LeoAppearanceRule(field: "environments", op: "contains", value: "prod", color: "red"),
            LeoAppearanceRule(field: "name", op: "glob", value: "alfred-*", color: "pink", emoji: "🎩"),
        ]
        _ = try await LeoConfigHTTPClient(prefix: prefix, transport: transport).setAppearanceRules(rules, ifMatch: "sha256:abc")

        let request = try #require(await transport.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "\(prefix)/appearance/rules")
        #expect(request.headers == ["If-Match": "sha256:abc"])
        #expect(try Self.json(request) == [
            "rules": [
                ["when": ["field": "environments", "op": "contains", "value": "prod"], "color": "red"],
                ["when": ["field": "name", "op": "glob", "value": "alfred-*"], "color": "pink", "emoji": "🎩"],
            ],
        ])
    }

    @Test func invalidRuleMapsToItsIndexAndReason() async throws {
        let transport = try Self.transport(golden: "appearance-rule-error")
        await #expect(throws: LeoAppearanceError.invalidRule(
            index: 1,
            reason: #"color "magenta" is not in the palette (red, orange, yellow, green, teal, blue, indigo, purple, pink, gray)"#
        )) {
            _ = try await LeoConfigHTTPClient(prefix: "", transport: transport).setAppearanceRules([], ifMatch: "r1")
        }
    }

    @Test func staleRevisionIsAConflict() async throws {
        let transport = ConfigRecordingTransport(
            body: #"{"ok":false,"code":"revision_mismatch","error":"stale","data":{"revision":"sha256:new"}}"#, status: 409
        )
        await #expect(throws: LeoConfigError.conflict(currentRevision: "sha256:new")) {
            _ = try await LeoConfigHTTPClient(prefix: "/api/v1", transport: transport).setAppearanceRules([], ifMatch: "sha256:old")
        }
    }

    @Test(arguments: prefixes)
    func setsAgentAppearance(prefix: String) async throws {
        let transport = try Self.transport(golden: "appearance-agent-put")
        let result = try await LeoConfigHTTPClient(prefix: prefix, transport: transport)
            .setAgentAppearance(name: "olympus", emoji: .set("🏛️"), color: .unchanged)

        #expect(result == LeoAgentAppearanceResult(
            agent: "olympus", appearance: LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0))
        ))
        let request = try #require(await transport.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "\(prefix)/agents/olympus/appearance")
        #expect(request.headers["If-Match"] == nil)
        // Absent key: unchanged.
        #expect(try Self.json(request) == ["emoji": "🏛️"])
    }

    @Test func resetSendsExplicitNulls() async throws {
        let transport = try Self.transport(golden: "appearance-agent-put-null")
        let result = try await LeoConfigHTTPClient(prefix: "", transport: transport)
            .setAgentAppearance(name: "olympus", emoji: .cleared, color: .cleared)

        #expect(result == LeoAgentAppearanceResult(agent: "olympus", appearance: nil))
        let request = try #require(await transport.requests.first)
        #expect(try Self.json(request) == ["emoji": NSNull(), "color": NSNull()])
    }

    @Test func colorIsSentByPaletteName() async throws {
        let transport = try Self.transport(golden: "appearance-agent-put")
        _ = try await LeoConfigHTTPClient(prefix: "", transport: transport)
            .setAgentAppearance(name: "a b", emoji: .unchanged, color: .set(.indigo))

        let request = try #require(await transport.requests.first)
        #expect(request.path == "/agents/a%20b/appearance")
        #expect(try Self.json(request) == ["color": "indigo"])
    }

    @Test func invalidValueMapsToItsFieldAndReason() async throws {
        let transport = ConfigRecordingTransport(
            body: #"{"ok":false,"code":"invalid_appearance","error":"bad","data":{"field":"emoji","reason":"must be a single emoji"}}"#,
            status: 400
        )
        await #expect(throws: LeoAppearanceError.invalidValue(field: "emoji", reason: "must be a single emoji")) {
            _ = try await LeoConfigHTTPClient(prefix: "", transport: transport).setAgentAppearance(name: "a", emoji: .set("ab"), color: .unchanged)
        }
    }

    @Test func unknownAgentStaysADaemonError() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"code":"not_found","error":"no agent"}"#, status: 404)
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: "no agent", matches: [])) {
            _ = try await LeoConfigHTTPClient(prefix: "", transport: transport).setAgentAppearance(name: "a", emoji: .cleared, color: .unchanged)
        }
    }

    // MARK: - Fake

    @Test func fakeKeepsRulesWithRevisionsAndResolvesAgents() async throws {
        let fake = LeoFakeConfigClient(schema: LeoConfigSchema(resources: []))
        await fake.seedAppearance(agents: [LeoAppearanceFacts(name: "olympus", environments: ["homelab"], template: "ops", harness: "")])
        let empty = try await fake.appearanceRules()
        #expect(empty.rules.isEmpty)

        let rule = LeoAppearanceRule(field: "environments", op: "contains", value: "homelab", color: "teal")
        let saved = try await fake.setAppearanceRules([rule], ifMatch: empty.revision)
        #expect(saved.rules == [rule])
        #expect(saved.revision != empty.revision)
        await #expect(throws: LeoConfigError.conflict(currentRevision: saved.revision)) {
            _ = try await fake.setAppearanceRules([], ifMatch: empty.revision)
        }
        await #expect(throws: LeoAppearanceError.invalidRule(index: 0, reason: "value is required")) {
            _ = try await fake.setAppearanceRules([LeoAppearanceRule(field: "name", op: "is", value: "", color: "red")], ifMatch: saved.revision)
        }

        let set = try await fake.setAgentAppearance(name: "olympus", emoji: .set("🏛️"), color: .unchanged)
        #expect(set.appearance == LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0)))
        let reset = try await fake.setAgentAppearance(name: "olympus", emoji: .cleared, color: .cleared)
        #expect(reset.appearance == LeoAgentAppearance(emoji: nil, color: .teal, emojiSource: nil, colorSource: .rule(0)))
        await #expect(throws: LeoDaemonError.self) {
            _ = try await fake.setAgentAppearance(name: "ghost", emoji: .cleared, color: .unchanged)
        }
        await #expect(throws: LeoAppearanceError.invalidValue(field: "emoji", reason: #"emoji "ab" must be a single emoji (one grapheme cluster of at most 64 bytes)"#)) {
            _ = try await fake.setAgentAppearance(name: "olympus", emoji: .set("ab"), color: .unchanged)
        }
        let calls = await fake.calls
        #expect(calls.contains(.appearanceRules))
        #expect(calls.contains(.setAgentAppearance(name: "olympus", emoji: .cleared, color: .cleared)))
    }
}
