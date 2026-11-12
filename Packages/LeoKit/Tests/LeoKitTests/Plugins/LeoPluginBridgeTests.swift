import Foundation
import Testing

@testable import LeoKit

struct LeoPluginBridgeTests {
    private let agent = LeoPluginAgentRef(machine: "local", name: "alfred")

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func hostRequestsRoundTrip() throws {
        let requests: [LeoPluginHostRequest] = [
            .render(slot: .view(viewID: "pr", agent: agent), node: try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))])),
            .render(slot: .section(id: "issues"), node: try LeoPluginSlotRoot(nodes: [])),
            .fetch(id: "r1", url: "https://api.github.com/user",
                   init: LeoPluginFetchInit(method: "POST", headers: ["a": "b"], body: "x=1")),
            .fetch(id: "r2", url: "https://api.github.com/user", init: LeoPluginFetchInit()),
            .secretsGet(id: "r3", key: "token"),
            .secretsSet(id: "r4", key: "token", value: "v"),
            .secretsDelete(id: "r5", key: "token"),
            .agentsList(id: "r6"),
            .agentsUsage(id: "r7", agent: agent),
            .timerStart(id: "t1", seconds: 60),
            .afterStart(id: "t2", seconds: 5),
            .timerStop(id: "t1"),
            .log(level: "info", message: "hi"),
            .callbackResult(ref: "c1", action: .copy("x")),
            .handlerError(source: "callback", message: "boom"),
        ]
        for request in requests { #expect(try roundTrip(request) == request) }
    }

    @Test func eventsRoundTrip() throws {
        let slot = LeoPluginSlotID.accessory(id: "pr", agent: agent)
        let events: [LeoPluginEvent] = [
            .activate(slot: nil),
            .activate(slot: slot),
            .agentsChanged,
            .viewOpened(agent: agent, slot: .view(viewID: "pr", agent: agent)),
            .command(id: "open", slot: .palette(commandID: "open")),
            .command(id: "open", slot: nil),
            .callback(ref: "c1", id: "refresh", payload: .object(["n": .int(2)]), gesture: true),
            .timerFired(id: "t1"),
            .reply(id: "r1", outcome: .value(.object(["status": .int(200)]))),
            .reply(id: "r2", outcome: .rejected(reason: "host not allowed")),
        ]
        for event in events { #expect(try roundTrip(event) == event) }
    }

    @Test func slotIDsRoundTripAndHaveDistinctKeys() throws {
        let slots: [LeoPluginSlotID] = [
            .view(viewID: "pr", agent: agent),
            .accessory(id: "pr", agent: agent),
            .section(id: "pr"),
            .palette(commandID: "pr"),
        ]
        for slot in slots { #expect(try roundTrip(slot) == slot) }
        #expect(Set(slots.map(\.key)).count == slots.count)
    }

    // MARK: No send/spawn request

    @Test(arguments: ["sendToAgent", "spawnAgent", "message", "exec", ""])
    func unknownCallsDecodeToUnsupported(call: String) throws {
        let json = #"{"call":"\#(call)","agent":{"machine":"local","name":"alfred"},"text":"rm -rf"}"#
        let request = try JSONDecoder().decode(LeoPluginHostRequest.self, from: Data(json.utf8))
        #expect(request == .unsupported(call: call))
    }

    @Test func missingCallDecodesToUnsupported() throws {
        let request = try JSONDecoder().decode(LeoPluginHostRequest.self, from: Data("{}".utf8))
        #expect(request == .unsupported(call: ""))
    }

    @Test func knownCallWithBadFieldsFailsToDecode() {
        let json = Data(#"{"call":"timerStart","id":"t","seconds":"soon"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LeoPluginHostRequest.self, from: json) }
    }

    @Test(arguments: [
        #"{"call":"agentsUsage","id":"r"}"#, #"{"call":"agentsUsage","id":"r","agent":"alfred"}"#,
        #"{"call":"agentsUsage","id":"r","agent":{"machine":1,"name":"a"}}"#, #"{"call":"agentsUsage","id":"r","agent":{"machine":"m"}}"#,
        #"{"call":"agentsUsage","agent":{"machine":"m","name":"a"}}"#,
    ])
    func anAgentsUsageRequestWithoutAWellFormedAgentFailsToDecode(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LeoPluginHostRequest.self, from: Data(json.utf8)) }
    }

    @Test func spawnCanOnlyArriveAsACallbackFollowUp() throws {
        let json = #"""
        {"call":"callbackResult","ref":"c1","action":{"type":"spawnAgent","repo":"a/b","branch":"x","prompt":"p"}}
        """#
        let request = try JSONDecoder().decode(LeoPluginHostRequest.self, from: Data(json.utf8))
        guard case .callbackResult(_, let action) = request, case .spawnAgent = action else {
            Issue.record("expected callbackResult(spawnAgent)")
            return
        }
    }

    @Test func eventWireShapesAreStable() throws {
        let event = LeoPluginEvent.callback(ref: "c1", id: "go", payload: .null, gesture: true)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        #expect(object?["type"] as? String == "callback")
        #expect(object?["ref"] as? String == "c1")
        #expect(object?["gesture"] as? Bool == true)
    }
}
