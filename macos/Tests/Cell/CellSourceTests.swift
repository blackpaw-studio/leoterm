import Testing
@testable import Ghostty

struct CellSourceTests {
    @Test func ptySourceLeavesCommandNilToInheritShell() {
        let config = CellSource.pty.surfaceConfiguration
        #expect(config.command == nil)
    }

    @Test func agentSourceRunsLeoControlModeAttach() {
        let config = CellSource.agent(name: "leoterm").surfaceConfiguration
        #expect(config.command == "leo agent attach --cc leoterm")
    }

    @Test func agentSourcePreservesExactAgentName() {
        let name = "leo-coding-blackpaw-studio-beacon"
        let config = CellSource.agent(name: name).surfaceConfiguration
        #expect(config.command == "leo agent attach --cc \(name)")
    }

    @Test func isAgentDistinguishesCellKinds() {
        #expect(CellSource.pty.isAgent == false)
        #expect(CellSource.agent(name: "x").isAgent == true)
    }
}
