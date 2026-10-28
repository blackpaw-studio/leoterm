import Foundation
import Testing

@testable import LeoKit

struct LeoModelsTests {
    @Test func decodesAgentListFixture() throws {
        let envelope = try LeoDaemonEnvelope<[LeoAgent]>.decode(fixture("agents_list.json"))
        #expect(envelope.ok)
        #expect(!(try envelope.value()).isEmpty)
    }

    @Test func decodesTemplateFixture() throws {
        let templates = try JSONDecoder().decode([LeoTemplate].self, from: fixture("template_list.json"))
        #expect(!templates.isEmpty)
    }

    @Test func toleratesUnknownAndMissingFields() throws {
        let data = Data(#"{"name":"future","status":"hibernating","surprise":1}"#.utf8)
        let agent = try JSONDecoder().decode(LeoAgent.self, from: data)
        #expect(agent.status == .some(.unknown("hibernating")))
        #expect(agent.template == nil)
        #expect(agent.wakeOnMessage == nil)
    }

    @Test func decodesMovedToAndMovedAt() throws {
        let data = Data(#"{"name":"alpha","status":"stopped","moved_to":"nas","moved_at":"2026-10-28T13:55:00Z"}"#.utf8)
        let agent = try JSONDecoder().decode(LeoAgent.self, from: data)
        #expect(agent.movedTo == "nas")
        #expect(agent.movedAt == "2026-10-28T13:55:00Z")
    }

    @Test func movedFieldsAreNilWhenAbsent() throws {
        let agent = try JSONDecoder().decode(LeoAgent.self, from: Data(#"{"name":"alpha"}"#.utf8))
        #expect(agent.movedTo == nil)
        #expect(agent.movedAt == nil)
    }

    @Test func decodesRestoringAsItsOwnStatusAndRoundTrips() throws {
        let data = Data(#"{"name":"booting","status":"restoring"}"#.utf8)
        let agent = try JSONDecoder().decode(LeoAgent.self, from: data)
        #expect(agent.status == .some(.restoring))
        let encoded = try JSONEncoder().encode(LeoAgentStatus.restoring)
        #expect(try JSONDecoder().decode(LeoAgentStatus.self, from: encoded) == .restoring)
    }

    @Test func daemonRestoringErrorReadsFriendly() {
        let error = LeoDaemonError.daemon(code: "daemon_restoring", message: "daemon is restoring agents", matches: [])
        #expect(error.localizedDescription == "leo is still restoring agents — try again in a moment")
    }

    @Test func agentBusyAndAgentMovedReadWithoutCLIPhrasing() {
        let busy = LeoDaemonError.daemon(code: "agent_busy", message: "agent is mid-turn; pass --force to move anyway", matches: [])
        let moved = LeoDaemonError.daemon(code: "agent_moved", message: "moved; run `leo --host nas agent attach x`", matches: [])
        #expect(busy.localizedDescription == "This agent is in the middle of a turn.")
        #expect(moved.localizedDescription == "This agent was moved to another machine.")
    }

    @Test func otherMoveCodesKeepTheDaemonMessageVerbatim() {
        let error = LeoDaemonError.daemon(code: "name_taken", message: "an agent named x-copy exists on nas", matches: [])
        #expect(error.localizedDescription == "an agent named x-copy exists on nas")
    }

    @Test func mapsErrorEnvelopeIncludingMatches() throws {
        let data = Data(#"{"ok":false,"error":"ambiguous agent","code":"ambiguous","matches":["one","two"]}"#.utf8)
        let envelope = try LeoDaemonEnvelope<LeoAgent>.decode(data)
        #expect(throws: LeoDaemonError.daemon(code: "ambiguous", message: "ambiguous agent", matches: ["one", "two"])) {
            try envelope.value()
        }
    }

    @Test func transportErrorLocalizedDescriptionIncludesTheUnderlyingMessage() {
        let error = LeoDaemonError.transport("x")
        #expect(error.localizedDescription.contains("x"))
        #expect((error as NSError).localizedDescription.contains("x"))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }
}
