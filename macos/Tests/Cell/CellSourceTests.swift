import Foundation
import Testing
@testable import Ghostty

struct CellSourceTests {
    /// Absolute path to `leo` the command must use (a GUI app's PATH lacks
    /// ~/.local/bin, so bare `leo` fails with "env: leo: No such file").
    /// Kept as an independent literal — assertions must not derive truth
    /// from the production constant they are validating.
    private let leo = NSString(string: "~/.local/bin/leo").expandingTildeInPath

    // MARK: - Helpers

    /// Builds the full expected surface command from first-principle test
    /// literals. The leo path is single-quoted so spaces in the home
    /// directory do not word-split when `/bin/sh -c` interprets the string.
    private func expectedCommand(name: String, host: String? = nil) -> String {
        let env = "/usr/bin/env -u TMUX -u TMUX_PANE"
        let leoQuoted = "'\(leo)'"
        let hostSegment = (host == nil || host == "localhost") ? "" : " --host '\(host!)'"
        return "\(env) \(leoQuoted)\(hostSegment) agent attach --cc '\(name)'"
    }

    // MARK: - Tests

    @Test func ptySourceLeavesCommandNilToInheritShell() {
        let config = CellSource.pty.surfaceConfiguration()
        #expect(config.command == nil)
    }

    @Test func agentSourceRunsLeoControlModeAttach() {
        let config = CellSource.agent(name: "leoterm").surfaceConfiguration()
        #expect(config.command == expectedCommand(name: "leoterm"))
    }

    @Test func agentCommandUsesAbsoluteLeoPathNotBareLeo() {
        // Regression: bare `leo` fails under a GUI app's minimal PATH.
        let command = CellSource.agent(name: "x").surfaceConfiguration().command
        #expect(command?.contains("'\(leo)'") == true)
        #expect(command?.contains(" env -u TMUX -u TMUX_PANE leo agent") == false)
    }

    @Test func agentSourcePreservesExactAgentName() {
        let name = "leo-coding-blackpaw-studio-beacon"
        let config = CellSource.agent(name: name).surfaceConfiguration()
        #expect(config.command == expectedCommand(name: name))
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
        #expect(command?.hasSuffix("'\(leo)' agent attach --cc 'x'") == true)
    }

    @Test func isAgentDistinguishesCellKinds() {
        #expect(CellSource.pty.isAgent == false)
        #expect(CellSource.agent(name: "x").isAgent == true)
    }

    // MARK: - Host-aware command tests

    @Test func agentLocalhostExplicitMatchesDefault() {
        let explicit = CellSource.agent(name: "alpha").surfaceConfiguration(host: "localhost").command
        let defaulted = CellSource.agent(name: "alpha").surfaceConfiguration().command
        #expect(explicit == expectedCommand(name: "alpha"))
        #expect(explicit == defaulted)
    }

    @Test func agentRemoteHostInsertsHostFlag() {
        let command = CellSource.agent(name: "alpha").surfaceConfiguration(host: "dionysus").command
        #expect(command == expectedCommand(name: "alpha", host: "dionysus"))
    }

    @Test func ptyRemoteHostLeavesCommandNil() {
        let config = CellSource.pty.surfaceConfiguration(host: "dionysus")
        #expect(config.command == nil)
    }
}
