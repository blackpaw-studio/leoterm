import Foundation
import Testing

@testable import Ghostty

/// B-288: leo >= 0.47 attaches a dispatch writable with `--rw`. The app
/// can't read a version off the CLI, so it looks for the flag in
/// `dispatch attach --help` and stays read-only on any doubt.
struct LeoDispatchAccessHelpTests {
    /// The flag line as leo >= 0.47 prints it (internal/cli/dispatch_attach.go).
    private static let rwHelp = """
    Show an interactive dispatch's TUI, read-only by default, in this terminal.

    With --rw the client is read-write: keystrokes and the mouse reach
    the subagent, which marks the run steered.

    Usage:
      leo dispatch attach <id> [flags]

    Examples:
      leo dispatch attach d-12ab34
      leo dispatch attach d-12ab34 --rw

    Flags:
      -h, --help          help for attach
          --host string   remote host name (from client.hosts), or "localhost"
          --rw            attach read-write: input typed there reaches the subagent and marks the run steered; multiple writers can type at once
    """

    /// Verbatim `leo dispatch attach --help` of leo 0.45.0.
    private static let leo045Help = """
    Show an interactive dispatch's TUI, read-only, in this terminal.

    The dispatch's tmux window is linked into a throwaway session and attached
    with a read-only client, so nothing typed can reach the dispatch and no pane
    is moved. Detaching (or the dispatch ending) removes the throwaway session;
    the dispatch is untouched. Only a dispatch that has its own tmux window can
    be attached: headless dispatches, ended ones, and panes split into their
    caller's window are refused with exit status 1.

    With --host, runs the remote leo over ssh -tt.

    Usage:
      leo dispatch attach <id> [flags]

    Examples:
      leo dispatch attach d-12ab34
      leo dispatch attach d-12ab34 --host prod

    Flags:
      -h, --help          help for attach
          --host string   remote host name (from client.hosts), or "localhost"

    Global Flags:
      -c, --config string   path to leo.yaml (default: auto-detect)
    """

    @Test func helpWithTheRwFlagLineIsReadWrite() {
        #expect(LeoDispatchAccess(fromHelp: Self.rwHelp) == .readWrite)
    }

    @Test func helpOfLeo045IsReadOnly() {
        #expect(LeoDispatchAccess(fromHelp: Self.leo045Help) == .readOnly)
    }

    /// Prose, examples and a longer flag that starts with `--rw` are not the flag.
    @Test func aMentionOfRwInProseIsNotTheFlag() {
        let help = """
        With --rw the client is read-write.
          leo dispatch attach d-1 --rw
        Flags:
              --rwx   something else
        """
        #expect(LeoDispatchAccess(fromHelp: help) == .readOnly)
    }
}

@MainActor struct LeoDispatchAccessProbeTests {
    private static let rwHelp = "Flags:\n  -h, --help   help\n      --rw   attach read-write\n"
    private static let roHelp = "Flags:\n  -h, --help   help\n"
    private static let box = LeoHostConfiguration(name: "box", sshTarget: "evan@box.example", remoteLeoPath: "/opt/leo")

    private func makeProbe(
        runner: ProbeRunner,
        executable: @escaping () throws -> String = { "/leo" },
        hosts: [LeoHostConfiguration] = [box],
        modified: @escaping (String) -> Date? = { _ in nil }
    ) -> LeoDispatchAccessProbe {
        LeoDispatchAccessProbe(
            runner: runner, executable: executable, sshExecutable: "/usr/bin/ssh", hosts: { hosts }, modificationDate: modified
        )
    }

    @Test func localProbeRunsDispatchAttachHelpOnTheResolvedLeo() async {
        let runner = ProbeRunner(.success(status: 0, stdout: Self.rwHelp))
        let access = await makeProbe(runner: runner, executable: { "/opt/bin/leo" }).access(for: .local)
        #expect(access == .readWrite)
        let calls = await runner.calls
        #expect(calls.map(\.executable) == ["/opt/bin/leo"])
        #expect(calls.map(\.arguments) == [["dispatch", "attach", "--help"]])
        #expect(calls.map(\.timeout) == [LeoDispatchAccessProbe.timeout])
    }

    @Test func remoteProbeRunsTheRemoteLeoOverBatchModeSSH() async throws {
        let runner = ProbeRunner(.success(status: 0, stdout: Self.rwHelp))
        let access = await makeProbe(runner: runner).access(for: .remote("box"))
        #expect(access == .readWrite)
        let calls = await runner.calls
        #expect(calls.map(\.executable) == ["/usr/bin/ssh"])
        let expected = try LeoSSHCommand(configuration: Self.box).execArguments(remoteCommand: ["/opt/leo", "dispatch", "attach", "--help"])
        #expect(calls.map(\.arguments) == [expected])
        #expect(expected.starts(with: ["-o", "BatchMode=yes"]))
    }

