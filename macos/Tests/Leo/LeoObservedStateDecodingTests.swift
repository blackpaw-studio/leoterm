import Foundation
import Testing

@testable import Ghostty

struct LeoObservedStateDecodingTests {
    private func decode(_ json: String) throws -> LeoObservedState {
        try LeoDaemonEnvelope<LeoObservedState>.decode(Data(json.utf8)).value()
    }

    @Test func metaSeqDecodesWhenPresentAndIsNilOtherwise() throws {
        let with = try decode(#"{"ok":true,"data":{"agents":[],"meta":{"seq":42}}}"#)
        #expect(with.seq == 42)
        let without = try decode(#"{"ok":true,"data":{"agents":[]}}"#)
        #expect(without.seq == nil)
        let malformed = try decode(#"{"ok":true,"data":{"agents":[],"meta":{"seq":"x"}}}"#)
        #expect(malformed.seq == nil)
    }

    @Test func absentDispatchesReadAsNone() throws {
        let state = try decode(#"{"ok":true,"data":{"agents":[{"name":"alpha"}]}}"#)
        #expect(state.agents.map(\.name) == ["alpha"])
        #expect(state.dispatches.isEmpty)
    }

    @Test func aMalformedDispatchIsDroppedAndEverythingElseSurvives() throws {
        let state = try decode(#"{"ok":true,"data":{"agents":[{"name":"alpha"},{"name":"beta"}],"dispatches":["#
            + #"{"id":"d-1","status":"running","caller_agent":"alpha"},"#
            + #"{"status":"running"},"#
            + #""not an object","#
            + #"{"id":"d-2","status":"done","parent_dispatch_id":"d-1","stalled":"yes"}]}}"#)
        #expect(state.agents.map(\.name) == ["alpha", "beta"])
        #expect(state.dispatches.map(\.id) == ["d-1", "d-2"])
        #expect(state.dispatches.last?.stalled == false, "a wrong-typed optional degrades instead of dropping the entry")
    }

    @Test func aNonArrayDispatchesReadsAsNone() throws {
        let state = try decode(#"{"ok":true,"data":{"agents":[{"name":"alpha"}],"dispatches":{"id":"d-1"}}}"#)
        #expect(state.agents.map(\.name) == ["alpha"])
        #expect(state.dispatches.isEmpty)
    }

    @Test func decodesAgentUsage() throws {
        let usage = #"{"session_id":"s1","session":{"tokens":1200,"cost_usd":0.42},"incarnation":{"tokens":5000,"cost_usd":1.5},"#
            + #""context":{"tokens":74000,"window":200000,"percent":37}}"#
        let state = try decode(#"{"ok":true,"data":{"agents":[{"name":"a","usage":"# + usage + #"},{"name":"b"},"#
            + #"{"name":"c","usage":{"session":"nope"}},{"name":"d","usage":{"session":{"tokens":1},"context":{"percent":"x"}}}]}}"#)
        #expect(state.agents[0].usage == LeoAgentUsage(
            sessionID: "s1", session: LeoUsageTotals(tokens: 1200, costUSD: 0.42), incarnation: LeoUsageTotals(tokens: 5000, costUSD: 1.5),
            context: LeoContextUsage(tokens: 74000, window: 200_000, percent: 37)))
        #expect(state.agents[1].usage == nil, "missing usage is nil")
        #expect(state.agents[2].usage == nil, "malformed usage is nil and the agent still decodes")
        #expect(state.agents[3].usage?.context == nil, "a malformed context drops only the context")
        #expect(state.agents.map(\.name) == ["a", "b", "c", "d"])
    }

    @Test func absurdContextPercentIsMalformedNotFatal() throws {
        let state = try decode(#"{"ok":true,"data":{"agents":[{"name":"a","usage":{"session":{"tokens":1},"context":{"tokens":1,"window":2,"percent":1e30}}}]}}"#)
        #expect(state.agents[0].usage?.context == nil)
        #expect(state.agents[0].usage?.session.tokens == 1)
    }

    @Test func implausibleUsageReadsAsNilAndTheAgentSurvives() throws {
        let bad = [
            #"{"session":{"tokens":-5,"cost_usd":0.1}}"#,
            #"{"session":{"tokens":1e30,"cost_usd":0.1}}"#,
            #"{"session":{"tokens":5,"cost_usd":1e12}}"#,
            #"{"session":{"tokens":5,"cost_usd":-1}}"#
        ]
        for usage in bad {
            let state = try decode(#"{"ok":true,"data":{"agents":[{"name":"a","usage":"# + usage + #"}]}}"#)
            #expect(state.agents.map(\.name) == ["a"])
            #expect(state.agents[0].usage == nil, "\(usage) must not render")
        }
        for context in [#"{"tokens":1,"window":0,"percent":5}"#, #"{"tokens":1,"window":-3,"percent":5}"#, #"{"tokens":-1,"window":9,"percent":5}"#] {
            let state = try decode(#"{"ok":true,"data":{"agents":[{"name":"a","usage":{"session":{"tokens":5},"context":"# + context + #"}}]}}"#)
            #expect(state.agents[0].usage?.session.tokens == 5)
            #expect(state.agents[0].usage?.context == nil, "\(context) is a bad context")
        }
    }

    @Test func implausibleTurnNumbersAreDroppedNotTrusted() {
        let json = #"{"seq":1,"agent":"a","outcome":"completed","preview":"x","tokens":{"input":-1,"output":2},"cost_usd":-3}"#
        guard case .agentTurnCompleted(_, let turn) = LeoActivityClient.decode(LeoSSEEvent(name: "agent_turn_completed", data: json, id: nil)) else {
            Issue.record("not a turn")
            return
        }
        #expect(turn.tokens == nil && turn.costUSD == nil)
        #expect(turn.preview == "x", "the preview survives bad numbers")
        let huge = #"{"seq":2,"agent":"a","preview":"x","cost_usd":1e12}"#
        guard case .agentTurnCompleted(_, let capped) = LeoActivityClient.decode(LeoSSEEvent(name: "agent_turn_completed", data: huge, id: nil)) else {
            Issue.record("not a turn")
            return
        }
        #expect(capped.costUSD == nil)
    }

    @Test func liveMeansNoEndAndANonTerminalStatus() {
        #expect(LeoDispatch(id: "a", status: "running").isLive)
        #expect(LeoDispatch(id: "a", status: "idle").isLive)
        #expect(LeoDispatch(id: "a", status: "settling").isLive)
        #expect(LeoDispatch(id: "a", status: "queued").isLive)
        for status in ["done", "failed", "timeout", "canceled", "closed", "released"] {
            #expect(!LeoDispatch(id: "a", status: status).isLive, "\(status) is terminal")
        }
        #expect(!LeoDispatch(id: "a", status: "running", endedAt: "2026-10-06T12:00:00Z").isLive)
    }

    @Test func decodesAttachDispatchPlacement() {
        let features = LeoDaemonFeatures(["attach_dispatch_placement", "from_the_future"])
        #expect(features.contains(.attachDispatchPlacement))
        #expect(!LeoDaemonFeatures.none.contains(.attachDispatchPlacement))
    }

    @Test func unknownFeatureNamesAreIgnored() {
        let features = LeoDaemonFeatures(["dispatch_tree", "from_the_future", "agent_usage"])
        #expect(features.features == [.dispatchTree, .agentUsage])
        #expect(!LeoDaemonFeatures.none.contains(.dispatchTree))
    }
}
