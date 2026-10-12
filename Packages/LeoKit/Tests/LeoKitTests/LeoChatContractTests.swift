import Foundation
import Testing

@testable import LeoKit

/// One test per chat route: the exact body the daemon sends (spec
/// 2026-10-12-leo-chat, "Wire shapes"), wrapped in its `apiResponse`
/// envelope, decodes to the expected value. Fakes elsewhere can be loose;
/// these pin the contract.
struct LeoChatContractTests {
    /// A spec-shaped Message with every field set.
    static let messageJSON = #"""
    {"id":"01JB","agent":"zeus","direction":"out","kind":"ask","text":"Deploy now?","transcript":"deploy now",
     "reply_to":"01JA","task":"wharf report","run_id":"run-7","state":"answered",
     "answer":{"values":["yes","no"],"text":"both, carefully"},
     "input":{"type":"checkboxes","options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],
              "allow_text":true,"min":1,"max":2,"placeholder":"Anything else?"},
     "ts":"2026-10-12T18:00:00Z",
     "attachments":[{"id":"att1","filename":"plan.pdf","mime":"application/pdf","bytes":2048}]}
    """#

    static let message = LeoChatMessage(
        id: "01JB", agent: "zeus", direction: .outbound, kind: .ask, text: "Deploy now?", transcript: "deploy now",
        replyTo: "01JA", task: "wharf report", runID: "run-7", state: "answered",
        answer: LeoChatAnswer(values: ["yes", "no"], text: "both, carefully"),
        ts: Date(timeIntervalSince1970: 1_791_828_000),
        attachments: [LeoChatAttachment(id: "att1", filename: "plan.pdf", mime: "application/pdf", bytes: 2048)],
        input: try? LeoChatInput(
            kind: .checkboxes, options: [LeoChatOption(value: "yes", label: "Yes"), LeoChatOption(value: "no", label: "No")],
            allowsText: true, min: 1, max: 2, placeholder: "Anything else?"
        )
    )

    static func enveloped(_ data: String) -> [Int: String] {
        [200: #"{"ok":true,"data":\#(data)}"#]
    }

    @Test func threadsDecodesTheThreadList() async throws {
        let body = #"{"threads":[{"agent":"zeus","last_message":\#(Self.messageJSON),"unread":3,"pinned":true},{"agent":"hera","unread":0,"pinned":false}]}"#
        let threads = try await LeoChatHTTPClient(transport: FakeWebTransport(responses: Self.enveloped(body))).threads()

        #expect(threads == [
            LeoChatThread(agent: "zeus", lastMessage: Self.message, unread: 3, isPinned: true),
            LeoChatThread(agent: "hera", lastMessage: nil, unread: 0, isPinned: false),
        ])
    }

    @Test func messagesDecodesAPage() async throws {
        let body = #"{"messages":[\#(Self.messageJSON)],"has_more":true}"#
        let page = try await LeoChatHTTPClient(transport: FakeWebTransport(responses: Self.enveloped(body)))
            .messages(agent: "zeus", query: LeoChatPageQuery())

        #expect(page == LeoChatPage(messages: [Self.message], hasMore: true))
    }

    @Test func sendDecodesTheMessage() async throws {
        let sent = try await LeoChatHTTPClient(transport: FakeWebTransport(responses: Self.enveloped(Self.messageJSON)))
            .send(agent: "zeus", LeoChatDraft(text: "hi"))

        #expect(sent == Self.message)
    }

    @Test func uploadDecodesTheAttachment() async throws {
        let body = #"{"id":"att9","filename":"note.m4a","mime":"audio/mp4","bytes":4096}"#
        let attachment = try await LeoChatHTTPClient(transport: FakeWebTransport(responses: Self.enveloped(body)))
            .upload(LeoChatUpload(filename: "note.m4a", mime: "audio/mp4", data: Data(count: 4)))

        #expect(attachment == LeoChatAttachment(id: "att9", filename: "note.m4a", mime: "audio/mp4", bytes: 4096))
    }

    @Test func downloadReturnsTheRawBytesUnwrapped() async throws {
        let raw = #"{"ok":true,"data":"not an envelope: file bytes"}"#
        let data = try await LeoChatHTTPClient(transport: FakeWebTransport(responses: [200: raw])).download(attachmentID: "att1")

        #expect(data == Data(raw.utf8))
    }

    @Test func answerDecodesTheMessage() async throws {
        let answered = try await LeoChatHTTPClient(transport: FakeWebTransport(responses: Self.enveloped(Self.messageJSON)))
            .answer(agent: "zeus", messageID: "01JB", value: "yes")

        #expect(answered == Self.message)
    }

    @Test func readAcceptsTheEmptyEnvelope() async throws {
        try await LeoChatHTTPClient(transport: FakeWebTransport(responses: [200: #"{"ok":true,"data":null}"#]))
            .markRead(agent: "zeus", upTo: "01JB")
    }

    @Test func aRefusedEnvelopeThrowsItsCodeAndError() async {
        let refused = [200: #"{"ok":false,"error":"no such agent","code":"not_found"}"#]
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: "no such agent", matches: [])) {
            _ = try await LeoChatHTTPClient(transport: FakeWebTransport(responses: refused)).send(agent: "zeus", LeoChatDraft(text: "hi"))
        }
    }
}
