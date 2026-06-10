import Testing
@testable import Ghostty

struct LeoErrorTests {
    @Test func descriptionsAreHumanReadable() {
        #expect(LeoError.daemonUnreachable.errorDescription == "The Leo daemon is not reachable.")
        #expect(LeoError.daemon(message: "boom").errorDescription == "Leo daemon error: boom")
        #expect(LeoError.decode(detail: "bad json").errorDescription == "Could not read the daemon response: bad json")
    }
}
