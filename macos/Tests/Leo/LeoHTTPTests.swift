import Testing
import Foundation
@testable import Ghostty

struct LeoHTTPTests {
    @Test func buildsGetRequestBytes() {
        let req = LeoHTTPRequest(method: "GET", path: "/agents/list")
        let text = String(data: req.serialized(), encoding: .utf8)!
        #expect(text.hasPrefix("GET /agents/list HTTP/1.1\r\n"))
        #expect(text.contains("Host: localhost\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func buildsPostRequestWithJSONBody() {
        let body = Data(#"{"template":"coding","repo":"a/b"}"#.utf8)
        let req = LeoHTTPRequest(method: "POST", path: "/agents/spawn", body: body)
        let text = String(data: req.serialized(), encoding: .utf8)!
        #expect(text.contains("POST /agents/spawn HTTP/1.1\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.hasSuffix(#"{"template":"coding","repo":"a/b"}"#))
    }

    @Test func parsesResponseStatusAndBody() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"ok\":true}\r\n".utf8)
        let resp = try LeoHTTPResponse.parse(raw)
        #expect(resp.status == 200)
        #expect(String(data: resp.body, encoding: .utf8) == "{\"ok\":true}\r\n")
    }

    @Test func parseRejectsMalformedResponse() {
        let raw = Data("not http".utf8)
        #expect(throws: LeoError.self) { _ = try LeoHTTPResponse.parse(raw) }
    }
}
