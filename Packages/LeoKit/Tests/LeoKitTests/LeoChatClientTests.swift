import Foundation
import Testing

@testable import LeoKit

struct LeoChatClientTests {
    static let message = #"{"id":"01JA","agent":"zeus","direction":"in","kind":"text","text":"hi","state":"pending","ts":0}"#

    @Test func buildsEveryChatRoute() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"threads":[],"messages":[]}}"#])
        let client = LeoChatHTTPClient(transport: transport)
        _ = try await client.threads()
        _ = try await client.messages(agent: "zeus", query: LeoChatPageQuery(before: "01J9", limit: 50, task: "wharf report"))
        _ = try await client.messages(agent: "a/b", query: LeoChatPageQuery())
        try await client.markRead(agent: "zeus", upTo: "01JA")

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "POST"])
        #expect(requests.map(\.path) == [
            "/api/v1/chat/threads",
            "/api/v1/chat/zeus/messages?before=01J9&limit=50&task=wharf%20report",
            "/api/v1/chat/a%2Fb/messages",
            "/api/v1/chat/zeus/read",
        ])
        #expect(try Self.object(requests[3]) as? [String: String] == ["up_to": "01JA"])
    }

    @Test func pageLimitsAreClampedToTheDaemonsMaximum() {
        #expect(LeoChatPageQuery(limit: 500).limit == 200)
        #expect(LeoChatPageQuery(limit: 0).limit == 1)
    }

    @Test func sendPostsTextReplyAndAttachmentsAndReturnsTheMessage() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":\#(Self.message)}"#])
        let sent = try await LeoChatHTTPClient(transport: transport).send(
            agent: "zeus", LeoChatDraft(text: "hi", replyTo: "01J0", attachmentIDs: ["att1"])
        )

        #expect(sent.id == "01JA")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/chat/zeus/messages")
        let body = try Self.object(request)
        #expect(body["text"] as? String == "hi")
        #expect(body["reply_to"] as? String == "01J0")
        #expect(body["attachment_ids"] as? [String] == ["att1"])
    }

    @Test func sendOmitsAnAbsentReplyAndEmptyAttachments() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":\#(Self.message)}"#])
        _ = try await LeoChatHTTPClient(transport: transport).send(agent: "zeus", LeoChatDraft(text: "hi"))
        let body = try Self.object(try #require(await transport.requests.first))
        #expect(Set(body.keys) == ["text"])
    }

    @Test func answerPostsTheAnswerAndReadsTheUpdatedMessage() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":\#(Self.message)}"#])
        let updated = try await LeoChatHTTPClient(transport: transport).answer(agent: "zeus", messageID: "01JA", answer: .choice("allow"))

        #expect(updated?.id == "01JA")
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/api/v1/chat/zeus/messages/01JA/answer")
        #expect(try Self.object(request) as? [String: [String]] == ["values": ["allow"]])
    }

    @Test func anAnswerWithoutABodyIsStillASuccess() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true}"#])
        let updated = try await LeoChatHTTPClient(transport: transport).answer(agent: "zeus", messageID: "01JA", answer: .choice("yes"))
        #expect(updated == nil)
    }

    @Test func otherAnswerFailuresCarryTheDaemonsReason() async {
        let transport = FakeWebTransport(responses: [404: #"{"ok":false,"error":"no such message"}"#])
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: "no such message", matches: [])) {
            _ = try await LeoChatHTTPClient(transport: transport).answer(agent: "zeus", messageID: "01JA", answer: .choice("yes"))
        }
    }

    @Test func uploadSendsOneMultipartFileAndReturnsTheAttachment() async throws {
        let transport = FakeWebTransport(responses: [200: #"{"ok":true,"data":{"id":"att1","filename":"a.png","mime":"image/png","bytes":3}}"#])
        let upload = LeoChatUpload(filename: "a.png", mime: "image/png", data: Data("PNG".utf8))
        let attachment = try await LeoChatHTTPClient(transport: transport, boundary: "B0UND").upload(upload)

        #expect(attachment == LeoChatAttachment(id: "att1", filename: "a.png", mime: "image/png", bytes: 3))
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/chat/uploads")
        #expect(request.contentType == "multipart/form-data; boundary=B0UND")
        #expect(request.body == upload.multipartBody(boundary: "B0UND"))
    }

    @Test func downloadFetchesTheAttachmentBytes() async throws {
        let transport = FakeWebTransport(responses: [200: "PNG"])
        let data = try await LeoChatHTTPClient(transport: transport).download(attachmentID: "att 1")

        #expect(data == Data("PNG".utf8))
        #expect(await transport.requests.map(\.path) == ["/api/v1/chat/attachments/att%201"])
    }

    @Test func socketFlavorUsesTheSameRoutesOverTheUnixSocket() async throws {
        let transport = SocketFake()
        let client = LeoChatHTTPClient(transport: LeoSocketChatTransport(socketPath: "/tmp/leo.sock", transport: transport))
        _ = try await client.threads()
        #expect(await transport.calls == ["/tmp/leo.sock /api/v1/chat/threads"])
    }

    private static func object(_ request: LeoHTTPRequest) throws -> [String: Any] {
        try #require(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    }
}

struct LeoChatMultipartTests {
    @Test func theBodyNamesTheFileAndItsType() throws {
        let upload = LeoChatUpload(filename: #"my "note".m4a"#, mime: "audio/mp4", data: Data([0x00, 0xFF]))
        let body = upload.multipartBody(boundary: "XYZ")

        var expected = Data("--XYZ\r\n".utf8)
        expected.append(Data(#"Content-Disposition: form-data; name="file"; filename="my %22note%22.m4a""#.utf8))
        expected.append(Data("\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        expected.append(Data([0x00, 0xFF]))
        expected.append(Data("\r\n--XYZ--\r\n".utf8))
        #expect(body == expected)
    }

    @Test func theUploadCapIsFiftyMegabytes() {
        #expect(LeoChatUpload.maximumBytes == 50 * 1024 * 1024)
        let tooBig = LeoChatUpload(filename: "a", mime: "application/octet-stream", data: Data(count: 2))
        #expect(throws: LeoChatUpload.Failure.tooLarge(bytes: 2, limit: 1)) { try tooBig.validated(maximumBytes: 1).get() }
    }
}

private actor SocketFake: LeoDaemonTransport {
    var calls: [String] = []

    func send(_ request: LeoHTTPRequest, socketPath: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        calls.append("\(socketPath) \(request.path)")
        return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true,"data":[]}"#.utf8))
    }
}
