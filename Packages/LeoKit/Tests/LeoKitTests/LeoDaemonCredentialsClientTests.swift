import Foundation
import Testing

@testable import LeoKit

private actor StubTransport: LeoDaemonTransport {
    private(set) var requests: [LeoHTTPRequest] = []
    private(set) var timeouts: [TimeInterval] = []
    private let reply: LeoHTTPResponse
    init(status: Int = 200, body: String) { reply = LeoHTTPResponse(status: status, body: Data(body.utf8)) }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        timeouts.append(timeout)
        return reply
    }
}

private func client(_ transport: StubTransport) -> LeoSocketDaemonClient {
    LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
}

private func json(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct LeoDaemonCredentialsClientTests {
    @Test func listsAccountsForAKind() async throws {
        let transport = StubTransport(body: #"{"accounts":[{"kind":"claude-code","dir":"/Users/evan/.claude-blackpaw-leo","label":"blackpaw-leo"}]}"#)
        let accounts = try await client(transport).credentialAccounts(kind: .claudeCode)
        #expect(accounts == [LeoCredentialAccount(kind: .claudeCode, dir: "/Users/evan/.claude-blackpaw-leo", label: "blackpaw-leo")])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/credentials/accounts?kind=claude-code")
    }

    @Test func listsEveryAccountWhenNoKindIsGiven() async throws {
        let transport = StubTransport(body: #"{"accounts":[]}"#)
        _ = try await client(transport).credentialAccounts(kind: nil)
        #expect(await transport.requests.first?.path == "/credentials/accounts")
    }

    @Test func checkPostsKindAndDir() async throws {
        let transport = StubTransport(body: #"{"ok":true}"#)
        try await client(transport).credentialCheck(kind: .codex, dir: "/Users/evan/.codex")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/credentials/check")
        let body = try json(request.body)
        #expect(Set(body.keys) == ["kind", "dir"])
        #expect(body["kind"] as? String == "codex")
        #expect(body["dir"] as? String == "/Users/evan/.codex")
    }

    @Test func checkSurfacesTheDaemonsReasonAndMessage() async throws {
        let transport = StubTransport(body: #"{"error":{"reason":"credentialNeedsAuthorization","message":"Keychain would ask"}}"#)
        await #expect(throws: LeoCredentialRemoteError(reason: "credentialNeedsAuthorization", message: "Keychain would ask")) {
            try await client(transport).credentialCheck(kind: .claudeCode, dir: "/d")
        }
    }

    @Test func fetchEncodesTheExactContractAndUsesTheLongTimeout() async throws {
        let transport = StubTransport(body: #"{"status":200,"headers":[["content-type","application/json"]],"bodyBase64":"eyJhIjoxfQ=="}"#)
        let request = LeoCredentialFetchRequest(
            kind: .claudeCode, dir: "/Users/evan/.claude", url: "https://api.anthropic.com/api/oauth/usage", method: "POST",
            headers: [LeoCredentialHeader(name: "Accept", value: "application/json")], body: Data("hi".utf8))
        let reply = try await client(transport).credentialFetch(request)

        #expect(reply.status == 200)
        #expect(reply.headers == [LeoCredentialHeader(name: "content-type", value: "application/json")])
        #expect(reply.body == Data(#"{"a":1}"#.utf8))
        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "POST" && sent.path == "/credentials/fetch")
        let body = try json(sent.body)
        #expect(Set(body.keys) == ["kind", "dir", "url", "method", "headers", "bodyBase64"])
        #expect(body["headers"] as? [[String]] == [["Accept", "application/json"]])
        #expect(body["bodyBase64"] as? String == Data("hi".utf8).base64EncodedString())
        #expect(await transport.timeouts == [LeoSocketDaemonClient.credentialFetchTimeout])
        #expect(LeoSocketDaemonClient.credentialFetchTimeout == 35)
    }

    @Test func aBodylessFetchOmitsBodyBase64AndAnEmptyReplyBodyDecodesEmpty() async throws {
        let transport = StubTransport(body: #"{"status":204,"headers":[]}"#)
        let reply = try await client(transport).credentialFetch(
            LeoCredentialFetchRequest(kind: .codex, dir: "/d", url: "https://chatgpt.com/x", method: "GET", headers: [], body: nil))
        #expect(reply.body.isEmpty)
        let body = try json(await transport.requests.first?.body)
        #expect(body["bodyBase64"] == nil)
    }

    @Test(arguments: [
        "credentialHostMismatch", "credentialHeaderConflict", "credentialNeedsAuthorization", "credentialInvalid",
        "invalidRequest", "bodyTooLarge", "networkError",
    ])
    func fetchThrowsTheDaemonsErrorBody(_ reason: String) async throws {
        let transport = StubTransport(body: #"{"error":{"reason":"\#(reason)","message":"nope"}}"#)
        await #expect(throws: LeoCredentialRemoteError(reason: reason, message: "nope")) {
            try await client(transport).credentialFetch(
                LeoCredentialFetchRequest(kind: .codex, dir: "/d", url: "https://chatgpt.com/x", method: "GET", headers: [], body: nil))
        }
    }

    @Test func anOlderDaemonsNotFoundIsADaemonError() async throws {
        let transport = StubTransport(status: 404, body: "404 page not found")
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: "HTTP 404", matches: [])) {
            _ = try await client(transport).credentialAccounts(kind: nil)
        }
    }

    @Test func aReplyThatIsNotTheContractIsADecodingError() async throws {
        let transport = StubTransport(body: #"{"unexpected":true}"#)
        await #expect(throws: LeoDaemonError.self) {
            _ = try await client(transport).credentialAccounts(kind: nil)
        }
    }
}
