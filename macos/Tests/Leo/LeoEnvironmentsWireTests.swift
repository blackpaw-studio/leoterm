import Foundation
import Testing

@testable import Ghostty

/// B-283: the named-environment fields, decoded in one place. Names only;
/// an env value never reaches the app.
struct LeoEnvironmentsWireTests {
    private func observed(_ json: String) throws -> LeoObservedAgent {
        try JSONDecoder().decode(LeoObservedAgent.self, from: Data(json.utf8))
    }

    private func event(_ json: String) -> LeoObserveEvent? {
        LeoActivityClient.decode(LeoSSEEvent(name: nil, data: json, id: nil))
    }

    @Test func decodesObservedAgentEnvironments() throws {
        let override = try observed(#"{"name":"a","environments":["zeta","alpha"],"environments_source":"override","environment_error":"environment \"gone\" is not configured"}"#)
        #expect(override.environments == LeoAgentEnvironments(names: ["zeta", "alpha"], source: .override, error: #"environment "gone" is not configured"#))
        let fallback = try observed(#"{"name":"a","environments":[],"environments_source":"default","environment_error":null}"#)
        #expect(fallback.environments == LeoAgentEnvironments(names: [], source: .default, error: nil))
        #expect(try observed(#"{"name":"a"}"#).environments == nil)
        // A malformed value never fails /state; it reads as not reported.
        let malformed = try observed(#"{"name":"a","status":"running","environments":"oops","environments_source":7}"#)
        #expect(malformed.status == .running)
        #expect(malformed.environments == nil)
        let state = try JSONDecoder().decode(LeoObservedState.self, from: Data(#"{"agents":[{"name":"a","environments":{"x":1}},{"name":"b"}]}"#.utf8))
        #expect(state.agents.map(\.name) == ["a", "b"])
    }

    @Test func lifecycleStateChangeHasNoPatch() {
        let decoded = event(#"{"type":"agent_state_changed","seq":3,"agent":"a","status":"starting"}"#)
        guard case .agentStateChanged(_, _, let agent, let status, _, _, let patch) = decoded else {
            Issue.record("not a state change: \(String(describing: decoded))")
            return
        }
        #expect(agent == "a")
        #expect(status == .starting)
        #expect(patch == nil)
    }

    @Test func setEnvironmentEventClearsWithExplicitNull() {
        let decoded = event(#"{"type":"agent_state_changed","seq":4,"agent":"a","environments":[],"environments_source":"default","environment_error":null}"#)
        guard case .agentStateChanged(_, _, _, _, _, _, let patch) = decoded, let patch else {
            Issue.record("no patch: \(String(describing: decoded))")
            return
        }
        #expect(patch == LeoAgentEnvironmentsPatch(names: .set([]), source: .set(.default), error: .cleared))
        let before = LeoAgentEnvironments(names: ["x"], source: .override, error: "gone")
        #expect(patch.applied(to: before) == LeoAgentEnvironments(names: [], source: .default, error: nil))
    }

    @Test func absentPatchFieldsLeaveValuesUnchanged() {
        let patch = LeoAgentEnvironmentsPatch(names: .unchanged, source: .unchanged, error: .set("gone"))
        let before = LeoAgentEnvironments(names: ["x", "y"], source: .override, error: nil)
        #expect(patch.applied(to: before) == LeoAgentEnvironments(names: ["x", "y"], source: .override, error: "gone"))
    }

    @Test func agentSpawnedCarriesEnvironments() {
        let decoded = event(#"{"type":"agent_spawned","seq":5,"agent":{"name":"a","environments":["one","two"],"environments_source":"override","environment_error":null}}"#)
        guard case .agentSpawned(_, _, let agent, _, let patch) = decoded else {
            Issue.record("not a spawn: \(String(describing: decoded))")
            return
        }
        #expect(agent.name == "a")
        #expect(patch == LeoAgentEnvironmentsPatch(names: .set(["one", "two"]), source: .set(.override), error: .cleared))
    }

    @Test func decodesCatalogNamesAndTemplateDefaults() throws {
        let names = try LeoEnvironmentsWire.catalogNames(Data(#"{"ok":true,"data":[{"name":"prod"},{"name":"aws"}]}"#.utf8))
        #expect(names == ["aws", "prod"])
        let defaults = try LeoEnvironmentsWire.templateDefaults(Data(#"{"ok":true,"data":[{"name":"claude","harness":"claude","model":"opus","environments":["aws","prod"]},{"name":"bare","environments":[]},{"name":"old"}]}"#.utf8))
        #expect(defaults == ["claude": ["aws", "prod"], "bare": [], "old": []])
    }
}
