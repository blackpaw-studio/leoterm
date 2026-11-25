import Foundation
import Testing

@testable import LeoKit

struct LeoAgentBriefTests {
    private static let now = Date(timeIntervalSince1970: 1_795_539_600)
    private let decoder = JSONDecoder()

    private func agent(_ extra: String) throws -> LeoObservedAgent {
        try decoder.decode(LeoObservedAgent.self, from: Data(#"{"name":"zeus"\#(extra)}"#.utf8))
    }

    @Test func decodesABriefOnAnAgentEntry() throws {
        let json = #","brief":{"goal":"Ship it","status":"Testing","decisions":["a","b"],"open":["c"],"updated_at":"2026-11-25T02:00:00Z"}"#
        let brief = try #require(try agent(json).brief)
        #expect(brief.goal == "Ship it")
        #expect(brief.status == "Testing")
        #expect(brief.decisions == ["a", "b"])
        #expect(brief.open == ["c"])
        #expect(brief.updatedAt == LeoAgentBriefWire.date("2026-11-25T02:00:00Z"))
    }

    @Test func anEntryWithoutABriefHasNone() throws {
        #expect(try agent("").brief == nil)
    }

    @Test(arguments: [#","brief":"oops""#, #","brief":{"goal":5}"#, #","brief":{"decisions":"x"}"#, #","brief":[1]"#])
    func aMalformedBriefIsNilAndLeavesTheAgentIntact(_ json: String) throws {
        let decoded = try agent(json)
        #expect(decoded.brief == nil)
        #expect(decoded.name == "zeus")
    }

    @Test func aNullEventClearsTheBrief() throws {
        let data = Data(#"{"type":"agent_brief","seq":88,"agent":"zeus","brief":null}"#.utf8)
        let payload = try #require(LeoAgentBriefWire.event(data))
        #expect(payload.agent == "zeus")
        #expect(payload.brief == nil)
    }

    @Test func anEventCarriesTheBrief() throws {
        let data = Data(#"{"type":"agent_brief","seq":88,"agent":"zeus","brief":{"goal":"G"}}"#.utf8)
        #expect(LeoAgentBriefWire.event(data)?.brief?.goal == "G")
    }

    @Test func aMalformedEventPayloadIsRejected() {
        #expect(LeoAgentBriefWire.event(Data(#"{"seq":1,"agent":"zeus","brief":{"goal":5}}"#.utf8)) == nil)
        #expect(LeoAgentBriefWire.event(Data(#"{"seq":1,"brief":null}"#.utf8)) == nil)
    }

    @Test func configChangedEventDecodes() {
        #expect(LeoAgentBriefWire.configEnabled(Data(#"{"seq":89,"enabled":false}"#.utf8))?.enabled == false)
        #expect(LeoAgentBriefWire.configEnabled(Data(#"{"seq":89}"#.utf8)) == nil)
    }

    @Test func theFeatureGateReadsTheHelloFlag() {
        #expect(LeoDaemonFeatures(["agent_brief"]).contains(.agentBrief))
        #expect(!LeoDaemonFeatures.none.contains(.agentBrief))
        #expect(LeoAgentBriefWire.configResource == "brief")
    }

    // MARK: Presentation

    @Test func anEmptyBriefIsHidden() {
        let empty = LeoAgentBrief(goal: "  ", status: nil, decisions: ["", " "], open: [])
        #expect(LeoAgentBriefPresentation(brief: empty, lastActivity: nil, now: Self.now) == nil)
        #expect(LeoAgentBriefPresentation(brief: nil, lastActivity: nil, now: Self.now) == nil)
    }

    @Test func aBriefWithAnyContentShows() {
        let brief = LeoAgentBrief(status: "next step")
        #expect(LeoAgentBriefPresentation(brief: brief, lastActivity: nil, now: Self.now)?.status == "next step")
    }

    @Test(arguments: [
        (10.0, "just now"), (12 * 60.0, "12m ago"), (3 * 3600.0, "3h ago"), (2 * 86_400.0, "2d ago"), (-5.0, "just now"),
    ])
    func ageText(_ seconds: TimeInterval, _ expected: String) {
        let brief = LeoAgentBrief(goal: "g", updatedAt: Self.now.addingTimeInterval(-seconds))
        #expect(LeoAgentBriefPresentation(brief: brief, lastActivity: nil, now: Self.now)?.ageText == expected)
    }

    @Test func noUpdateTimeMeansNoAgeText() {
        #expect(LeoAgentBriefPresentation(brief: LeoAgentBrief(goal: "g"), lastActivity: nil, now: Self.now)?.ageText == nil)
    }

    @Test func stalenessBoundaryIs24HoursBehindLastActivity() {
        let day = LeoAgentBriefPresentation.staleInterval
        let updated = Self.now
        let brief = LeoAgentBrief(goal: "g", updatedAt: updated)
        func stale(activityAfter gap: TimeInterval) -> Bool? {
            LeoAgentBriefPresentation(brief: brief, lastActivity: updated.addingTimeInterval(gap), now: Self.now)?.isStale
        }
        #expect(day == 24 * 3600)
        #expect(stale(activityAfter: day) == false)
        #expect(stale(activityAfter: day + 1) == true)
        #expect(stale(activityAfter: 0) == false)
    }

    @Test func staleNeedsBothTimes() {
        let noUpdate = LeoAgentBrief(goal: "g")
        #expect(LeoAgentBriefPresentation(brief: noUpdate, lastActivity: Self.now, now: Self.now)?.isStale == false)
        let updated = LeoAgentBrief(goal: "g", updatedAt: Self.now)
        #expect(LeoAgentBriefPresentation(brief: updated, lastActivity: nil, now: Self.now)?.isStale == false)
    }
}
