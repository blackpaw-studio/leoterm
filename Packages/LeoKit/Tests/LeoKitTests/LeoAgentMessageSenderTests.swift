import Foundation
import Testing

@testable import LeoKit

/// A chat transport that answers with one scripted outcome and records requests.
actor ScriptedTransport: LeoChatTransport {
    enum Outcome: Sendable {
        case status(Int, String)
        case fail(LeoDaemonError)
    }

    let outcome: Outcome
    private(set) var requests: [LeoHTTPRequest] = []

    init(_ outcome: Outcome) { self.outcome = outcome }

    func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        switch outcome {
        case .status(let status, let body): return LeoHTTPResponse(status: status, body: Data(body.utf8))
        case .fail(let error): throw error
        }
    }
}

struct LeoAgentMessageSenderTests {
    static let studio = LeoAgentTarget(machineID: "d1", machineName: "Studio", agent: "zeus")
    static let sentBody = #"{"ok":true,"data":{"id":"01JA","agent":"zeus","direction":"out","kind":"text","text":"hi","state":"pending","ts":0}}"#

    struct CredentialsError: Error {}

    static func sender(
        transport: ScriptedTransport, agents: [String] = ["zeus"], chatThrows: Bool = false,
        machines: [LeoAgentMachine]? = nil, deadline: @escaping @Sendable (String) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    ) -> LeoAgentMessageSender {
        let studio = LeoAgentMachine(id: "d1", name: "Studio") { agents }
        return LeoAgentMessageSender(
            machines: { machines ?? [studio] },
            chat: { _ in
                if chatThrows { throw CredentialsError() }
                return LeoChatHTTPClient(transport: transport)
            },
            deadline: deadline
        )
    }

    @Test func aSuccessfulPostIsSentAndCarriesTheText() async throws {
        let transport = ScriptedTransport(.status(200, Self.sentBody))
        let result = await Self.sender(transport: transport).send(Self.studio, text: "run the tests")

        #expect(result == .sent(Self.studio))
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/api/v1/chat/zeus/messages")
        let data = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["text"] as? String == "run the tests")
    }

    @Test(arguments: [
        (ScriptedTransport.Outcome.status(401, ""), "unauthorized"),
        (.status(403, ""), "unauthorized"),
        (.fail(.crossOriginRedirect("https://team.cloudflareaccess.com/login")), "unauthorized"),
        (.status(404, #"{"ok":false,"code":"not_found","error":"agent not found"}"#), "missing"),
        (.status(503, ""), "unreachable"),
        (.status(500, ""), "unreachable"),
        (.fail(.timeout), "unreachable"),
        (.fail(.transport("offline")), "unreachable"),
        (.fail(.hostUnavailable("down")), "unreachable"),
    ])
    func eachFailureMapsToItsResult(outcome: ScriptedTransport.Outcome, expected: String) async {
        let result = await Self.sender(transport: ScriptedTransport(outcome)).send(Self.studio, text: "hi")
        switch (expected, result) {
        case ("unauthorized", .unauthorized(let target, text: "hi")), ("unreachable", .unreachable(let target, text: "hi")):
            #expect(target == Self.studio)
        case ("missing", .agentMissing(let target)):
            #expect(target == Self.studio)
        default:
            Issue.record("\(outcome) mapped to \(result), wanted \(expected)")
        }
    }

    @Test func aCredentialsFailureIsUnreachable() async {
        let transport = ScriptedTransport(.status(200, Self.sentBody))
        let result = await Self.sender(transport: transport, chatThrows: true).send(Self.studio, text: "hi")
        #expect(result == .unreachable(Self.studio, text: "hi"))
        #expect(await transport.requests.isEmpty)
    }

    @Test func aMachineThatIsNoLongerPairedMakesTheAgentMissing() async {
        let result = await Self.sender(transport: ScriptedTransport(.status(200, Self.sentBody)), machines: []).send(Self.studio, text: "hi")
        #expect(result == .agentMissing(Self.studio))
    }

    @Test func outcomesNameWhatTheAppShouldSay() {
        #expect(LeoAgentSendResult.sent(Self.studio).outcome == .sent(agent: "zeus"))
        #expect(LeoAgentSendResult.unreachable(Self.studio, text: "x").outcome == .unreachable(machine: "Studio"))
        #expect(LeoAgentSendResult.unauthorized(Self.studio, text: "x").outcome == .unreachable(machine: "Studio"))
        #expect(LeoAgentSendResult.agentMissing(Self.studio).outcome == .agentMissing(agent: "zeus"))
    }

    @Test func everyFailureExceptAMissingAgentKeepsTheTextForRetry() {
        let expected = LeoAgentRetryPayload(target: Self.studio.pushTarget, machine: "Studio", text: "keep me")
        #expect(LeoAgentSendResult.unreachable(Self.studio, text: "keep me").retryPayload == expected)
        #expect(LeoAgentSendResult.unauthorized(Self.studio, text: "keep me").retryPayload == expected)
        #expect(LeoAgentSendResult.agentMissing(Self.studio).retryPayload == nil)
        #expect(LeoAgentSendResult.sent(Self.studio).retryPayload == nil)
    }

    @Test func agentsListsEveryMachinesAgentsAndCountsMachines() async {
        let machines = [
            LeoAgentMachine(id: "d1", name: "Studio") { ["zeus", "hera"] },
            LeoAgentMachine(id: "d2", name: "Laptop") { ["zeus"] },
        ]
        let directory = await Self.sender(transport: ScriptedTransport(.status(200, "")), machines: machines).agents()

        #expect(directory.machineCount == 2)
        #expect(Set(directory.targets) == [
            LeoAgentTarget(machineID: "d1", machineName: "Studio", agent: "zeus"),
            LeoAgentTarget(machineID: "d1", machineName: "Studio", agent: "hera"),
            LeoAgentTarget(machineID: "d2", machineName: "Laptop", agent: "zeus"),
        ])
    }

    @Test func aFailingOrSlowMachineIsSkippedNotFatal() async {
        struct Down: Error {}
        let machines = [
            LeoAgentMachine(id: "d1", name: "Studio") { ["zeus"] },
            LeoAgentMachine(id: "d2", name: "Broken") { throw Down() },
            LeoAgentMachine(id: "d3", name: "Slow") {
                try await Task.sleep(for: .seconds(3600))
                return ["late"]
            },
        ]
        // The deadline fires at once for the slow machine only; the others never time out.
        let sender = Self.sender(transport: ScriptedTransport(.status(200, "")), machines: machines) { machineID in
            if machineID != "d3" { try await Task.sleep(for: .seconds(3600)) }
        }
        let directory = await sender.agents()

        #expect(directory.machineCount == 3)
        #expect(directory.targets == [LeoAgentTarget(machineID: "d1", machineName: "Studio", agent: "zeus")])
        #expect(directory.unreachable == [LeoAgentMachineRef(id: "d2", name: "Broken"), LeoAgentMachineRef(id: "d3", name: "Slow")])
    }
}
