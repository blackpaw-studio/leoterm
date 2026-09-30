import Testing

@testable import Ghostty

/// B-052: what an attach surface contributes to its tab and window title.
/// (Change Tab Title… sits above this in `BaseTerminalController`; see
/// `LeoTitleIntegrationTests`.)
struct LeoTitleSourceTests {
    @Test func attachSurfaceShowsTheAgentName() {
        let source = LeoTitleSource.resolve(terminalTitle: "👻 Ghostty", isUserSet: false, agentName: "autopilot-scratch")
        #expect(source == .agentName("autopilot-scratch"))
        #expect(source.title == "autopilot-scratch")
    }

    @Test(arguments: ["", "👻", "✳ Claude Code", "tmux: 0:bash*"])
    func terminalOSCTitleIsIgnoredForAnAttach(_ terminalTitle: String) {
        let source = LeoTitleSource.resolve(terminalTitle: terminalTitle, isUserSet: false, agentName: "worker")
        #expect(source.title == "worker")
    }

    @Test func userSetSurfaceTitleWinsOverTheAgentName() {
        let source = LeoTitleSource.resolve(terminalTitle: "My title", isUserSet: true, agentName: "worker")
        #expect(source == .userTitle("My title"))
        #expect(source.title == "My title")
    }

    @Test func nonAttachSurfaceKeepsTheTerminalTitle() {
        let source = LeoTitleSource.resolve(terminalTitle: "~/src — zsh", isUserSet: false, agentName: nil)
        #expect(source == .terminalTitle("~/src — zsh"))
        #expect(source.title == "~/src — zsh")
    }

    @Test func nonAttachUserTitleIsTheUsersTitle() {
        let source = LeoTitleSource.resolve(terminalTitle: "Mine", isUserSet: true, agentName: nil)
        #expect(source == .userTitle("Mine"))
    }

    @Test func emptyAgentNameFallsBackToTheTerminalTitle() {
        let source = LeoTitleSource.resolve(terminalTitle: "zsh", isUserSet: false, agentName: "")
        #expect(source == .terminalTitle("zsh"))
    }
}
