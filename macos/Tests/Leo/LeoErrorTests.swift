import Testing
@testable import Ghostty

struct LeoErrorTests {
    @Test func descriptionsAreHumanReadable() {
        #expect(LeoError.daemonUnreachable.errorDescription == "The Leo daemon is not reachable.")
        #expect(LeoError.daemon(message: "boom").errorDescription == "Leo daemon error: boom")
        #expect(LeoError.decode(detail: "bad json").errorDescription == "Could not read the daemon response: bad json")
        #expect(LeoError.invalidAgentName("a/../b").errorDescription == "Invalid agent name: a/../b")
    }

    @Test func daemonErrorDefaultsToNoCode() {
        #expect(LeoError.daemon(message: "boom").code == nil)
    }

    @Test func daemonErrorExposesStructuredCode() {
        let error = LeoError.daemon(message: "agent is running", code: "agent_still_running")
        #expect(error.errorDescription == "Leo daemon error: agent is running")
        #expect(error.code == "agent_still_running")
    }

    @Test func nonDaemonErrorsHaveNoCode() {
        #expect(LeoError.daemonUnreachable.code == nil)
        #expect(LeoError.decode(detail: "x").code == nil)
        #expect(LeoError.invalidAgentName("x").code == nil)
    }
}
