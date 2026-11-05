import Foundation
import Testing

@testable import LeoKit

/// The daemon's additive `display_name` (leo >= 0.66.0): shown to the user,
/// while `name` stays the identifier.
struct LeoAgentDisplayNameTests {
    private func observed(_ json: String) throws -> LeoObservedAgent {
        try JSONDecoder().decode(LeoObservedAgent.self, from: Data(json.utf8))
    }

    private func agent(_ json: String) throws -> LeoAgent {
        try JSONDecoder().decode(LeoAgent.self, from: Data(json.utf8))
    }

    @Test func observedAgentShowsDisplayNameWhenPresent() throws {
        let a = try observed(#"{"name":"alfred-itunes-dj","display_name":"Alfred"}"#)
        #expect(a.displayName == "Alfred")
        #expect(a.name == "alfred-itunes-dj")
    }

    @Test func observedAgentFallsBackToNameForOlderDaemons() throws {
        #expect(try observed(#"{"name":"alpha"}"#).displayName == "alpha")
    }

    @Test func emptyOrBlankDisplayNameFallsBackToName() throws {
        #expect(try observed(#"{"name":"alpha","display_name":""}"#).displayName == "alpha")
        #expect(try observed(#"{"name":"alpha","display_name":"  "}"#).displayName == "alpha")
        #expect(try observed(#"{"name":"alpha","display_name":null}"#).displayName == "alpha")
    }

    @Test func malformedDisplayNameNeverFailsState() throws {
        let a = try observed(#"{"name":"alpha","display_name":7,"status":"running"}"#)
        #expect(a.displayName == "alpha")
        #expect(a.status == .running)
    }

    @Test func agentModelDecodesDisplayNameAndFallsBack() throws {
        #expect(try agent(#"{"name":"alpha","display_name":"Alpha!"}"#).displayName == "Alpha!")
        #expect(try agent(#"{"name":"alpha"}"#).displayName == "alpha")
        #expect(try agent(#"{"name":"alpha","display_name":""}"#).displayName == "alpha")
    }

    @Test func spawnedEventCarriesDisplayNameAndKeepsIdentityOnName() {
        let raw = LeoSSEEvent(name: nil, data: #"{"type":"agent_spawned","seq":5,"agent":{"name":"alpha","display_name":"Alpha"}}"#, id: nil)
        guard case .agentSpawned(_, _, let agent, _, _) = LeoActivityClient.decode(raw) else {
            Issue.record("not a spawn")
            return
        }
        #expect(agent.displayName == "Alpha")
        #expect(agent.id == "alpha")
    }

    /// A rename arrives as departure + spawn under a new `name`; the same
    /// name with a new display name is the same agent.
    @Test func identityStaysOnNameWhenDisplayNameChanges() throws {
        let before = try agent(#"{"name":"alpha","display_name":"Old"}"#)
        let after = try agent(#"{"name":"alpha","display_name":"New"}"#)
        #expect(before.id == after.id)
        #expect(before.displayName != after.displayName)
    }
}
