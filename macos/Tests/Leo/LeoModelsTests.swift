import Foundation
import Testing

@testable import Ghostty

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

    @Test func mapsErrorEnvelopeIncludingMatches() throws {
        let data = Data(#"{"ok":false,"error":"ambiguous agent","code":"ambiguous","matches":["one","two"]}"#.utf8)
        let envelope = try LeoDaemonEnvelope<LeoAgent>.decode(data)
        #expect(throws: LeoDaemonError.daemon(code: "ambiguous", message: "ambiguous agent", matches: ["one", "two"])) {
            try envelope.value()
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }
}
