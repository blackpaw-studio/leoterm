import Foundation
import LeoKit
import Testing

@testable import Ghostty

/// A11: what the menu bar extra shows for each daemon state, and the exact
/// commands its actions run.
struct LeoMenuBarModelTests {
    private static func row(_ name: String, status: LeoAgentStatus = .running, attention: LeoAttentionBadge? = nil) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: status, activity: .idle, actionDetail: nil, attention: attention)
    }

    private static func inputs(
        _ connectivity: LeoConnectivity = .connected, rows: [LeoAgentRow] = [], version: String? = nil,
        managed: Bool = false, outside: Bool = false, serverOnly: Bool = false, restarting: Bool = false, hasLog: Bool = true
    ) -> LeoMenuBarInputs {
        LeoMenuBarInputs(
            snapshot: LeoSidebarSnapshot(rows: rows, connectivity: connectivity, generation: 1),
            version: version, isManaged: managed, isOutsideDaemon: outside, serverOnly: serverOnly, isRestarting: restarting, hasLogFile: hasLog
        )
    }

    private static func status(_ items: [LeoMenuBarItem]) -> LeoMenuBarItem { items[0] }

    // MARK: Status line

    @Test func aDaemonOutsideLeoAppIsNeverCalledManagedByLeo() {
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs(version: "0.57.0", managed: true, outside: true)))
            == .status(title: "A leo daemon is running outside Leo.app", detail: "v0.57.0"))
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs(managed: true, outside: true)))
            == .status(title: "A leo daemon is running outside Leo.app", detail: nil))
    }

    @Test func connectedShowsTheRunningDaemonWithVersionAndManagement() {
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs(version: "0.57.0", managed: true)))
            == .status(title: "Daemon running", detail: "v0.57.0 · managed by Leo"))
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs()))
            == .status(title: "Daemon running", detail: nil))
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs(version: "0.57.0")))
            == .status(title: "Daemon running", detail: "v0.57.0"))
    }

    @Test func everyOtherConnectivityHasItsOwnStatus() {
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs(.loading))) == .status(title: "Connecting to daemon…", detail: nil))
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs(.failed(message: "no socket"))))
            == .status(title: "Daemon not running", detail: nil))
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs(.disconnected(reason: "eof", isRetrying: false))))
            == .status(title: "Daemon disconnected", detail: nil))
        #expect(Self.status(LeoMenuBarModel.items(Self.inputs(.disconnected(reason: "eof", isRetrying: true))))
            == .status(title: "Daemon disconnected", detail: "Reconnecting…"))
    }

    // MARK: Agents

    @Test func agentsAreSortedByNameAndFlagAttention() {
        let items = LeoMenuBarModel.items(Self.inputs(rows: [
            Self.row("zed", status: .stopped), Self.row("Alfred", attention: .needsInput), Self.row("bob", status: .starting),
        ]))

        #expect(items[1] == .agents(title: "Agents", isEnabled: true, agents: [
            LeoMenuBarAgent(id: Self.row("Alfred").id, name: "Alfred", state: .running, needsAttention: true),
            LeoMenuBarAgent(id: Self.row("bob").id, name: "bob", state: .starting, needsAttention: false),
            LeoMenuBarAgent(id: Self.row("zed").id, name: "zed", state: .stopped, needsAttention: false),
        ]))
    }

    @Test func noAgentsOrNoConnectionDisablesTheSubmenu() {
        #expect(LeoMenuBarModel.items(Self.inputs())[1] == .agents(title: "No Agents", isEnabled: false, agents: []))
        let items = LeoMenuBarModel.items(Self.inputs(.disconnected(reason: "eof", isRetrying: false), rows: [Self.row("a")]))
        guard case .agents(_, let isEnabled, _) = items[1] else {
            Issue.record("no agents item")
            return
        }
        #expect(!isEnabled)
    }

    // MARK: Actions

    private static func actions(_ items: [LeoMenuBarItem]) -> [LeoMenuBarAction: (title: String, enabled: Bool, checked: Bool)] {
        var result: [LeoMenuBarAction: (String, Bool, Bool)] = [:]
        for case .action(let action, let title, let enabled, let checked) in items { result[action] = (title, enabled, checked) }
        return result.mapValues { (title: $0.0, enabled: $0.1, checked: $0.2) }
    }

    @Test func theActionsAreInOrder() {
        let order = LeoMenuBarModel.items(Self.inputs()).compactMap { item -> LeoMenuBarAction? in
            if case .action(let action, _, _, _) = item { action } else { nil }
        }
        #expect(order == [.pairDevice, .restartDaemon, .openLogs, .toggleServerOnly, .openLeo, .quit])
    }

    @Test func pairingNeedsAConnectedLocalDaemon() {
        let connected = Self.actions(LeoMenuBarModel.items(Self.inputs()))[.pairDevice]
        #expect(connected?.title == "Pair a Device…")
        #expect(connected?.enabled == true)
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs(.failed(message: "x"))))[.pairDevice]?.enabled == false)
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs(.loading)))[.pairDevice]?.enabled == false)
        let remote = LeoMenuBarInputs(
            snapshot: LeoSidebarSnapshot(rows: [], connectivity: .connected, generation: 1, features: .none, featuresHost: .remote("box")),
            version: nil, isManaged: false, isOutsideDaemon: false, serverOnly: false, isRestarting: false, hasLogFile: true
        )
        #expect(Self.actions(LeoMenuBarModel.items(remote))[.pairDevice]?.enabled == false)
    }

    @Test func releaseToCLIIsOfferedOnlyWhileTheAppManagesTheDaemon() {
        let order = LeoMenuBarModel.items(Self.inputs(managed: true)).compactMap { item -> LeoMenuBarAction? in
            if case .action(let action, _, _, _) = item { action } else { nil }
        }
        #expect(order == [.pairDevice, .restartDaemon, .releaseToCLI, .openLogs, .toggleServerOnly, .openLeo, .quit])
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs(managed: true)))[.releaseToCLI]?.title == "Release to CLI…")
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs(managed: true, restarting: true)))[.releaseToCLI]?.enabled == false)
    }

    @Test func restartIsOfferedWhileTheDaemonIsDownAndDisabledOnlyWhileRunning() {
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs(.failed(message: "x"))))[.restartDaemon]?.enabled == true)
        let busy = Self.actions(LeoMenuBarModel.items(Self.inputs(restarting: true)))[.restartDaemon]
        #expect(busy?.enabled == false)
        #expect(busy?.title == "Restarting Daemon…")
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs()))[.restartDaemon]?.title == "Restart Daemon")
    }

    @Test func restartIsUnavailableForARemoteHost() {
        let remote = LeoMenuBarInputs(
            snapshot: LeoSidebarSnapshot(rows: [], connectivity: .connected, generation: 1, features: .none, featuresHost: .remote("box")),
            version: nil, isManaged: false, isOutsideDaemon: false, serverOnly: false, isRestarting: false, hasLogFile: true
        )
        #expect(Self.actions(LeoMenuBarModel.items(remote))[.restartDaemon]?.enabled == false)
    }

    @Test func logsNeedAFileAndServerOnlyIsChecked() {
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs(hasLog: false)))[.openLogs]?.enabled == false)
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs()))[.openLogs]?.enabled == true)
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs(serverOnly: true)))[.toggleServerOnly]?.checked == true)
        #expect(Self.actions(LeoMenuBarModel.items(Self.inputs()))[.toggleServerOnly]?.checked == false)
    }

    // MARK: Visibility

    @Test(arguments: [(true, false, true), (false, false, false), (false, true, true), (true, true, true)])
    func serverOnlyForcesTheExtraOn(preference: Bool, serverOnly: Bool, expected: Bool) {
        #expect(LeoMenuBarModel.isVisible(preference: preference, serverOnly: serverOnly) == expected)
    }

    @Test func theExtraIsOnByDefaultAndReadsItsKey() {
        let defaults = LeoInMemoryDefaults()
        #expect(LeoMenuBarModel.preference(in: defaults))
        defaults.set(false, forKey: "leo.menuBarExtra")
        #expect(!LeoMenuBarModel.preference(in: defaults))
    }
}

