import Foundation
import Testing

@testable import LeoKit

struct LeoAgentUsageTelemetryTests {
    private func usage(_ json: String) throws -> LeoAgentUsage {
        try JSONDecoder().decode(LeoAgentUsage.self, from: Data(json.utf8))
    }

    private static let session = #""session":{"tokens":5,"cost_usd":0.1}"#

    /// Today's daemon payload: none of the telemetry keys.
    @Test func todaysPayloadDecodesUnchangedWithEveryNewFieldAbsent() throws {
        let decoded = try usage(#"{"session_id":"s1",\#(Self.session),"context":{"tokens":10,"window":100,"percent":10}}"#)
        #expect(decoded.model == nil)
        #expect(decoded.effort == nil)
        #expect(decoded.rateLimits.isEmpty)
        #expect(decoded.git == nil)
        #expect(decoded.context == LeoContextUsage(tokens: 10, window: 100, percent: 10))
        #expect(decoded.context?.breakdown == nil)
        #expect(decoded.context?.compactAt == nil)
    }

    @Test func theFullTelemetryPayloadDecodes() throws {
        let decoded = try usage("""
        {"session_id":"s1",\(Self.session),"model":"claude-opus-4-1","effort":"high",
         "context":{"tokens":154000,"window":200000,"percent":77,"compact_at":0.9,
           "breakdown":{"system":3000,"tools":12000,"mcp":500,"memory":1500,"messages":137000}},
         "rate_limits":[{"kind":"five_hour","percent_used":42.5,"resets_at":"2026-11-12T05:00:00Z"},
                        {"kind":"seven_day","percent_used":10,"resets_at":"2026-11-15T00:00:00.500Z"}],
         "git":{"added":120,"removed":7}}
        """)
        #expect(decoded.model == "claude-opus-4-1")
        #expect(decoded.effort == "high")
        #expect(decoded.context?.compactAt == 0.9)
        #expect(decoded.context?.breakdown == LeoContextBreakdown(system: 3000, tools: 12000, mcp: 500, memory: 1500, messages: 137_000))
        #expect(decoded.rateLimits.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(decoded.rateLimits[0].percentUsed == 42.5)
        #expect(decoded.rateLimits[0].resetsAt == Date(timeIntervalSince1970: 1_794_459_600))
        #expect(decoded.rateLimits[1].resetsAt == Date(timeIntervalSince1970: 1_794_700_800.5))
        #expect(decoded.git == LeoGitDelta(added: 120, removed: 7))
    }

    @Test func aPartialBreakdownKeepsOnlyItsValidKeys() throws {
        let decoded = try usage(#"{\#(Self.session),"context":{"tokens":1,"window":2,"percent":50,"breakdown":{"system":10,"tools":-1,"mcp":"x","bogus":4}}}"#)
        #expect(decoded.context?.breakdown == LeoContextBreakdown(system: 10))
    }

    /// Each malformed telemetry field reads as absent and never fails the usage it rides in.
    @Test(arguments: [
        ##""model":"""##, #""model":7"#, #""model":"bad\nmodel""#, #""model":"é""#,
        #""effort":["x"]"#, #""effort":"\#(String(repeating: "a", count: 65))""#,
        #""rate_limits":"x""#, #""rate_limits":{"kind":"five_hour"}"#,
        #""git":{"added":1}"#, #""git":{"added":-1,"removed":2}"#, #""git":"x""#, #""git":{"added":"a","removed":1}"#,
    ])
    func aMalformedTopLevelFieldReadsAsAbsent(_ field: String) throws {
        let decoded = try usage(#"{\#(Self.session),\#(field)}"#)
        #expect(decoded.session == LeoUsageTotals(tokens: 5, costUSD: 0.1))
        #expect(decoded.model == nil)
        #expect(decoded.effort == nil)
        #expect(decoded.rateLimits.isEmpty)
        #expect(decoded.git == nil)
    }

    @Test(arguments: [
        #""compact_at":1.5"#, #""compact_at":-0.1"#, #""compact_at":"x""#, #""compact_at":null"#,
        #""breakdown":"x""#, #""breakdown":{}"#, #""breakdown":{"system":-5}"#, #""breakdown":[1]"#,
    ])
    func aMalformedContextFieldReadsAsAbsentAndKeepsTheContext(_ field: String) throws {
        let decoded = try usage(#"{\#(Self.session),"context":{"tokens":10,"window":100,"percent":10,\#(field)}}"#)
        #expect(decoded.context == LeoContextUsage(tokens: 10, window: 100, percent: 10))
        #expect(decoded.context?.compactAt == nil)
        #expect(decoded.context?.breakdown == nil)
    }

    @Test func aBadRateLimitEntryDropsOnlyThatEntry() throws {
        let decoded = try usage("""
        {\(Self.session),"rate_limits":[
          {"kind":"monthly","percent_used":1,"resets_at":"2026-11-12T05:00:00Z"},
          {"kind":"five_hour","percent_used":-1,"resets_at":"2026-11-12T05:00:00Z"},
          {"kind":"five_hour","percent_used":5000,"resets_at":"2026-11-12T05:00:00Z"},
          "junk",
          {"kind":"seven_day","percent_used":3,"resets_at":"2026-11-12T05:00:00Z"}]}
        """)
        #expect(decoded.rateLimits.map(\.kind) == [.sevenDay])
        #expect(decoded.rateLimits.first?.percentUsed == 3)
    }

    @Test func aRateLimitPercentAbove100IsKeptBriefly() throws {
        let decoded = try usage(#"{\#(Self.session),"rate_limits":[{"kind":"five_hour","percent_used":103.2,"resets_at":"2026-11-12T05:00:00Z"}]}"#)
        #expect(decoded.rateLimits.first?.percentUsed == 103.2)
    }

    @Test func aRateLimitWithoutAResetTimeIsKeptWithANilReset() throws {
        let decoded = try usage(#"{\#(Self.session),"rate_limits":[{"kind":"five_hour","percent_used":3},{"kind":"seven_day","percent_used":4,"resets_at":"yesterday"}]}"#)
        #expect(decoded.rateLimits.map(\.percentUsed) == [3, 4])
        #expect(decoded.rateLimits.allSatisfy { $0.resetsAt == nil })
    }

    @Test func aRateLimitWithoutAResetTimeEncodesWithoutTheKey() throws {
        let original = try usage(#"{\#(Self.session),"rate_limits":[{"kind":"five_hour","percent_used":3}]}"#)
        let again = try JSONDecoder().decode(LeoAgentUsage.self, from: JSONEncoder().encode(original))
        #expect(again.rateLimits == original.rateLimits)
    }

    @Test func theRateLimitListIsCappedAtOneEntryPerKind() throws {
        let entry = #"{"kind":"five_hour","percent_used":1,"resets_at":"2026-11-12T05:00:00Z"}"#
        let decoded = try usage(#"{\#(Self.session),"rate_limits":[\#(Array(repeating: entry, count: 50).joined(separator: ","))]}"#)
        #expect(decoded.rateLimits.count == 1)
    }

    @Test func usageStillFailsWithoutReadableSessionTotals() {
        #expect(throws: DecodingError.self) { try usage(#"{"model":"m","effort":"high"}"#) }
    }

    @Test func theNewTelemetryFieldsRoundTripThroughTheirOwnEncoding() throws {
        let original = try usage(#"{\#(Self.session),"model":"m","effort":"low","context":{"tokens":1,"window":2,"percent":50,"compact_at":0.8,"breakdown":{"tools":4}},"rate_limits":[{"kind":"five_hour","percent_used":2,"resets_at":"2026-11-12T05:00:00Z"}],"git":{"added":1,"removed":2}}"#)
        let again = try JSONDecoder().decode(LeoAgentUsage.self, from: JSONEncoder().encode(original))
        #expect(again.model == original.model)
        #expect(again.effort == original.effort)
        #expect(again.context == original.context)
        #expect(again.rateLimits == original.rateLimits)
        #expect(again.git == original.git)
    }

    // MARK: model on the agent rows

    @Test func anObservedAgentCarriesItsConfiguredModelAndTheObservedOneInUsage() throws {
        let json = #"{"name":"a","model":"configured-model","usage":{\#(Self.session),"model":"observed-model"}}"#
        let agent = try JSONDecoder().decode(LeoObservedAgent.self, from: Data(json.utf8))
        #expect(agent.model == "configured-model")
        #expect(agent.usage?.model == "observed-model")
        let bare = try JSONDecoder().decode(LeoObservedAgent.self, from: Data(#"{"name":"a"}"#.utf8))
        #expect(bare.model == nil)
        let malformed = try JSONDecoder().decode(LeoObservedAgent.self, from: Data(#"{"name":"a","model":7}"#.utf8))
        #expect(malformed.model == nil)
    }

    @Test func anAgentRowDecodesItsModelLeniently() throws {
        let agent = try JSONDecoder().decode(LeoAgent.self, from: Data(#"{"name":"a","model":"m"}"#.utf8))
        #expect(agent.model == "m")
        #expect(try JSONDecoder().decode(LeoAgent.self, from: Data(#"{"name":"a"}"#.utf8)).model == nil)
        #expect(try JSONDecoder().decode(LeoAgent.self, from: Data(#"{"name":"a","model":["x"]}"#.utf8)).model == nil)
    }
}
