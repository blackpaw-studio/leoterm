import Testing
import Foundation
@testable import Ghostty

struct LeoModelsTests {
    @Test func decodesAgentListEnvelope() throws {
        let json = Data("""
        {"ok":true,"data":[
          {"name":"olympus","template":"coding","repo":"blackpaw-studio/olympus",
           "workspace":"/Users/evan/.leo/agents/olympus","status":"running",
           "started_at":"2026-06-10T10:01:27.860901-04:00","env":{"X":"1"}},
          {"name":"plex","template":"coding","repo":"plex",
           "workspace":"/Users/evan/.leo/agents/plex","status":"stopped",
           "started_at":"2026-06-10T10:01:27.907514-04:00","env":{}}
        ]}
        """.utf8)
        let env = try LeoEnvelope<[Agent]>.decode(json)
        let agents = try env.value()
        #expect(agents.count == 2)
        #expect(agents[0].name == "olympus")
        #expect(agents[0].status == .running)
        #expect(agents[0].repo == "blackpaw-studio/olympus")
        #expect(agents[1].status == .stopped)
    }

    @Test func envelopeWithOkFalseThrowsDaemonError() {
        let json = Data(#"{"ok":false,"error":"no such agent"}"#.utf8)
        #expect(throws: LeoError.daemon(message: "no such agent")) {
            _ = try LeoEnvelope<[Agent]>.decode(json).value()
        }
    }

    @Test func unknownStatusDecodesToStopped() throws {
        let json = Data(#"{"ok":true,"data":[{"name":"a","template":"t","repo":"r","workspace":"/w","status":"weird","started_at":"2026-06-10T10:01:27Z","env":{}}]}"#.utf8)
        let agents = try LeoEnvelope<[Agent]>.decode(json).value()
        #expect(agents[0].status == .stopped)
    }

    @Test func decodesTemplateArray() throws {
        let json = Data(#"[{"name":"coding","workspace":"/Users/evan/.leo/agents"},{"name":"incident","workspace":"/Users/evan/.leo/agents"}]"#.utf8)
        let templates = try JSONDecoder().decode([Template].self, from: json)
        #expect(templates.map(\.name) == ["coding", "incident"])
    }
}