/// Restart always drains gracefully and never prompts (`restart` alone may).
/// A managed daemon restarts through the bundled binary by explicit path
/// (D6) with `--json`, and every answer maps to friendly text: leo's stderr
/// (a raw `launchctl kickstart … exit status 113`) never reaches the user,
/// for a CLI daemon's restart either.
struct LeoDaemonRestarterTests {
    private actor Recorder: LeoProcessRunning {
        private(set) var calls: [(executable: String, arguments: [String])] = []
        let result: LeoProcessResult
        let failure: (any Error & Sendable)?
        init(status: Int32 = 0, stdout: String = "", stderr: String = "", failure: (any Error & Sendable)? = nil) {
            result = LeoProcessResult(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), status: status)
            self.failure = failure
        }
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult {
            calls.append((executable, arguments))
            if let failure { throw failure }
            return result
        }
    }

    private struct Boom: Error, Sendable {}

    private static let restartedJSON = #"{"ok":true,"drained":true,"restarted":true}"#
    private static let kickstartStderr = "launchctl kickstart gui/501/studio.blackpaw.leo.daemon: exit status 113"

    private static func restarter(_ recorder: Recorder) -> LeoDaemonRestarter {
        LeoDaemonRestarter(
            cli: LeoCLI(
                runner: recorder, candidatePaths: ["/usr/local/bin/leo"], path: nil, expandTilde: { $0 }, isExecutable: { $0 == "/usr/local/bin/leo" }
            ),
            bundledExecutable: "/Applications/Leo.app/Contents/Helpers/leo"
        )
    }

    @Test func aCLIDaemonRestartsGracefullyThroughTheResolvedLeo() async throws {
        let recorder = Recorder()

        let outcome = await Self.restarter(recorder).restart(isManaged: false)

        let calls = await recorder.calls
        #expect(outcome == .restarted)
        #expect(calls.map(\.executable) == ["/usr/local/bin/leo"])
        #expect(calls.map(\.arguments) == [["service", "restart", "--graceful"]])
    }

    @Test func aManagedDaemonRestartsThroughTheBundledLeoByPathAsJSON() async throws {
        let recorder = Recorder(stdout: Self.restartedJSON)

        let outcome = await Self.restarter(recorder).restart(isManaged: true)

        let calls = await recorder.calls
        #expect(outcome == .restarted)
        #expect(calls.map(\.executable) == ["/Applications/Leo.app/Contents/Helpers/leo"])
        #expect(calls.map(\.arguments) == [["service", "restart", "--graceful", "--json"]])
    }

    @Test func aCLIFailureGetsFriendlyTextNotLeosStderr() async {
        let recorder = Recorder(status: 1, stderr: Self.kickstartStderr)

        let outcome = await Self.restarter(recorder).restart(isManaged: false)

        guard case .failed(let message) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(message.contains("leo doctor"))
        #expect(message.contains("~/.leo/state/service.log"))
        #expect(!message.contains("kickstart"))
        #expect(!message.contains("113"))
    }

    @Test func aCLIThatCannotRunOrBeFoundGetsFriendlyTextToo() async {
        let cannotRun = Recorder(failure: Boom())
        let missing = LeoDaemonRestarter(
            cli: LeoCLI(runner: Recorder(), candidatePaths: [], path: nil, expandTilde: { $0 }, isExecutable: { _ in false }),
            bundledExecutable: "/Applications/Leo.app/Contents/Helpers/leo"
        )

        for outcome in [await Self.restarter(cannotRun).restart(isManaged: false), await missing.restart(isManaged: false)] {
            guard case .failed(let message) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
            #expect(message.contains("leo doctor"))
        }
    }

    @Test func notRegisteredIsTheOutsideDaemonCaseNotAnError() async throws {
        let recorder = Recorder(
            status: 1, stdout: #"{"ok":false,"error":"not_registered","message":"no job"}"#, stderr: Self.kickstartStderr
        )

        let outcome = await Self.restarter(recorder).restart(isManaged: true)

        #expect(outcome == .notRegistered)
    }

    @Test func busyAgentsExplainThemselves() async throws {
        let recorder = Recorder(status: 1, stdout: #"{"ok":false,"error":"drain_timeout","message":"2 agents busy"}"#)

        let outcome = await Self.restarter(recorder).restart(isManaged: true)

        guard case .failed(let message) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(message.contains("busy"))
    }

    @Test(arguments: [
        (1, #"{"ok":false,"error":"restart_failed","message":"kickstart failed"}"#),
        (1, #"{"error":"not_permitted"}"#),
        (1, "not json at all"),
        (0, "not json at all"),
        (113, ""),
    ])
    func everyOtherAnswerGetsFriendlyTextWithoutRawStderr(status: Int32, stdout: String) async throws {
        let recorder = Recorder(status: Int32(status), stdout: stdout, stderr: Self.kickstartStderr)

        let outcome = await Self.restarter(recorder).restart(isManaged: true)

        guard case .failed(let message) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(message.contains("leo doctor"))
        #expect(message.contains("~/.leo/state/service.log"))
        #expect(!message.contains("kickstart"))
        #expect(!message.contains("113"))
    }

    @Test func aLeoThatCannotRunGetsFriendlyTextToo() async throws {
        let recorder = Recorder(failure: Boom())

        let outcome = await Self.restarter(recorder).restart(isManaged: true)

        guard case .failed(let message) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(message.contains("leo doctor"))
    }
}
