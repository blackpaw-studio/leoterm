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
}
