import Foundation
import Testing

@testable import LeoKit

/// Agent appearance on the observe wire, decoded from the daemon's own
/// goldens (leo `internal/observe/testdata/wire/appearance-*.json`).
struct LeoAppearanceWireTests {
    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private func observed(_ data: Data) throws -> LeoObservedAgent {
        try JSONDecoder().decode(LeoObservedAgent.self, from: data)
    }

    private func observed(_ json: String) throws -> LeoObservedAgent { try observed(Data(json.utf8)) }

    private func event(_ data: Data, type: String = "agent_appearance_changed") -> LeoObserveEvent? {
        LeoActivityClient.decode(LeoSSEEvent(name: type, data: String(bytes: data, encoding: .utf8) ?? "", id: nil))
    }

    @Test func decodesFullAppearance() throws {
        let agent = try observed(try Self.fixture("appearance-agent"))
        #expect(agent.appearance == LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0)))
    }

    @Test func decodesPartialAppearance() throws {
        let agent = try observed(try Self.fixture("appearance-agent-partial"))
        #expect(agent.appearance == LeoAgentAppearance(emoji: nil, color: .pink, emojiSource: nil, colorSource: .rule(1)))
    }

    @Test func absentKeyIsNil() throws {
        #expect(try observed(#"{"name":"a","status":"running"}"#).appearance == nil)
    }

    @Test func unknownColorReadsAsUnset() throws {
        let both = try observed(#"{"name":"a","appearance":{"emoji":"🎩","color":"magenta","emoji_source":"manual","color_source":"rule:2"}}"#)
        #expect(both.appearance == LeoAgentAppearance(emoji: "🎩", color: nil, emojiSource: .manual, colorSource: nil))
        // Only an unknown color: nothing this app can show.
        #expect(try observed(#"{"name":"a","appearance":{"color":"magenta","color_source":"manual"}}"#).appearance == nil)
    }

    @Test func unknownSourceKeepsTheValue() throws {
        let agent = try observed(#"{"name":"a","appearance":{"color":"red","color_source":"theme:dark"}}"#)
        #expect(agent.appearance == LeoAgentAppearance(emoji: nil, color: .red, emojiSource: nil, colorSource: nil))
        #expect(LeoAgentAppearance.Source(wire: "rule:-1") == nil)
        #expect(LeoAgentAppearance.Source(wire: "rule:x") == nil)
        #expect(LeoAgentAppearance.Source(wire: "rule:12") == .rule(12))
    }

    @Test func malformedAppearanceNeverFailsState() throws {
        let agent = try observed(#"{"name":"a","status":"running","appearance":"teal"}"#)
        #expect(agent.status == .running)
        #expect(agent.appearance == nil)
        let typed = try observed(#"{"name":"a","appearance":{"emoji":7,"color":"blue"}}"#)
        #expect(typed.appearance == LeoAgentAppearance(emoji: nil, color: .blue, emojiSource: nil, colorSource: nil))
    }

    @Test func eventCarriesAppearance() throws {
        let decoded = event(try Self.fixture("appearance-event"))
        #expect(decoded == .agentAppearanceChanged(
            seq: 42, at: "2026-10-27T14:05:00Z", agent: "olympus",
            appearance: LeoAgentAppearance(emoji: "🏛️", color: .teal, emojiSource: .manual, colorSource: .rule(0))
        ))
        #expect(decoded?.sequence == 42)
    }

    @Test func eventWithNullClears() throws {
        let decoded = event(try Self.fixture("appearance-event-null"))
        #expect(decoded == .agentAppearanceChanged(seq: 43, at: "2026-10-27T14:06:00Z", agent: "olympus", appearance: nil))
    }

    @Test func eventByTypeFieldDecodes() {
        let decoded = LeoActivityClient.decode(LeoSSEEvent(
            name: nil, data: #"{"type":"agent_appearance_changed","seq":5,"agent":"a","appearance":{"emoji":"🎩"}}"#, id: nil
        ))
        #expect(decoded == .agentAppearanceChanged(
            seq: 5, at: nil, agent: "a", appearance: LeoAgentAppearance(emoji: "🎩", color: nil, emojiSource: nil, colorSource: nil)
        ))
    }

    @Test func malformedEventKeepsItsSequence() {
        // No agent, or an appearance that is not an object: sequence only,
        // never a clear.
        #expect(event(Data(#"{"seq":9,"appearance":null}"#.utf8)) == .other(seq: 9, type: "agent_appearance_changed"))
        #expect(event(Data(#"{"seq":10,"agent":"a","appearance":"teal"}"#.utf8)) == .other(seq: 10, type: "agent_appearance_changed"))
        #expect(event(Data(#"{"seq":11,"agent":"a"}"#.utf8)) == .other(seq: 11, type: "agent_appearance_changed"))
    }

    @Test func helloAdvertisesAgentAppearance() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/client-tools/hello-provider.json"))
        guard case .hello(_, _, _, _, _, let names) = event(data, type: "hello") else {
            Issue.record("not a hello")
            return
        }
        #expect(LeoDaemonFeatures(names).contains(.agentAppearance))
        #expect(!LeoDaemonFeatures(["client_tools"]).contains(.agentAppearance))
    }

    @Test func paletteIsTheDaemonsInOrder() {
        #expect(LeoAppearanceColor.allCases.map(\.rawValue) == [
            "red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "gray",
        ])
    }

    @Test func sourceWireRoundTrips() {
        #expect(LeoAgentAppearance.Source.manual.wireValue == "manual")
        #expect(LeoAgentAppearance.Source.rule(3).wireValue == "rule:3")
        #expect(LeoAgentAppearance.Source(wire: "manual") == .manual)
    }
}
