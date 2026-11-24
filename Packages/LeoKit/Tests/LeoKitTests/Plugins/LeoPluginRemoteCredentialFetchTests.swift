import Foundation
import Testing

@testable import LeoKit

private let dionysus = LeoHostID.remote("Dionysus")

/// A daemon transport that answers with a canned reply, or throws, and counts the calls.
private actor RemoteTransport: LeoDaemonTransport {
    enum Behavior: Sendable {
        case reply(status: Int, body: String)
        case fail(LeoDaemonError)
    }

    private(set) var requests: [LeoHTTPRequest] = []
    private let behavior: Behavior
    init(_ behavior: Behavior) { self.behavior = behavior }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        switch behavior {
        case .reply(let status, let body): return LeoHTTPResponse(status: status, body: Data(body.utf8))
        case .fail(let error): throw error
        }
    }
}

@MainActor private final class FakeForwarding: LeoPluginRemoteCredentialForwarding {
    var client: (any LeoDaemonClient)?
    private(set) var asked: [LeoHostID] = []
    init(_ transport: RemoteTransport?) {
        client = transport.map { LeoSocketDaemonClient(socketPath: "/tmp/dionysus.sock", transport: $0) }
    }

    func daemon(for host: LeoHostID) -> (any LeoDaemonClient)? {
        asked.append(host)
        return client
    }
}

private func fetcher(
    limiter: LeoPluginRateLimiter = LeoPluginRateLimiter(),
    network: [String] = ["api.anthropic.com", "chatgpt.com"]
) -> LeoPluginFetcher {
    LeoPluginFetcher(
        pluginID: "studio.blackpaw.usage", engine: LeoPluginPermissionEngine(permissions: LeoPluginPermissions(network: network)), limiter: limiter)
}

/// A remote source whose forward closure only counts: if a check let a bad request through, the count shows it.
private final class CountingRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [LeoPluginRemoteFetchRequest] = []
    var requests: [LeoPluginRemoteFetchRequest] { lock.withLock { seen } }

    func source(_ kind: LeoPluginCredentialKind) -> LeoPluginFetchCredentialSource {
        .remote(boundHost: kind.boundHost, reservedHeaders: kind.reservedHeaders) { [self] request in
            lock.withLock { seen.append(request) }
            return LeoPluginFetchResponse(status: 200, headers: [:], body: "ok")
        }
    }
}

struct LeoPluginRemoteCredentialFetchTests {
    // MARK: Checks run before anything is forwarded

