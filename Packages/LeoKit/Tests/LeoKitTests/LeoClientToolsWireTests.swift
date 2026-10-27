import Foundation
import Testing

@testable import LeoKit

/// The client-tools wire contract, pinned to the golden JSON the daemon's
/// `internal/clienttools/testdata/wire/` also encodes against.
struct LeoClientToolsWireTests {
    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/client-tools/\(name).json")
        return try Data(contentsOf: url)
    }

    /// Encodes `value` and checks it is the same JSON as `golden` (key order and
    /// whitespace aside).
    static func expectSameJSON<T: Encodable>(_ value: T, as golden: Data, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let encoded = try JSONEncoder().encode(value)
        let lhs = try JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed) as AnyObject
        let rhs = try JSONSerialization.jsonObject(with: golden, options: .fragmentsAllowed) as AnyObject
        #expect(lhs.isEqual(rhs), "encoded \(String(bytes: encoded, encoding: .utf8) ?? "<non-utf8>")", sourceLocation: sourceLocation)
    }

    /// The `data` member of an enveloped fixture, as JSON.
    static func envelopeData(_ name: String) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: try fixture(name)) as? [String: Any]
        return try JSONSerialization.data(withJSONObject: try #require(object?["data"]), options: .fragmentsAllowed)
    }

    static func decodeAndRoundTrip<T: Codable & Equatable>(_ type: T.Type, data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
        let value = try JSONDecoder().decode(T.self, from: data)
        try expectSameJSON(value, as: data, sourceLocation: sourceLocation)
        return value
    }

    @Test func registerRequestRoundTrips() throws {
        let request = try Self.decodeAndRoundTrip(LeoClientToolsRegisterRequest.self, data: try Self.fixture("register-request"))
        #expect(request.clientID == "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W")
        #expect(request.group == "browser")
        #expect(request.tools.map(\.name) == ["browser_click", "browser_handoff"])
        #expect(request.tools.map(\.timeoutSeconds) == [30, 0])
        #expect(request.tools[0].inputSchema == .object([
            "type": .string("object"),
            "properties": .object(["ref": .object(["type": .string("string")]), "tab": .object(["type": .string("integer")])]),
            "required": .array([.string("ref")]),
        ]))
    }

    @Test func registerResponseCarriesRevision() throws {
        let revision = try Self.decodeAndRoundTrip(LeoClientToolsRegistered.self, data: try Self.envelopeData("register-response"))
        #expect(revision.revision == 7)
    }

    @Test func listResponseRoundTrips() throws {
        let list = try Self.decodeAndRoundTrip(LeoClientToolsList.self, data: try Self.envelopeData("list-response"))
        #expect(list.revision == 7)
        #expect(list.everRegistered)
        #expect(list.tools.map(\.group) == ["browser", "browser"])
        #expect(list.tools.map(\.name) == ["browser_click", "browser_handoff"])
    }

    @Test func callRequestRoundTrips() throws {
        let call = try Self.decodeAndRoundTrip(LeoClientToolCallRequest.self, data: try Self.fixture("call-request"))
        #expect(call.tool == "browser_click")
        #expect(call.args == .object(["ref": .string("e12")]))
    }

    @Test func callResponsePreservesTextAndImageBlocks() throws {
        let ok = try Self.decodeAndRoundTrip(LeoClientToolOutcome.self, data: try Self.envelopeData("call-response-ok"))
        guard case .success(let content) = ok else { Issue.record("expected success, got \(ok)"); return }
        #expect(content.first == .text("clicked e12"))
        guard case .image(let data, let mimeType) = content.last else { Issue.record("expected image"); return }
        #expect(mimeType == "image/png")
        #expect(data.hasPrefix("iVBORw0KGgo"))
    }

    @Test func callResponseErrorCarriesCodeAndMessage() throws {
        let failed = try Self.decodeAndRoundTrip(LeoClientToolOutcome.self, data: try Self.envelopeData("call-response-error"))
        #expect(failed == .failure(LeoClientToolError(code: "stale_ref", message: "ref e12 is not in the current snapshot")))
    }

    @Test func unknownContentBlockKindsPassThrough() throws {
        let raw = Data(#"{"ok":true,"content":[{"type":"resource","uri":"file:///x","size":3}]}"#.utf8)
        let outcome = try Self.decodeAndRoundTrip(LeoClientToolOutcome.self, data: raw)
        #expect(outcome == .success([.other(.object(["type": .string("resource"), "uri": .string("file:///x"), "size": .int(3)]))]))
    }

    @Test func claimRequestAndResponseRoundTrip() throws {
        let claim = try Self.decodeAndRoundTrip(LeoClientToolClaimRequest.self, data: try Self.fixture("claim-request"))
        #expect(claim.clientID == "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W")
        let claimed = try Self.decodeAndRoundTrip(LeoClientToolClaimed.self, data: try Self.envelopeData("claim-response"))
        #expect(claimed.request.id == "ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K")
        #expect(claimed.request.agent == "alfred")
        #expect(claimed.request.group == "browser")
        #expect(claimed.request.tool == "browser_click")
        #expect(claimed.request.args == .object(["ref": .string("e12")]))
        #expect(claimed.request.owner == "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W")
        #expect(claimed.request.timeoutSeconds == 30)
        #expect(claimed.request.createdAt == "2026-10-26T15:21:02.123Z")
    }

    @Test func resultRequestsRoundTrip() throws {
        let ok = try Self.decodeAndRoundTrip(LeoClientToolResultRequest.self, data: try Self.fixture("result-request-ok"))
        #expect(ok.clientID == "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W")
        guard case .success(let content) = ok.outcome else { Issue.record("expected success"); return }
        #expect(content.count == 2)
        let failed = try Self.decodeAndRoundTrip(LeoClientToolResultRequest.self, data: try Self.fixture("result-request-error"))
        #expect(failed.outcome == .failure(LeoClientToolError(code: "user_has_control", message: "the user is controlling the browser")))
    }

    @Test func resultResponseIsAnEmptyObject() throws {
        _ = try JSONDecoder().decode(LeoClientToolEmpty.self, from: try Self.envelopeData("result-response"))
    }

    @Test func pendingResponseFlattensRequestFieldsWithClaimant() throws {
        let pending = try Self.decodeAndRoundTrip(LeoClientToolPendingList.self, data: try Self.envelopeData("pending-response"))
        let owner = "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W"
        #expect(pending.requests.map(\.request.tool) == ["browser_click", "browser_snapshot", "browser_snapshot"])
        // Claimed: the claimant owns the group. Unclaimed under the same owner. Unowned.
        #expect(pending.requests.map(\.claimedBy) == [owner, "", ""])
        #expect(pending.requests.map(\.request.owner) == [owner, owner, ""])
        #expect(pending.requests[1].request.args == .object([:]))
    }

    // MARK: - Error envelopes

    static func mapped(_ name: String) throws -> LeoClientToolsError {
        let body = try fixture(name)
        return LeoClientToolsError(envelope: try LeoDaemonEnvelope<LeoClientToolEmpty>.decode(body), rawBody: body)
    }

    @Test(arguments: [
        ("register-error-invalid-tool", "invalid_tool"),
        ("register-error-too-many-tools", "too_many_tools"),
        ("register-error-unknown-client", "unknown_client"),
        ("register-error-name-conflict", "name_conflict"),
        ("claim-409-owned-by-other", "owned_by_other"),
        ("claim-409-already-claimed", "already_claimed"),
        ("claim-404-unknown-request", "unknown_request"),
        ("result-409-not-claimant", "not_claimant"),
        ("result-409-already-settled", "already_settled"),
        ("result-404-unknown-request", "unknown_request"),
    ])
    func errorEnvelopesDecodeToTypedErrors(name: String, code: String) throws {
        let error = try Self.mapped(name)
        #expect(error.code == code)
        #expect(!error.message.isEmpty)
    }

    @Test func nameConflictCarriesTheOffendingTool() throws {
        let error = try Self.mapped("register-error-name-conflict")
        #expect(error == .nameConflict(tool: "leo_chat_post", message: "tool \"leo_chat_post\" conflicts with an existing tool"))
    }

    @Test func unrecognisedErrorCodeStaysTyped() throws {
        let envelope = try LeoDaemonEnvelope<LeoClientToolEmpty>.decode(Data(#"{"ok":false,"error":"boom","code":"teapot"}"#.utf8))
        #expect(LeoClientToolsError(envelope: envelope) == .other(code: "teapot", message: "boom"))
    }

    // MARK: - Events

    private func event(_ name: String, _ fixtureName: String) throws -> LeoClientToolsWireEvent? {
        LeoClientToolsWireEvent.decode(name: name, data: try Self.fixture(fixtureName))
    }

    @Test func helloCarriesClientIDAndFeatures() throws {
        guard case .hello(let seq, let clientID, let features) = try event("hello", "hello-provider") else { Issue.record("not a hello"); return }
        #expect(seq == 41)
        #expect(clientID == "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W")
        #expect(features.contains("client_tools"))
    }

    @Test func changedCarriesRevisionAndToolNames() throws {
        guard case .changed(let seq, let revision, let tools) = try event("client_tools.changed", "event-client-tools-changed") else {
            Issue.record("not a changed event")
            return
        }
        #expect(seq == 42)
        #expect(revision == 7)
        #expect(tools == ["browser_click", "browser_navigate", "browser_snapshot"])
    }

    @Test func requestEventDecodesFull() throws {
        guard case .request(let seq, .full(let request)) = try event("client_tool.request", "event-client-tool-request") else {
            Issue.record("not a full request")
            return
        }
        #expect(seq == 43)
        #expect(request.id == "ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K")
        #expect(request.owner == "ct_01JC8Z3K4M5N6P7Q8R9S0T1V2W")
        #expect(request.args == .object(["ref": .string("e12")]))
    }

    @Test func redactedRequestDecodesAsRedactedID() throws {
        guard case .request(let seq, let payload) = try event("client_tool.request", "event-client-tool-request-redacted") else {
            Issue.record("not a request")
            return
        }
        #expect(seq == 43)
        #expect(payload == .redacted(id: "ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K"))
    }

    @Test func cancelledEventCarriesReasonAndRedactedDropsIt() throws {
        guard case .cancelled(let seq, let full) = try event("client_tool.cancelled", "event-client-tool-cancelled") else { Issue.record("not cancelled"); return }
        #expect(seq == 44)
        #expect(full == LeoClientToolCancellation(id: "ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K", agent: "alfred", reason: "timeout"))
        guard case .cancelled(_, let redacted) = try event("client_tool.cancelled", "event-client-tool-cancelled-redacted") else { Issue.record("not cancelled"); return }
        #expect(redacted == LeoClientToolCancellation(id: "ctr_01JC8Z4A5B6C7D8E9F0G1H2J3K", agent: nil, reason: nil))
    }

    @Test func otherEventsKeepOnlyTheirSequence() {
        let data = Data(#"{"seq":50,"agent":"alpha","status":"running"}"#.utf8)
        #expect(LeoClientToolsWireEvent.decode(name: "agent_state_changed", data: data) == .other(seq: 50))
    }

    @Test func unknownFieldsAreIgnored() {
        let data = Data(#"{"seq":9,"revision":3,"tools":[],"future":{"x":1}}"#.utf8)
        #expect(LeoClientToolsWireEvent.decode(name: "client_tools.changed", data: data) == .changed(seq: 9, revision: 3, tools: []))
    }

    @Test func malformedPayloadDecodesToNil() {
        #expect(LeoClientToolsWireEvent.decode(name: "client_tool.request", data: Data("not json".utf8)) == nil)
    }
}
