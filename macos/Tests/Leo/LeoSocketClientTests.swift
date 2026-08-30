import Testing
import Foundation
@testable import Ghostty

struct LeoSocketClientTests {
    @Test func cliArgsWithoutHostAreUnchanged() {
        #expect(LeoSocketClient.cliArgs(host: nil, ["template", "list", "--json"])
            == ["template", "list", "--json"])
    }

    @Test func cliArgsForLocalhostAreUnchanged() {
        #expect(LeoSocketClient.cliArgs(host: "localhost", ["template", "list", "--json"])
            == ["template", "list", "--json"])
    }

    @Test func cliArgsForRemoteHostPrependHostFlag() {
        #expect(LeoSocketClient.cliArgs(host: "dionysus", ["template", "list", "--json"])
            == ["--host", "dionysus", "template", "list", "--json"])
    }

    // MARK: - Path segment validation (path traversal defense)

    @Test func pathSegmentAllowsSimpleAgentNames() throws {
        #expect(try LeoSocketClient.pathSegment(for: "my-agent_1.2") == "my-agent_1.2")
    }

    @Test func pathSegmentRejectsEmbeddedSlash() {
        // A raw `/` would previously survive `.urlPathAllowed` unescaped and
        // could redirect the request to an unintended path, e.g.
        // "a/../b/stop" instead of "a%2F..%2Fb/stop".
        #expect(throws: LeoError.invalidAgentName("a/../b")) {
            _ = try LeoSocketClient.pathSegment(for: "a/../b")
        }
    }

    @Test func pathSegmentRejectsEmptyName() {
        #expect(throws: LeoError.invalidAgentName("")) {
            _ = try LeoSocketClient.pathSegment(for: "")
        }
    }

    @Test func pathSegmentRejectsOtherUnsafeCharacters() {
        #expect(throws: LeoError.invalidAgentName("has space")) {
            _ = try LeoSocketClient.pathSegment(for: "has space")
        }
    }
}
