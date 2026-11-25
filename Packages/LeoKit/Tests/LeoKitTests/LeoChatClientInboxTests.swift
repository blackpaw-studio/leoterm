import Foundation
import Testing

@testable import LeoKit

struct LeoChatClientInboxTests {
    private static func ask(_ id: String) -> String {
        #"{"id":"\#(id)","agent":"zeus","direction":"out","kind":"ask","text":"Which?","state":"open","ts":1,"input":{"type":"buttons","options":[{"value":"a","label":"A"}]}}"#
    }

    private static let t1 = Date(timeIntervalSince1970: 1_795_539_600)

    @Test func openAsksReadsTheCrossAgentRoute() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"messages":[\#(Self.ask("m1")),\#(Self.ask("m2"))]}}"#])

        let asks = try #require(try await LeoChatHTTPClient(transport: transport).openAsks())

        #expect(asks.map(\.id) == ["m1", "m2"])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/chat/asks?state=open")
    }

    @Test func openAsksDropsUndecodableMessagesAndAcceptsAnEmptyList() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"messages":[{"id":"bad"},\#(Self.ask("m1"))]}}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).openAsks()?.map(\.id) == ["m1"])
        let empty = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"messages":[]}}"#])
        #expect(try await LeoChatHTTPClient(transport: empty).openAsks() == [])
    }

    @Test func openAsksIsNilOnAnOldDaemon() async throws {
        let transport = FakeWebTransport(responses: [404: #"{"ok":false,"error":"not found"}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).openAsks() == nil)
    }

    @Test func openAsksStillThrowsOtherFailures() async {
        let transport = FakeWebTransport(responses: [500: #"{"ok":false,"error":"boom"}"#])
        await #expect(throws: LeoDaemonError.self) { _ = try await LeoChatHTTPClient(transport: transport).openAsks() }
    }

    @Test func seenReadsTheAgentToTimestampMapWithOrWithoutMilliseconds() async throws {
        let map = #"{"zeus":"2026-11-24T17:00:00Z","hera":"2026-11-24T17:00:00.500Z"}"#
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":\#(map)}"#])

        let seen = try #require(try await LeoChatHTTPClient(transport: transport).seen())

        #expect(seen == ["zeus": Self.t1, "hera": Self.t1.addingTimeInterval(0.5)])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/agents/seen")
    }

    @Test func seenIsEmptyForADaemonWithNoMarksAndNilOnAnOldDaemon() async throws {
        let none = FakeWebTransport(responses: [200: #"{"ok":true,"data":{}}"#])
        #expect(try await LeoChatHTTPClient(transport: none).seen() == [:])
        let old = FakeWebTransport(responses: [404: #"{"ok":false}"#])
        #expect(try await LeoChatHTTPClient(transport: old).seen() == nil)
    }

    @Test func markSeenAlwaysUsesTheBatchRouteAndReturnsTheServerTimes() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"zeus":"2026-11-24T17:00:00.250Z"}}"#])

        let marked = try await LeoChatHTTPClient(transport: transport).markSeen(agents: ["zeus"])

        #expect(marked == ["zeus": Self.t1.addingTimeInterval(0.25)])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/api/v1/agents/seen")
        let sent = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: [String]]
        #expect(sent == ["agents": ["zeus"]])
    }

    @Test func markSeenIsNilOnAnOldDaemon() async throws {
        let transport = FakeWebTransport(responses: [404: #"{"ok":false}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).markSeen(agents: ["zeus"]) == nil)
    }

    @Test func markSeenOfNoAgentsSendsNothing() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).markSeen(agents: []) == [:])
        #expect(await transport.requests.isEmpty)
    }
}
