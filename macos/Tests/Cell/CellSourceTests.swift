import Testing
@testable import Ghostty

struct CellSourceTests {
    @Test func ptySourceLeavesCommandNilToInheritShell() {
        let config = CellSource.pty.surfaceConfiguration()
        #expect(config.command == nil)
    }

    @Test func agentSourceRunsLeoControlModeAttach() {
        let config = CellSource.agent(name: "leoterm").surfaceConfiguration()
        #expect(config.command == "/usr/bin/env -u TMUX -u TMUX_PANE leo agent attach --cc leoterm")
    }

    @Test func agentSourcePreservesExactAgentName() {
        let name = "leo-coding-blackpaw-studio-beacon"
        let config = CellSource.agent(name: name).surfaceConfiguration()
        #expect(config.command == "/usr/bin/env -u TMUX -u TMUX_PANE leo agent attach --cc \(name)")
    }

    /// The control-mode client (`tmux -CC` / `leo agent attach --cc`) refuses
    /// to start when `$TMUX` is inherited (tmux's session-nesting guard), which
    /// makes the surface command exit immediately. The agent command must clear
    /// `$TMUX`/`$TMUX_PANE` so the client can attach when Leo itself was
    /// launched from inside tmux.
    @Test func agentSourceClearsTmuxEnvSoClientCanAttach() {
        let command = CellSource.agent(name: "x").surfaceConfiguration().command
        #expect(command?.contains("-u TMUX") == true)
        #expect(command?.contains("-u TMUX_PANE") == true)
        #expect(command?.hasSuffix("leo agent attach --cc x") == true)
    }

    @Test func isAgentDistinguishesCellKinds() {
        #expect(CellSource.pty.isAgent == false)
        #expect(CellSource.agent(name: "x").isAgent == true)
    }

    // MARK: - Host-aware command tests

    @Test func agentLocalhostExplicitMatchesDefault() {
        let explicit = CellSource.agent(name: "alpha").surfaceConfiguration(host: "localhost").command
        let defaulted = CellSource.agent(name: "alpha").surfaceConfiguration().command
        #expect(explicit == "/usr/bin/env -u TMUX -u TMUX_PANE leo agent attach --cc alpha")
        #expect(explicit == defaulted)
    }

    @Test func agentRemoteHostInsertsHostFlag() {
        let command = CellSource.agent(name: "alpha").surfaceConfiguration(host: "dionysus").command
        #expect(command == "/usr/bin/env -u TMUX -u TMUX_PANE leo --host dionysus agent attach --cc alpha")
    }

    @Test func ptyRemoteHostLeavesCommandNil() {
        let config = CellSource.pty.surfaceConfiguration(host: "dionysus")
        #expect(config.command == nil)
    }
}
