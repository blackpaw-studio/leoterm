import Foundation
import Testing

@testable import Ghostty

struct LeoObservedStateDecodingTests {
    private func decode(_ json: String) throws -> LeoObservedState {
        try LeoDaemonEnvelope<LeoObservedState>.decode(Data(json.utf8)).value()
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

    @Test func unknownFeatureNamesAreIgnored() {
        let features = LeoDaemonFeatures(["dispatch_tree", "from_the_future", "agent_usage"])
        #expect(features.features == [.dispatchTree, .agentUsage])
        #expect(!LeoDaemonFeatures.none.contains(.dispatchTree))
    }
}
