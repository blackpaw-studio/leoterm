import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

struct AgentMessagingClientTests {
    private actor FakeTransport: LeoChatTransport {
        let status: Int?
        private(set) var requests: [LeoHTTPRequest] = []

        init(status: Int?) { self.status = status }

        func send(_ request: LeoHTTPRequest, timeout: TimeInterval) async throws -> LeoHTTPResponse {
            requests.append(request)
            guard let status else { throw LeoDaemonError.transport("offline") }
            let body = #"{"ok":true,"data":{"id":"01","agent":"zeus","direction":"out","kind":"text","text":"hi","state":"pending","ts":0}}"#
            return LeoHTTPResponse(status: status, body: Data(body.utf8))
        }
    }

    private static let studio = LeoAgentTarget(machineID: PairedDaemon.dionysus.id, machineName: "dionysus", agent: "zeus")

    private static func client(
        daemons: [PairedDaemon] = [.dionysus], hasSecrets: Bool = true, status: Int? = 200,
        agents: @escaping @Sendable (DaemonConnection) async throws -> [String] = { _ in ["zeus", "hera"] },
        failures: LockIsolated<[LeoAgentRetryPayload]> = LockIsolated([]),
        unsent: LockIsolated<[String]> = LockIsolated([])
    ) -> (client: AgentMessagingClient, transport: FakeTransport) {
        let transport = FakeTransport(status: status)
        var secrets = SecretsClient()
        secrets.load = { _ in hasSecrets ? DaemonSecrets(token: "t") : nil }
        var pairedDaemons = PairedDaemonsClient()
        pairedDaemons.load = { daemons }
        let client = AgentMessagingClient.live(
            pairedDaemons: pairedDaemons, secrets: secrets, agentNames: agents, transport: { _ in transport },
            notifyFailure: { payload in failures.withValue { $0.append(payload) } },
            notifyUnsent: { machine, text in unsent.withValue { $0.append("\(machine): \(text)") } }
        )
        return (client, transport)
    }

    @Test func listsTheAgentsOfEveryPairedDaemonAndSkipsOneThatFails() async {
        struct Down: Error {}
        let daemons = [PairedDaemon.dionysus, .hestia]
        let (client, _) = Self.client(daemons: daemons) { connection in
            if connection.daemonID == PairedDaemon.hestia.id { throw Down() }
            return ["zeus", "hera"]
        }
        let directory = await client.agents()
        #expect(directory.machineCount == 2)
        #expect(directory.targets.map(\.agent) == ["zeus", "hera"])
        #expect(Set(directory.targets.map(\.machineName)) == ["dionysus"])
        #expect(directory.unreachable == [LeoAgentMachineRef(id: PairedDaemon.hestia.id, name: "hestia")])
    }

    @Test func aSendPostsTheTextAndNotifiesNothing() async throws {
        let failures = LockIsolated<[LeoAgentRetryPayload]>([])
        let (client, transport) = Self.client(failures: failures)
        let result = await client.send(Self.studio, "run the tests")
        #expect(result == .sent(Self.studio))
        #expect(try #require(await transport.requests.first).path == "/api/v1/chat/zeus/messages")
        #expect(failures.value.isEmpty)
    }

    @Test func anUnreachableDaemonPostsARetryableFailure() async {
        let failures = LockIsolated<[LeoAgentRetryPayload]>([])
        let (client, _) = Self.client(status: nil, failures: failures)
        let result = await client.send(Self.studio, "run the tests")
        #expect(result == .unreachable(Self.studio, text: "run the tests"))
        #expect(failures.value == [LeoAgentRetryPayload(target: Self.studio.pushTarget, machine: "dionysus", text: "run the tests")])
    }

    @Test func missingCredentialsAreUnreachableAndRetryable() async {
        let failures = LockIsolated<[LeoAgentRetryPayload]>([])
        let (client, transport) = Self.client(hasSecrets: false, failures: failures)
        #expect(await client.send(Self.studio, "hi") == .unreachable(Self.studio, text: "hi"))
        #expect(await transport.requests.isEmpty)
        #expect(failures.value.map(\.text) == ["hi"])
    }

    @Test func aMissingAgentIsNotRetryable() async {
        let failures = LockIsolated<[LeoAgentRetryPayload]>([])
        let (client, _) = Self.client(status: 404, failures: failures)
        #expect(await client.send(Self.studio, "hi") == .agentMissing(Self.studio))
        #expect(failures.value.isEmpty)
    }

    @Test func nothingAnsweringForAConfiguredAgentKeepsTheTextForRetry() async {
        let failures = LockIsolated<[LeoAgentRetryPayload]>([])
        let (client, _) = Self.client(failures: failures)
        let target = Self.studio.pushTarget
        let outcome = await client.reportUnreachable(target, "hestia", "run the tests")
        #expect(outcome == .unreachable(machine: "hestia"))
        #expect(failures.value == [LeoAgentRetryPayload(target: target, machine: "hestia", text: "run the tests")])
    }

    @Test func nothingAnsweringWithNoAgentChosenStillKeepsTheText() async {
        let failures = LockIsolated<[LeoAgentRetryPayload]>([])
        let unsent = LockIsolated<[String]>([])
        let (client, _) = Self.client(failures: failures, unsent: unsent)
        let outcome = await client.reportUnreachable(nil, "hestia", "run the tests")
        #expect(outcome == .unreachable(machine: "hestia"))
        #expect(failures.value.isEmpty)
        #expect(unsent.value == ["hestia: run the tests"])
    }
}