    @Test func anUnconfiguredRemoteHostIsReadOnly() async {
        let runner = ProbeRunner(.success(status: 0, stdout: Self.rwHelp))
        let access = await makeProbe(runner: runner).access(for: .remote("elsewhere"))
        #expect(access == .readOnly)
        #expect(await runner.calls.isEmpty, "nothing to ask")
    }

    @Test func anOlderLeoIsReadOnly() async {
        let runner = ProbeRunner(.success(status: 0, stdout: Self.roHelp))
        #expect(await makeProbe(runner: runner).access(for: .local) == .readOnly)
    }

    @Test(arguments: [ProbeOutcome.success(status: 1, stdout: ProbeOutcomeFixtures.rw), .failure])
    func aFailedProbeIsReadOnlyAndNotCached(_ outcome: ProbeOutcome) async {
        let runner = ProbeRunner(outcome)
        let probe = makeProbe(runner: runner)
        #expect(await probe.access(for: .local) == .readOnly)
        await runner.set(.success(status: 0, stdout: Self.rwHelp))
        #expect(await probe.access(for: .local) == .readWrite, "the next call probes again")
        #expect(await runner.calls.count == 2)
    }

    @Test func aMissingExecutableIsReadOnlyWithoutProbing() async {
        struct NoLeo: Error {}
        let runner = ProbeRunner(.success(status: 0, stdout: Self.rwHelp))
        #expect(await makeProbe(runner: runner, executable: { throw NoLeo() }).access(for: .local) == .readOnly)
        #expect(await runner.calls.isEmpty)
    }

    @Test func aSuccessfulProbeIsCachedPerHost() async {
        let runner = ProbeRunner(.success(status: 0, stdout: Self.rwHelp))
        let other = LeoHostConfiguration(name: "other", sshTarget: "other.example")
        let probe = makeProbe(runner: runner, hosts: [Self.box, other])
        _ = await probe.access(for: .local)
        _ = await probe.access(for: .local)
        _ = await probe.access(for: .remote("box"))
        _ = await probe.access(for: .remote("box"))
        _ = await probe.access(for: .remote("other"))
        #expect(await runner.calls.count == 3, "local once, each remote once")
    }

    @Test func aChangedLocalExecutableIsProbedAgain() async {
        let runner = ProbeRunner(.success(status: 0, stdout: Self.roHelp))
        var modified = Date(timeIntervalSince1970: 100)
        let probe = makeProbe(runner: runner, modified: { _ in modified })
        #expect(await probe.access(for: .local) == .readOnly)
        await runner.set(.success(status: 0, stdout: Self.rwHelp))
        #expect(await probe.access(for: .local) == .readOnly, "same binary: still the cached answer")
        modified = Date(timeIntervalSince1970: 200)
        #expect(await probe.access(for: .local) == .readWrite, "leo was upgraded in place")
    }

    @Test func anEditedRemoteHostIsProbedAgain() async {
        let runner = ProbeRunner(.success(status: 0, stdout: Self.roHelp))
        var hosts = [Self.box]
        let probe = LeoDispatchAccessProbe(
            runner: runner, executable: { "/leo" }, sshExecutable: "/usr/bin/ssh", hosts: { hosts }, modificationDate: { _ in nil }
        )
        _ = await probe.access(for: .remote("box"))
        hosts = [LeoHostConfiguration(id: Self.box.id, name: "box", sshTarget: "evan@box.example", remoteLeoPath: "/usr/local/bin/leo")]
        await runner.set(.success(status: 0, stdout: Self.rwHelp))
        #expect(await probe.access(for: .remote("box")) == .readWrite)
    }
}

enum ProbeOutcomeFixtures { static let rw = "Flags:\n      --rw   attach read-write\n" }

enum ProbeOutcome: Sendable {
    case success(status: Int32, stdout: String)
    /// The runner throws (timeout, spawn failure).
    case failure
}

private struct ProbeFailure: Error {}

private actor ProbeRunner: LeoProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String], timeout: TimeInterval)] = []
    private var outcome: ProbeOutcome

    init(_ outcome: ProbeOutcome) { self.outcome = outcome }

    func set(_ outcome: ProbeOutcome) { self.outcome = outcome }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult {
        calls.append((executable, arguments, timeout))
        switch outcome {
        case .success(let status, let stdout): return LeoProcessResult(stdout: Data(stdout.utf8), stderr: Data(), status: status)
        case .failure: throw ProbeFailure()
        }
    }
}
