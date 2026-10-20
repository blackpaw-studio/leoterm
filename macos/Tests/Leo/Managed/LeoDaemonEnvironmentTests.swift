import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoDaemonEnvironmentTests {
    private static let staticPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let terminfo = "/Applications/Leo.app/Contents/Resources/terminfo"

    // MARK: probe

    private func probe(
        shell: String? = "/bin/zsh",
        shells: [String] = ["/bin/bash", "/bin/zsh"],
        runner: LoginRunner
    ) -> LeoLoginPathProbe {
        LeoLoginPathProbe(runner: runner, userShell: { shell }, allowedShells: { shells })
    }

    @Test func runsExactlyTheLoginShellPrintenvWithATenSecondTimeout() async {
        let runner = LoginRunner(.success(stdout: "/Users/t/bin:/usr/bin\n"))

        let path = await probe(runner: runner).loginPath()

        #expect(path == "/Users/t/bin:/usr/bin")
        #expect(await runner.calls == [.init(executable: "/bin/zsh", arguments: ["-l", "-c", "/usr/bin/printenv PATH"], timeout: 10)])
    }

    @Test(arguments: [nil, "/usr/local/bin/fish", "zsh", ""])
    func neverRunsAShellThatIsMissingRelativeOrNotListedInEtcShells(shell: String?) async {
        let runner = LoginRunner(.success(stdout: "/usr/bin\n"))

        #expect(await probe(shell: shell, runner: runner).loginPath() == nil)
        #expect(await runner.calls.isEmpty)
    }

    @Test(arguments: [
        "",
        "\n",
        "/usr/bin:/bin\nwelcome to zsh\n",
        "motd\n/usr/bin:/bin\n",
        "usr/bin:/bin\n",
        "/usr/bin::/bin\n",
        "/usr/bin:/bin:\n",
        ":/usr/bin\n",
        "/usr/bin:./bin\n",
        "/usr/bin: /bin\n",
        "/usr/bin:/bin\r\n"
    ])
    func rejectsOutputThatIsNotOneLineOfAbsoluteDirectories(output: String) async {
        let runner = LoginRunner(.success(stdout: output))
        #expect(await probe(runner: runner).loginPath() == nil)
    }

    @Test func acceptsOutputWithoutATrailingNewline() async {
        let runner = LoginRunner(.success(stdout: "/a:/b"))
        #expect(await probe(runner: runner).loginPath() == "/a:/b")
    }

    @Test func aNonZeroExitFallsBack() async {
        let runner = LoginRunner(.success(stdout: "/usr/bin\n", status: 1))
        #expect(await probe(runner: runner).loginPath() == nil)
    }

    @Test func aTimeoutOrLaunchFailureFallsBack() async {
        #expect(await probe(runner: LoginRunner(.failure(LeoDaemonError.timeout))).loginPath() == nil)
        #expect(await probe(runner: LoginRunner(.failure(LeoDaemonError.transport("boom")))).loginPath() == nil)
    }

    @Test(arguments: [
        ("# List of acceptable shells\n/bin/bash\n/bin/zsh\n", ["/bin/bash", "/bin/zsh"]),
        ("  /bin/sh  \n\n# comment\n/bin/dash # trailing\n", ["/bin/sh", "/bin/dash"]),
        ("", [])
    ])
    func parsesEtcShells(contents: String, expected: [String]) {
        #expect(LeoLoginPathProbe.parseEtcShells(contents) == expected)
    }

    // MARK: merge

    private func merge(captured: [String: String]? = nil, loginPath: String? = nil) -> [String: String] {
        LeoDaemonEnvironment.merge(captured: captured, loginPath: loginPath, home: "/Users/t", bundledTerminfo: Self.terminfo)
    }

    @Test func withNothingCapturedTheLoginPathLeadsAndTheStaticPathTrails() {
        let env = merge(loginPath: "/Users/t/.cargo/bin:/usr/bin:/custom")
        #expect(env == [
            "PATH": "/Users/t/.local/bin:/Users/t/.cargo/bin:/usr/bin:/custom:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin",
            "TERMINFO_DIRS": Self.terminfo
        ])
    }

    @Test func withNothingAtAllItIsLocalBinPlusTheStaticPath() {
        #expect(merge()["PATH"] == "/Users/t/.local/bin:" + Self.staticPath)
    }

    @Test func aCapturedPathBeatsTheLoginPath() {
        let env = merge(captured: ["PATH": "/captured:/usr/bin"], loginPath: "/login")
        #expect(env["PATH"] == "/Users/t/.local/bin:/captured:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func anEmptyCapturedPathFallsBackToTheLoginPath() {
        #expect(merge(captured: ["PATH": ""], loginPath: "/login")["PATH"] == "/Users/t/.local/bin:/login:" + Self.staticPath)
    }

    @Test func pathEntriesAreDeduplicatedKeepingTheFirstOccurrence() {
        let env = merge(captured: ["PATH": "/Users/t/.local/bin:/usr/bin:/usr/bin:/x"])
        #expect(env["PATH"] == "/Users/t/.local/bin:/usr/bin:/x:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func capturedKeysWinAndPassThrough() {
        let env = merge(captured: ["LANG": "en_US.UTF-8", "ANTHROPIC_API_KEY": "k", "TERMINFO_DIRS": "/mine"])
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["ANTHROPIC_API_KEY"] == "k")
        #expect(env["TERMINFO_DIRS"] == "/mine")
    }

    @Test func terminfoDirsIsAddedUnlessCaptured() {
        #expect(merge(captured: ["LANG": "C"])["TERMINFO_DIRS"] == Self.terminfo)
    }

    @Test(arguments: [
        "SSH_AUTH_SOCK", "TMUX", "TMUX_PANE", "TMUX_TMPDIR", "TERM_SESSION_ID",
        "__CF_USER_TEXT_ENCODING", "__CFBundleIdentifier", "XPC_FLAGS", "XPC_SERVICE_NAME", "LEO_CONFIG"
    ])
    func dropsSessionSpecificVariables(key: String) {
        let env = merge(captured: [key: "x", "KEEP": "y"])
        #expect(env[key] == nil)
        #expect(env["KEEP"] == "y")
    }

    @Test func dropsOnlyTheListedKeysAndPrefixes() {
        let env = merge(captured: ["TERM": "xterm", "TMUXINATOR": "1", "MY_XPC_X": "1"])
        #expect(env["TERM"] == "xterm")
        #expect(env["MY_XPC_X"] == "1")
        #expect(env["TMUXINATOR"] == nil)  // `TMUX*` is a prefix rule
    }
}

private actor LoginRunner: LeoProcessRunning {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    enum Outcome {
        case success(stdout: String, status: Int32 = 0)
        case failure(any Error)
    }

    private let outcome: Outcome
    private(set) var calls: [Call] = []

    init(_ outcome: Outcome) { self.outcome = outcome }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult {
        calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
        switch outcome {
        case let .success(stdout, status): return LeoProcessResult(stdout: Data(stdout.utf8), stderr: Data(), status: status)
        case let .failure(error): throw error
        }
    }
}
