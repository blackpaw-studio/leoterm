import Foundation
import Testing

@testable import LeoKit

struct LeoChatClientInboxTests {
    private static func ask(_ id: String) -> String {
        #"{"id":"\#(id)","agent":"zeus","direction":"out","kind":"ask","text":"Which?","state":"open","ts":1,"input":{"type":"buttons","options":[{"value":"a","label":"A"}]}}"#
    }

    @Test func openAsksReadsTheCrossAgentRoute() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"asks":[\#(Self.ask("m1")),\#(Self.ask("m2"))]}}"#])

        let asks = try #require(try await LeoChatHTTPClient(transport: transport).openAsks())

        #expect(asks.map(\.id) == ["m1", "m2"])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/chat/asks?state=open")
    }

    @Test func openAsksAcceptsABareArray() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":[\#(Self.ask("m1"))]}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).openAsks()?.map(\.id) == ["m1"])
    }

    @Test func openAsksIsNilOnAnOldDaemon() async throws {
        let transport = FakeWebTransport(responses: [404: #"{"ok":false,"error":"not found"}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).openAsks() == nil)
    }

    @Test func openAsksStillThrowsOtherFailures() async {
        let transport = FakeWebTransport(responses: [500: #"{"ok":false,"error":"boom"}"#])
        await #expect(throws: LeoDaemonError.self) { _ = try await LeoChatHTTPClient(transport: transport).openAsks() }
    }

    @Test func seenReadsTheSharedMarks() async throws {
        let body = #"{"ok":true,"data":{"agents":[{"agent":"zeus","seen_at":"2026-11-24T17:00:00Z"},{"agent":"hera","seen_at":"2026-11-24T18:00:00Z"}]}}"#
        let transport = FakeWebTransport(responses: [200: body])

        let seen = try #require(try await LeoChatHTTPClient(transport: transport).seen())

        #expect(seen == ["zeus": Date(timeIntervalSince1970: 1_795_539_600), "hera": Date(timeIntervalSince1970: 1_795_543_200)])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/agents/seen")
    }

    @Test func seenAcceptsAnAgentToTimestampMap() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"agents":{"zeus":"2026-11-24T17:00:00Z"}}}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).seen() == ["zeus": Date(timeIntervalSince1970: 1_795_539_600)])
    }

    @Test func seenIsNilOnAnOldDaemon() async throws {
        let transport = FakeWebTransport(responses: [404: #"{"ok":false}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).seen() == nil)
    }

    @Test func markSeenPutsTheBatchAndReturnsTheServerTimes() async throws {
        let body = #"{"ok":true,"data":{"agents":[{"agent":"zeus","seen_at":"2026-11-24T17:00:00Z"}]}}"#
        let transport = FakeWebTransport(responses: [200: body])

        let marked = try await LeoChatHTTPClient(transport: transport).markSeen(agents: ["zeus", "a/b"])

        #expect(marked == ["zeus": Date(timeIntervalSince1970: 1_795_539_600)])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/api/v1/agents/seen")
        let sent = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: [String]]
        #expect(sent == ["agents": ["zeus", "a/b"]])
    }

    @Test func markSeenWithoutTimesInTheReplyIsAnEmptyMap() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true}"#])
        #expect(try await LeoChatHTTPClient(transport: transport).markSeen(agents: ["zeus"]) == [:])
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
