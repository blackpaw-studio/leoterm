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

    @Test func decodesTemplateArrayWithSupersetFields() throws {
        // leo v0.19's `template list --json` adds `model`/`agent`; extra keys
        // must not break decoding of the fields we care about.
        let json = Data(#"[{"name":"coding","model":"opus","agent":"claude","workspace":"/w"}]"#.utf8)
        let templates = try JSONDecoder().decode([Template].self, from: json)
        #expect(templates.map(\.name) == ["coding"])
    }

    @Test func envelopeWithOkFalseCarriesStructuredCode() {
        let json = Data(#"{"ok":false,"error":"no such agent","code":"not_found"}"#.utf8)
        #expect(throws: LeoError.daemon(message: "no such agent", code: "not_found")) {
            _ = try LeoEnvelope<[Agent]>.decode(json).value()
        }
    }

    // MARK: - decodeRoster (leo v0.19 real-shape fixture)

    /// Based on a real `GET /agents/list` response: no `env` field at all,
    /// `repo` absent for workspace-only agents, and `starting` as a live
    /// transient status alongside `running`/`stopped`.
    private static let realShapeFixture = Data("""
    {"ok":true,"data":[
      {"name":"olympus","template":"claude","repo":"blackpaw-studio/olympus",
       "workspace":"/Users/evan/.leo/agents/olympus","status":"running",
       "started_at":"2026-06-10T10:01:27.860901-04:00","wake_on_message":true},
      {"name":"assistant","template":"assistant",
       "workspace":"/Users/evan/.leo/workspace","status":"starting",
       "started_at":"2026-08-28T08:31:19.048814-04:00","restarts":1},
      {"name":"broken","template":"claude","workspace":42,
       "status":"stopped","started_at":"t"}
    ]}
    """.utf8)

    @Test func decodeRosterDefaultsRepoToEmptyStringWhenAbsent() throws {
        let agents = try Agent.decodeRoster(from: Self.realShapeFixture)
        let assistant = try #require(agents.first { $0.name == "assistant" })
        #expect(assistant.repo == "")
        #expect(assistant.env == [:])
    }

    @Test func decodeRosterDecodesStartingStatus() throws {
        let agents = try Agent.decodeRoster(from: Self.realShapeFixture)
        let assistant = try #require(agents.first { $0.name == "assistant" })
        #expect(assistant.status == .starting)
    }

    @Test func decodeRosterSkipsMalformedRecordButKeepsRest() throws {
        // "broken" has `workspace: 42` (not a string) — it should be skipped,
        // not fail the whole roster.
        let agents = try Agent.decodeRoster(from: Self.realShapeFixture)
        #expect(agents.map(\.name).sorted() == ["assistant", "olympus"])
    }

    @Test func decodeRosterKeepsFullyPopulatedRecordsIntact() throws {
        let agents = try Agent.decodeRoster(from: Self.realShapeFixture)
        let olympus = try #require(agents.first { $0.name == "olympus" })
        #expect(olympus.repo == "blackpaw-studio/olympus")
        #expect(olympus.status == .running)
        #expect(olympus.workspace == "/Users/evan/.leo/agents/olympus")
    }

    @Test func decodeRosterTreatsNullDataAsEmptyRoster() throws {
        // Go's json.Marshal renders a nil slice as `null`; leo's list handler
        // guards against that today (see internal/daemon/handlers_agents.go),
        // but decoding must tolerate it defensively rather than erroring.
        let json = Data(#"{"ok":true,"data":null}"#.utf8)
        let agents = try Agent.decodeRoster(from: json)
        #expect(agents.isEmpty)
    }

    @Test func decodeRosterThrowsOnEnvelopeFailure() {
        let json = Data(#"{"ok":false,"error":"unavailable","code":"not_found"}"#.utf8)
        #expect(throws: LeoError.daemon(message: "unavailable", code: "not_found")) {
            _ = try Agent.decodeRoster(from: json)
        }
    }
}
