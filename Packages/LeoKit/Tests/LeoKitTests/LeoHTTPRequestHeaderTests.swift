import Foundation
import Testing

@testable import LeoKit

struct LeoHTTPRequestHeaderTests {
    @Test func serializesIfMatch() throws {
        let request = LeoHTTPRequest(
            method: "PUT", path: "/config/web", body: Data("{}".utf8),
            headers: ["If-Match": "sha256:abc"]
        )
        let wire = try #require(String(data: try request.serialized(), encoding: .utf8))

        #expect(wire.contains("\r\nIf-Match: sha256:abc\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n{}"))
    }

    @Test func serializesWithoutHeadersAsBefore() throws {
        let wire = try #require(String(data: try LeoHTTPRequest(method: "GET", path: "/health").serialized(), encoding: .utf8))
        #expect(wire == "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    }

    @Test(arguments: [
        ["If-Match": "x\r\nX-Evil: 1"],
        ["If-Match": "x\nX-Evil: 1"],
        ["If-Match\r\nX-Evil": "1"],
        ["": "1"],
        ["If Match": "1"],
    ])
    func rejectsHeaderInjection(headers: [String: String]) {
        let request = LeoHTTPRequest(method: "PUT", path: "/config/web", headers: headers)
        #expect(throws: LeoDaemonError.self) { _ = try request.serialized() }
    }

    @Test func httpsRequestCarriesHeaders() throws {
        let transport = LeoHTTPSTransport(endpoint: LeoRemoteEndpoint(baseURL: URL(string: "https://leo.example.com")!, token: "tok"))
        let request = LeoHTTPRequest(method: "PUT", path: "/api/v1/config/web", body: Data("{}".utf8), headers: ["If-Match": "sha256:abc"])
        let built = try transport.urlRequest(for: request, timeout: 5)

        #expect(built.value(forHTTPHeaderField: "If-Match") == "sha256:abc")
        #expect(built.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func httpsRequestRejectsHeaderInjection() {
        let transport = LeoHTTPSTransport(endpoint: LeoRemoteEndpoint(baseURL: URL(string: "https://leo.example.com")!, token: nil))
        let request = LeoHTTPRequest(method: "PUT", path: "/x", headers: ["If-Match": "a\r\nb: c"])
        #expect(throws: LeoDaemonError.self) { _ = try transport.urlRequest(for: request, timeout: 5) }
    }
}