    @Test func aRequestThatPassesEveryCheckIsForwardedWithItsValidatedParts() async throws {
        let route = CountingRoute()
        let response = try await fetcher().fetch(
            url: "https://api.anthropic.com/api/oauth/usage?x=1",
            init: LeoPluginFetchInit(method: "post", headers: ["Accept": "application/json"], body: "hi"), credential: route.source(.claudeCode))
        #expect(response.body == "ok")
        #expect(route.requests == [
            LeoPluginRemoteFetchRequest(
                url: "https://api.anthropic.com/api/oauth/usage?x=1", method: "POST",
                headers: [LeoCredentialHeader(name: "Accept", value: "application/json")], body: Data("hi".utf8))
        ])
    }

    @Test func aHostOutsideTheManifestIsDeniedAndNothingIsForwarded() async {
        let route = CountingRoute()
        await #expect(throws: LeoPluginFetchError.self) {
            try await fetcher(network: ["chatgpt.com"]).fetch(
                url: "https://api.anthropic.com/x", init: LeoPluginFetchInit(), credential: route.source(.claudeCode))
        }
        #expect(route.requests.isEmpty)
    }

    @Test func aHostThatIsNotTheKindsBoundHostIsRejectedAndNothingIsForwarded() async {
        let route = CountingRoute()
        await #expect(throws: LeoPluginFetchError.credentialHostMismatch(host: "chatgpt.com")) {
            try await fetcher().fetch(url: "https://chatgpt.com/x", init: LeoPluginFetchInit(), credential: route.source(.claudeCode))
        }
        #expect(route.requests.isEmpty)
    }

    @Test func plainHttpIsRejectedAndNothingIsForwarded() async {
        let route = CountingRoute()
        await #expect(throws: LeoPluginFetchError.self) {
            try await fetcher().fetch(url: "http://api.anthropic.com/x", init: LeoPluginFetchInit(), credential: route.source(.claudeCode))
        }
        #expect(route.requests.isEmpty)
    }

    @Test(arguments: [
        (LeoPluginCredentialKind.claudeCode, "Authorization"), (.claudeCode, "anthropic-beta"), (.claudeCode, "user-agent"),
        (.codex, "authorization"), (.codex, "ChatGPT-Account-Id"),
    ])
    func aHeaderTheDaemonInjectsIsAConflictAndNothingIsForwarded(_ kind: LeoPluginCredentialKind, _ name: String) async {
        let route = CountingRoute()
        await #expect(throws: LeoPluginFetchError.credentialHeaderConflict(name: name)) {
            try await fetcher().fetch(
                url: "https://\(kind.boundHost)/x", init: LeoPluginFetchInit(headers: [name: "mine"]), credential: route.source(kind))
        }
        #expect(route.requests.isEmpty)
    }

    @Test func aMalformedRequestIsRejectedAndNothingIsForwarded() async {
        let route = CountingRoute()
        await #expect(throws: LeoPluginFetchError.self) {
            try await fetcher().fetch(
                url: "https://api.anthropic.com/x", init: LeoPluginFetchInit(method: "TRACE"), credential: route.source(.claudeCode))
        }
        await #expect(throws: LeoPluginFetchError.self) {
            try await fetcher().fetch(
                url: "https://api.anthropic.com/x", init: LeoPluginFetchInit(headers: ["Cookie": "a=b"]), credential: route.source(.claudeCode))
        }
        #expect(route.requests.isEmpty)
    }

    @Test func theRateLimitCoversRemoteRequests() async throws {
        let route = CountingRoute()
        let limiter = LeoPluginRateLimiter(maxPerWindow: 2)
        let sut = fetcher(limiter: limiter)
        for _ in 0..<2 {
            _ = try await sut.fetch(url: "https://api.anthropic.com/x", init: LeoPluginFetchInit(), credential: route.source(.claudeCode))
        }
        do {
            _ = try await sut.fetch(url: "https://api.anthropic.com/x", init: LeoPluginFetchInit(), credential: route.source(.claudeCode))
            Issue.record("expected a rate limit")
        } catch let error as LeoPluginFetchError {
            guard case .rateLimited = error else {
                Issue.record("expected rateLimited, got \(error)")
                return
            }
        }
        #expect(route.requests.count == 2)
    }

    // MARK: Forwarding to the daemon

    @MainActor private func forward(
        _ behavior: RemoteTransport.Behavior?, kind: LeoPluginCredentialKind = .claudeCode
    ) async throws -> (LeoPluginFetchResponse, RemoteTransport?) {
        let transport = behavior.map(RemoteTransport.init)
        let remote = LeoPluginRemoteCredentialFetcher(
            host: dionysus, kind: kind, dir: "/Users/evan/.claude", forwarding: FakeForwarding(transport))
        let response = try await remote.forward(
            LeoPluginRemoteFetchRequest(url: "https://api.anthropic.com/u", method: "GET", headers: [], body: nil))
        return (response, transport)
    }

    @MainActor private func reason(_ behavior: RemoteTransport.Behavior?) async -> String? {
        do {
            _ = try await forward(behavior)
            return nil
        } catch {
            return (error as? LeoPluginFetchError)?.reason ?? "\(error)"
        }
    }

    @Test @MainActor func theDaemonsReplyBecomesTheFetchResponse() async throws {
        let body = Data(#"{"five_hour":1}"#.utf8).base64EncodedString()
        let (response, transport) = try await forward(
            .reply(status: 200, body: #"{"status":200,"headers":[["Content-Type","application/json"],["X-A","1"]],"bodyBase64":"\#(body)"}"#))
        #expect(response == LeoPluginFetchResponse(
            status: 200, headers: ["content-type": "application/json", "x-a": "1"], body: #"{"five_hour":1}"#))
        let sent = try #require(await transport?.requests.first)
        #expect(sent.path == "/credentials/fetch")
    }

    @Test @MainActor func aMachineWithNoLiveConnectionIsOffline() async {
        #expect(await reason(nil) == "credentialMachineUnavailable: Dionysus is offline")
    }

    @Test(arguments: [
        LeoDaemonError.socketMissing(path: "/tmp/x.sock"), .timeout, .transport("closed"), .hostUnavailable("down"),
    ])
    @MainActor func aTransportFailureOrTimeoutIsOffline(_ error: LeoDaemonError) async {
        #expect(await reason(.fail(error)) == "credentialMachineUnavailable: Dionysus is offline")
    }

    @Test @MainActor func anOlderDaemonWithoutTheRoutesIsTooOld() async {
        #expect(await reason(.reply(status: 404, body: "404 page not found"))
            == "credentialMachineUnavailable: Dionysus's Leo is too old to share accounts")
    }

    @Test(arguments: [
        ("credentialHostMismatch", "credentialHostMismatch: nope"), ("credentialHeaderConflict", "credentialHeaderConflict: nope"),
        ("credentialNeedsAuthorization", "credentialNeedsAuthorization: nope"), ("credentialInvalid", "credentialInvalid: nope"),
        ("invalidRequest", "invalid fetch request: nope"), ("bodyTooLarge", "response body is larger than 5 MB"),
        ("networkError", "network error: nope"),
    ])
    @MainActor func theDaemonsErrorReasonsMapToTheExistingJSReasons(_ daemonReason: String, _ expected: String) async {
        let body = #"{"error":{"reason":"\#(daemonReason)","message":"nope"}}"#
        #expect(await reason(.reply(status: 200, body: body)) == expected)
    }

    @Test @MainActor func aReplyBodyOverFiveMegabytesIsTooLarge() async {
        let big = Data(count: LeoPluginFetcher.maxBodyBytes + 1).base64EncodedString()
        #expect(await reason(.reply(status: 200, body: #"{"status":200,"headers":[],"bodyBase64":"\#(big)"}"#)) == "response body is larger than 5 MB")
    }

    @Test @MainActor func theRequestGoesToTheNamedKindAndDirectory() async throws {
        let (_, transport) = try await forward(.reply(status: 200, body: #"{"status":204,"headers":[]}"#), kind: .codex)
        let sent = try #require(await transport?.requests.first)
        let wire = try #require(sent.body)
        let json = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(json["kind"] as? String == "codex")
        #expect(json["dir"] as? String == "/Users/evan/.claude")
        #expect(json["url"] as? String == "https://api.anthropic.com/u")
    }
}
