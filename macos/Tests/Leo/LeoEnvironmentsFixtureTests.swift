#if DEBUG
import Foundation
import Testing

@testable import Ghostty

/// B-283: the fixture file's `environments` key advertises the feature,
/// overlays rows' fields, and answers every environment route (and spawn)
/// itself, so nothing it drives reaches a real daemon.
struct LeoEnvironmentsFixtureTests {
    private static let json = #"""
    {"environments": {
      "names": ["prod", "aws", "dev"],
      "templates": {"claude": ["aws", "prod"]},
      "agents": {
        "autopilot-scratch": {"environments": ["prod", "aws"], "environments_source": "override", "environment_error": null},
        "broken": {"environments": ["gone"], "environments_source": "override", "environment_error": "environment \"gone\" is not configured"}
      },
      "set": {"code": "persistent_task", "error": "autopilot-scratch runs a persistent task"},
      "spawn_error": {"code": "unknown_environment", "error": "unknown environment \"dev\""}
    }}
    """#

    private func file() throws -> LeoAttentionFixture.File {
        try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(Self.json.utf8))
    }

    @Test func environmentsKeyAdvertisesFeature() async throws {
        let fixture = try #require(try file().environments)
        #expect(fixture.agents["broken"]?.error == #"environment "gone" is not configured"#)
        let (stream, continuation) = AsyncStream<LeoObserveEvent>.makeStream()
        continuation.yield(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "b", features: []))
        continuation.finish()
        var seen: [LeoObserveEvent] = []
        for await event in LeoAttentionFixture.advertising(stream, usage: false, turns: [:], environments: true) { seen.append(event) }
        guard case .hello(_, _, _, _, _, let features) = seen.first else { Issue.record("no hello"); return }
        #expect(features == ["agent_environments"])

        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, observedState: {
            LeoObservedState(agents: [LeoObservedAgent(name: "autopilot-scratch", status: .running, activity: nil, currentAction: nil, lastActivityAt: nil)])
        })
        let state = try await LeoAttentionFixture.wrap(base, overlay: [:], environments: fixture).fetchState()
        #expect(state.agents.first?.environments == LeoAgentEnvironments(names: ["prod", "aws"], source: .override, error: nil))
    }

    @Test func environmentsFixtureAnswersLocally() async throws {
        let fixture = try #require(try file().environments)
        let base = FixtureBaseTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: LeoEnvironmentsFixtureTransport(base: base, fixture: fixture))
        let catalog = try await client.environmentCatalog()
        #expect(catalog == LeoEnvironmentCatalog(names: ["aws", "dev", "prod"], templateDefaults: ["claude": ["aws", "prod"]]))
        await #expect { try await client.setEnvironments("autopilot-scratch", names: []) } throws: { error in
            (error as? LeoDaemonError) == .daemon(code: "persistent_task", message: "autopilot-scratch runs a persistent task", matches: [])
        }
        await #expect { _ = try await client.spawn(LeoSpawnRequest(template: "claude")) } throws: { error in
            (error as? LeoDaemonError)?.errorDescription == #"unknown environment "dev""#
        }
        _ = try await client.listAgents()
        #expect(await base.paths == ["/agents/list"])
    }

    @Test func setDefaultsToOkAndSpawnNeverPassesThrough() async throws {
        let fixture = try #require(try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(#"{"environments":{"names":["a"]}}"#.utf8)).environments)
        let base = FixtureBaseTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: LeoEnvironmentsFixtureTransport(base: base, fixture: fixture))
        try await client.setEnvironments("autopilot-scratch", names: ["a"])
        await #expect(throws: LeoDaemonError.self) { _ = try await client.spawn(LeoSpawnRequest(template: "claude")) }
        #expect(await base.paths.isEmpty)
    }
}

private actor FixtureBaseTransport: LeoDaemonTransport {
    private(set) var paths: [String] = []

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        paths.append(request.path)
        return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true,"data":[]}"#.utf8))
    }
}
#endif
