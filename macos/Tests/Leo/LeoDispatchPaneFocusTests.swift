import Foundation
import Testing

@testable import Ghostty

/// B-271: a dispatch viewer left in its caller's own tmux session is
/// brought forward on Leo's tmux server (`tmux -L leo`), over ssh for a
/// remote host. The process boundary is faked.
struct LeoDispatchPaneFocusTests {
    @Test func localFocusSelectsThePanesWindowOnLeosServer() throws {
        let command = try LeoDispatchPaneFocus.local(tmux: "/opt/homebrew/bin/tmux", pane: "%7")
        #expect(command.executable == "/opt/homebrew/bin/tmux")
        #expect(command.arguments == ["-L", "leo", "select-window", "-t", "%7", ";", "select-pane", "-t", "%7"])
    }

    @Test func localTmuxIsFoundInTheUsualPlacesBeforePATH() {
        let brew = LeoDispatchPaneFocus.resolveLocalTmux(path: "/x/bin") { $0 == "/opt/homebrew/bin/tmux" || $0 == "/x/bin/tmux" }
        #expect(brew == "/opt/homebrew/bin/tmux")
        let usrBin = LeoDispatchPaneFocus.resolveLocalTmux(path: nil) { $0 == "/usr/bin/tmux" }
        #expect(usrBin == "/usr/bin/tmux")
        let onPath = LeoDispatchPaneFocus.resolveLocalTmux(path: "/a:/x/bin") { $0 == "/x/bin/tmux" }
        #expect(onPath == "/x/bin/tmux")
        #expect(LeoDispatchPaneFocus.resolveLocalTmux(path: "/a") { _ in false } == nil)
    }

    @Test func remoteFocusPassesThePaneAsAnArgumentNotScript() throws {
        let ssh = LeoSSHCommand(configuration: LeoHostConfiguration(name: "work", sshTarget: "evan@work"))
        let command = try LeoDispatchPaneFocus.remote(ssh: ssh, sshExecutable: "/usr/bin/ssh", pane: "%7")
        #expect(command.executable == "/usr/bin/ssh")
        let script = try leoShellQuote(LeoDispatchPaneFocus.remoteScript)
        #expect(command.arguments == ["-o", "BatchMode=yes", "evan@work", "'/bin/sh' '-c' \(script) 'leo-focus' '%7'"])
        #expect(!LeoDispatchPaneFocus.remoteScript.contains("%7"), "the script is fixed")
        #expect(LeoDispatchPaneFocus.remoteScript.contains(#""$1""#))
    }

    @Test(arguments: ["", "7", "%", "%7;kill-server", "%7 ", "$(x)"])
    func refusesAnythingButAPaneID(_ pane: String) {
        let ssh = LeoSSHCommand(configuration: LeoHostConfiguration(name: "work", sshTarget: "work"))
        #expect(throws: LeoDispatchPaneFocusError.invalidPane) { try LeoDispatchPaneFocus.local(tmux: "/t", pane: pane) }
        #expect(throws: LeoDispatchPaneFocusError.invalidPane) {
            try LeoDispatchPaneFocus.remote(ssh: ssh, sshExecutable: "/usr/bin/ssh", pane: pane)
        }
    }

    @Test func aHostPicksLocalTmuxOrItsOwnSSHSettings() throws {
        let work = LeoHostConfiguration(name: "work", sshTarget: "work")
        let local = try LeoDispatchPaneFocus.command(host: .local, pane: "%7", hosts: [], sshExecutable: "/ssh") { "/t/tmux" }
        #expect(local.executable == "/t/tmux")
        let remote = try LeoDispatchPaneFocus.command(host: .remote("work"), pane: "%7", hosts: [work], sshExecutable: "/ssh") { nil }
        #expect(remote.executable == "/ssh")
        #expect(throws: LeoDispatchPaneFocusError.tmuxNotFound) {
            try LeoDispatchPaneFocus.command(host: .local, pane: "%7", hosts: [], sshExecutable: "/ssh") { nil }
        }
        #expect(throws: LeoDispatchPaneFocusError.hostNotConfigured("gone")) {
            try LeoDispatchPaneFocus.command(host: .remote("gone"), pane: "%7", hosts: [work], sshExecutable: "/ssh") { "/t" }
        }
    }

    @Test func aFocusRunsTheCommand() async throws {
        let runner = PaneFocusRunner(status: 0, stderr: "")
        let command = LeoDispatchPaneFocusCommand(executable: "/t", arguments: ["a"])
        try await LeoDispatchPaneFocuser(runner: runner).focus(command)
        #expect(await runner.calls.map(\.executable) == ["/t"])
        #expect(await runner.calls.map(\.arguments) == [["a"]])
    }

    @Test func aFailedFocusIsReported() async {
        let runner = PaneFocusRunner(status: 1, stderr: "can't find pane: %7\n")
        let command = LeoDispatchPaneFocusCommand(executable: "/t", arguments: [])
        await #expect(throws: LeoDispatchPaneFocusError.failed("can't find pane: %7")) {
            try await LeoDispatchPaneFocuser(runner: runner).focus(command)
        }
    }
}

private actor PaneFocusRunner: LeoProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    let status: Int32
    let stderr: String

    init(status: Int32, stderr: String) {
        self.status = status
        self.stderr = stderr
    }

    func run(executable: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append((executable, arguments))
        return LeoProcessResult(stdout: Data(), stderr: Data(stderr.utf8), status: status)
    }
}
