import CoreImage
import Foundation
import Testing

@testable import Ghostty

/// B7: `leo pair --json` decoding, its error mapping, the exact argv of the
/// pair / `web enable` / retry sequence, the refresh at `expires_at`, and a
/// QR that carries `qr_payload` verbatim. The panel layout is a TDD
/// exception (screenshot).
private enum PairFixtures {
    static let leoPath = "/usr/local/bin/leo"

    static let payloadJSON = """
    {"daemon_id":"d-1f2e","name":"studio-mac","urls":["https://studio.example.ts.net","http://10.0.2.20:8123"],
     "pairing_code":"ABCD-1234","warnings":["bind is not loopback"],"expires_at":"2026-10-20T23:45:00Z",
     "qr_payload":"leo://pair?d=d-1f2e&c=ABCD-1234&u=https%3A%2F%2Fstudio.example.ts.net","extra":1}
    """

    static func payload(code: String = "ABCD-1234", expiresAt: Date = Date(timeIntervalSince1970: 1_000_060)) -> LeoPairingPayload {
        LeoPairingPayload(
            daemonID: "d-1f2e", name: "studio-mac", urls: ["https://studio.example.ts.net"], pairingCode: code,
            warnings: [], expiresAt: expiresAt, qrPayload: "leo://pair?c=\(code)"
        )
    }

    static func payloadOutput(code: String = "ABCD-1234", expiresAt: String = "1970-01-12T13:48:20Z") -> LeoProcessResult {
        out("""
        {"daemon_id":"d-1f2e","name":"studio-mac","urls":["https://studio.example.ts.net"],"pairing_code":"\(code)",
         "warnings":[],"expires_at":"\(expiresAt)","qr_payload":"leo://pair?c=\(code)"}
        """)
    }

    static let webDisabled = out(#"{"error":"web_disabled","message":"web listener is off"}"#, status: 1)
    static let enabled = out(#"{"ok":true,"changed":true,"restarted":true,"web":{"enabled":true,"bind":"127.0.0.1","port":8123}}"#)
    static let enabledNoRestart = out(#"{"ok":true,"changed":true,"restarted":false,"web":{"enabled":true,"bind":"127.0.0.1","port":8123}}"#)

    static func out(_ json: String, status: Int32 = 0) -> LeoProcessResult {
        LeoProcessResult(stdout: Data(json.utf8), stderr: Data(), status: status)
    }

    static let bundledPath = "/Applications/Leo.app/Contents/Helpers/leo"

    /// A `LeoCLI` with the bundled helper configured, where only `executable` paths exist.
    static func service(
        _ runner: ScriptedRunner, override: String? = nil, executable: Set<String>, marker: LeoMarkerState = .absent
    ) -> LeoPairingService {
        LeoPairingService(cli: LeoCLI(
            executableOverride: override, runner: runner, candidatePaths: [leoPath], path: nil, bundledExecutable: bundledPath,
            markerState: { marker }, expandTilde: { $0 }, isExecutable: { executable.contains($0) }
        ))
    }

    static func service(_ runner: ScriptedRunner) -> LeoPairingService {
        LeoPairingService(cli: LeoCLI(
            runner: runner, candidatePaths: [leoPath], path: nil, bundledExecutable: nil,
            markerState: { .absent }, expandTilde: { $0 }, isExecutable: { $0 == leoPath }
        ))
    }
}

/// Plays back one canned result per run, recording each executable + argv.
private actor ScriptedRunner: LeoProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String], timeout: TimeInterval)] = []
    private var script: [LeoProcessResult]

    init(_ script: [LeoProcessResult]) { self.script = script }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> LeoProcessResult {
        calls.append((executable, arguments, timeout))
        return script.isEmpty ? LeoProcessResult(stdout: Data(), stderr: Data("script exhausted".utf8), status: 99) : script.removeFirst()
    }

    var argv: [[String]] { calls.map(\.arguments) }
}

struct LeoPairingServiceTests {
    @Test func decodesTheFlatPairingFields() async throws {
        let runner = ScriptedRunner([PairFixtures.out(PairFixtures.payloadJSON)])

        let payload = try await PairFixtures.service(runner).pair()

        #expect(payload.daemonID == "d-1f2e")
        #expect(payload.name == "studio-mac")
        #expect(payload.urls == ["https://studio.example.ts.net", "http://10.0.2.20:8123"])
        #expect(payload.pairingCode == "ABCD-1234")
        #expect(payload.warnings == ["bind is not loopback"])
        #expect(payload.expiresAt == Date(timeIntervalSince1970: 1_792_539_900))
        #expect(payload.qrPayload == "leo://pair?d=d-1f2e&c=ABCD-1234&u=https%3A%2F%2Fstudio.example.ts.net")
    }

    @Test func pairRunsExactlyPairJSONThroughTheResolvedLeo() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput()])

        _ = try await PairFixtures.service(runner).pair()

        let calls = await runner.calls
        #expect(calls.map(\.executable) == [PairFixtures.leoPath])
        #expect(calls.map(\.arguments) == [["pair", "--json"]])
    }

    // MARK: Which leo runs (D6)

    @Test func pairAndEnableRunTheBundledHelperEvenWhenAnOlderLeoIsInstalled() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput(), PairFixtures.enabled])
        let service = PairFixtures.service(runner, executable: [PairFixtures.leoPath, PairFixtures.bundledPath])

        _ = try await service.pair()
        _ = try await service.enableWeb()

        #expect(await runner.calls.map(\.executable) == [PairFixtures.bundledPath, PairFixtures.bundledPath])
    }

    @Test func aManagedMarkersSelfPathDoesNotOverrideTheBundledHelper() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput()])
        let marker = LeoMarkerState.foreign(bundleID: "studio.blackpaw.leo.macos.debug", marker: LeoManagedMarker(
            bundleID: "studio.blackpaw.leo.macos.debug", launchdLabel: "x", selfPath: "/Users/evan/.leo/app/bin/leo", tmuxPath: "/t", env: nil
        ))
        let service = PairFixtures.service(runner, executable: ["/Users/evan/.leo/app/bin/leo", PairFixtures.bundledPath], marker: marker)

        _ = try await service.pair()

        #expect(await runner.calls.map(\.executable) == [PairFixtures.bundledPath])
    }

    @Test func withoutABundledHelperTheResolvedLeoRuns() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput()])

        _ = try await PairFixtures.service(runner, executable: [PairFixtures.leoPath]).pair()

        #expect(await runner.calls.map(\.executable) == [PairFixtures.leoPath])
    }

    @Test func anExplicitExecutablePathStillWins() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput()])
        let service = PairFixtures.service(runner, override: "/opt/dev/leo", executable: ["/opt/dev/leo", PairFixtures.bundledPath])

        _ = try await service.pair()

        #expect(await runner.calls.map(\.executable) == ["/opt/dev/leo"])
    }

    @Test func pairKeepsTheShortTimeout() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput()])

        _ = try await PairFixtures.service(runner).pair()

        #expect(await runner.calls.map(\.timeout) == [30])
    }

    @Test func expiryAcceptsFractionalSeconds() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput(expiresAt: "2026-10-20T23:45:00.500Z")])

        let payload = try await PairFixtures.service(runner).pair()

        #expect(payload.expiresAt == Date(timeIntervalSince1970: 1_792_539_900.5))
    }

    @Test func webDisabledIsItsOwnError() async {
        let runner = ScriptedRunner([PairFixtures.webDisabled])

        await #expect(throws: LeoPairingError.webDisabled(message: "web listener is off")) {
            try await PairFixtures.service(runner).pair()
        }
    }

    @Test func otherLeoErrorsKeepTheirCodeAndMessage() async {
        let runner = ScriptedRunner([PairFixtures.out(#"{"error":"daemon_unreachable","message":"no socket"}"#, status: 1)])

        await #expect(throws: LeoPairingError.leo(code: "daemon_unreachable", message: "no socket")) {
            try await PairFixtures.service(runner).pair()
        }
    }

    @Test func aLeoErrorWithoutAMessageStillMaps() async {
        let runner = ScriptedRunner([PairFixtures.out(#"{"error":"boom"}"#, status: 1)])

        await #expect(throws: LeoPairingError.leo(code: "boom", message: nil)) {
            try await PairFixtures.service(runner).pair()
        }
    }

    @Test func aNonZeroExitWithoutJSONShowsAGenericMessageNotStderr() async {
        let runner = ScriptedRunner([LeoProcessResult(stdout: Data(), stderr: Data("panic: /Users/evan/secret/path\n".utf8), status: 2)])

        await #expect {
            try await PairFixtures.service(runner).pair()
        } throws: { error in
            guard case let LeoPairingError.unreadable(message) = error else { return false }
            return message == "Pairing failed (leo exited 2). See ~/.leo/state/service.log."
                && !message.contains("secret")
        }
    }

    @Test func aFailedEnableWithoutJSONNamesTheEnableStep() async {
        let runner = ScriptedRunner([LeoProcessResult(stdout: Data(), stderr: Data("boom".utf8), status: 4)])

        await #expect(throws: LeoPairingError.unreadable("Enabling web access failed (leo exited 4). See ~/.leo/state/service.log.")) {
            try await PairFixtures.service(runner).enableWeb()
        }
    }

    @Test func aSuccessfulExitWithMalformedJSONIsUnreadable() async {
        let runner = ScriptedRunner([PairFixtures.out(#"{"daemon_id":"d-1"}"#)])

        await #expect {
            try await PairFixtures.service(runner).pair()
        } throws: { error in
            if case LeoPairingError.unreadable = error { return true }
            return false
        }
    }

    @Test func aMissingExecutableIsUnavailable() async {
        let service = LeoPairingService(cli: LeoCLI(
            runner: ScriptedRunner([]), candidatePaths: ["/nope/leo"], path: nil, bundledExecutable: nil,
            markerState: { .absent }, expandTilde: { $0 }, isExecutable: { _ in false }
        ))

        await #expect {
            try await service.pair()
        } throws: { error in
            if case LeoPairingError.unavailable = error { return true }
            return false
        }
    }

    // MARK: web enable

    @Test func enableWebRunsTheExactArgv() async throws {
        let runner = ScriptedRunner([PairFixtures.enabled, PairFixtures.enabled, PairFixtures.enabled])
        let service = PairFixtures.service(runner)

        let result = try await service.enableWeb()
        _ = try await service.enableWeb(bind: "0.0.0.0")
        _ = try await service.enableWeb(bind: "100.64.0.1", allowHosts: ["a.ts.net", "b.ts.net"])

        #expect(result == LeoWebEnableResult(changed: true, restarted: true, binding: LeoWebBinding(bind: "127.0.0.1", port: 8123)))
        #expect(await runner.argv == [
            ["web", "enable", "--json"],
            ["web", "enable", "--bind", "0.0.0.0", "--json"],
            ["web", "enable", "--bind", "100.64.0.1", "--allow-host", "a.ts.net", "--allow-host", "b.ts.net", "--json"],
        ])
    }

    @Test func enableWithoutAWebObjectHasNoBinding() async throws {
        let runner = ScriptedRunner([PairFixtures.out(#"{"ok":true,"changed":false,"restarted":false}"#)])

        let result = try await PairFixtures.service(runner).enableWeb()

        #expect(result == LeoWebEnableResult(changed: false, restarted: false, binding: nil))
    }

    @Test func enableWaitsOutALongDrainBeforeGivingUp() async throws {
        let runner = ScriptedRunner([PairFixtures.enabled])

        _ = try await PairFixtures.service(runner).enableWeb()

        // The restart drains busy agents for up to 10 minutes.
        let timeout = try #require(await runner.calls.first?.timeout)
        #expect(timeout >= 11 * 60)
    }

    @Test func enableWebFailureMapsLikePair() async {
        let runner = ScriptedRunner([PairFixtures.out(#"{"error":"bind_failed","message":"port in use"}"#, status: 1)])

        await #expect(throws: LeoPairingError.leo(code: "bind_failed", message: "port in use")) {
            try await PairFixtures.service(runner).enableWeb()
        }
    }

    @Test func enableWebReportingNotOKIsAnError() async {
        let runner = ScriptedRunner([PairFixtures.out(#"{"ok":false,"changed":false,"restarted":false}"#)])

        await #expect {
            try await PairFixtures.service(runner).enableWeb()
        } throws: { error in
            if case LeoPairingError.unreadable = error { return true }
            return false
        }
    }

    @Test func theEnablingStateSaysItIsWaitingForBusyAgents() {
        #expect(LeoPairingCopy.enablingTitle == "Turning on web access…")
        #expect(LeoPairingCopy.enablingDetail == "Waiting for busy agents to finish…")
    }

    @Test func theEnableExplanationSpellsOutTheNetworkExposureAndTheDrain() {
        let text = LeoPairingCopy.enableExplanation
        #expect(text.contains("devices on your network"))
        #expect(text.contains("bind address in its configuration"))
        #expect(text.contains("Busy agents finish their work first"))
        #expect(text.contains("restarts"))
    }

    @Test func theEnabledNoticeShowsTheActualBindAndPort() {
        #expect(LeoPairingCopy.webEnabledNotice(bind: "0.0.0.0", port: 8123) == "Web access is on at 0.0.0.0:8123.")
        #expect(LeoPairingCopy.webEnabledNotice(bind: "::1", port: 8123) == "Web access is on at [::1]:8123.")
    }

    @Test func errorsReadAsSentences() {
        #expect(LeoPairingError.webDisabled(message: nil).message == "Web access is turned off.")
        #expect(LeoPairingError.leo(code: "x", message: "It broke.").message == "It broke.")
        #expect(LeoPairingError.leo(code: "daemon_unreachable", message: nil).message == "leo reported daemon_unreachable.")
        #expect(LeoPairingError.unreadable("leo exited 3").message == "leo exited 3")
    }
}

/// The states a model published, in order.
@MainActor private final class StateLog {
    var states: [LeoPairingModel.State] = []
}

@MainActor private final class Counter {
    var count = 0
}

@MainActor
struct LeoPairingModelTests {
    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private static func model(
        _ runner: ScriptedRunner, clock: LeoFiringClock, onDaemonRestarted: @escaping () -> Void = {}
    ) -> LeoPairingModel {
        LeoPairingModel(
            service: PairFixtures.service(runner),
            sleep: { try await clock.sleep($0) },
            now: { start },
            onDaemonRestarted: onDaemonRestarted
        )
    }

    private nonisolated static func seconds(_ value: UInt64) -> UInt64 { value * 1_000_000_000 }

    @Test func startLoadsThePayloadAndSchedulesTheRefreshAtExpiry() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput(code: "AAAA", expiresAt: "1970-01-12T13:48:00Z")])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)

        model.start()
        try await until { await MainActor.run { model.state != .loading } }

        // 1_000_080 − 1_000_000 = 80 s until expiry.
        #expect(model.state == .ready(PairFixtures.payload(code: "AAAA", expiresAt: Date(timeIntervalSince1970: 1_000_080))))
        try await until { clock.pending(Self.seconds(80)).count == 1 }
        model.stop()
    }

    @Test func theRefreshFetchesAFreshCodeWhenExpiryArrives() async throws {
        let runner = ScriptedRunner([
            PairFixtures.payloadOutput(code: "AAAA", expiresAt: "1970-01-12T13:48:00Z"),
            PairFixtures.payloadOutput(code: "BBBB", expiresAt: "1970-01-12T13:49:00Z"),
        ])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        model.start()
        try await until { clock.pending(Self.seconds(80)).count == 1 }

        clock.fire(Self.seconds(80))

        try await until { await MainActor.run { model.state == .ready(PairFixtures.payload(code: "BBBB", expiresAt: Date(timeIntervalSince1970: 1_000_140))) } }
        #expect(await runner.argv == [["pair", "--json"], ["pair", "--json"]])
        try await until { clock.pending(Self.seconds(140)).count == 1 }
        model.stop()
    }

    @Test func anAlreadyExpiredPayloadIsRejectedAndNeverShown() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput(code: "OLD1", expiresAt: "1970-01-01T00:00:00Z")])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        let log = StateLog()
        model.onChange = { log.states.append($0) }

        model.start()

        try await until { await MainActor.run { model.state == .failed(LeoPairingError.expired.message) } }
        #expect(!log.states.contains { if case .ready = $0 { true } else { false } })
        model.stop()
    }

    @Test func theStaleCodeIsClearedAtExpiryAndReplacedByRefreshing() async throws {
        let runner = ScriptedRunner([
            PairFixtures.payloadOutput(code: "AAAA", expiresAt: "1970-01-12T13:48:00Z"),
            PairFixtures.payloadOutput(code: "BBBB", expiresAt: "1970-01-12T13:49:00Z"),
        ])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        let log = StateLog()
        model.onChange = { log.states.append($0) }
        model.start()
        try await until { clock.pending(Self.seconds(80)).count == 1 }

        clock.fire(Self.seconds(80))

        try await until { await MainActor.run { log.states.count == 3 } }
        #expect(log.states == [
            .ready(PairFixtures.payload(code: "AAAA", expiresAt: Date(timeIntervalSince1970: 1_000_080))),
            .refreshing,
            .ready(PairFixtures.payload(code: "BBBB", expiresAt: Date(timeIntervalSince1970: 1_000_140))),
        ])
        model.stop()
    }

    @Test func aFailedRefreshShowsTheErrorAndStopsRefreshingUntilRetried() async throws {
        let runner = ScriptedRunner([
            PairFixtures.payloadOutput(expiresAt: "1970-01-12T13:48:00Z"),
            PairFixtures.out(#"{"error":"daemon_unreachable","message":"no socket"}"#, status: 1),
            PairFixtures.payloadOutput(code: "CCCC", expiresAt: "1970-01-12T13:48:00Z"),
        ])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        model.start()
        try await until { clock.pending(Self.seconds(80)).count == 1 }

        clock.fire(Self.seconds(80))
        try await until { await MainActor.run { model.state == .failed("no socket") } }
        #expect(clock.pending(Self.seconds(80)).isEmpty)

        model.start()
        try await until { await MainActor.run { model.state == .ready(PairFixtures.payload(code: "CCCC", expiresAt: Date(timeIntervalSince1970: 1_000_080))) } }
        model.stop()
    }

    @Test func stopCancelsThePendingRefresh() async throws {
        let runner = ScriptedRunner([PairFixtures.payloadOutput(expiresAt: "1970-01-12T13:48:00Z")])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        model.start()
        try await until { clock.pending(Self.seconds(80)).count == 1 }

        model.stop()

        #expect(clock.pending(Self.seconds(80)).isEmpty)
    }

    // MARK: web_disabled path

    @Test func webDisabledOffersToEnableAndSchedulesNoRefresh() async throws {
        let runner = ScriptedRunner([PairFixtures.webDisabled])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)

        model.start()

        try await until { await MainActor.run { model.state == .webDisabled(message: "web listener is off") } }
        model.stop()
    }

    @Test func enablingWebRunsPairThenEnableThenPairAgain() async throws {
        let runner = ScriptedRunner([
            PairFixtures.webDisabled, PairFixtures.enabledNoRestart,
            PairFixtures.payloadOutput(code: "DDDD", expiresAt: "1970-01-12T13:48:00Z"),
        ])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        model.start()
        try await until { await MainActor.run { model.state == .webDisabled(message: "web listener is off") } }

        model.enableWebAccess()

        try await until { await MainActor.run { model.state == .ready(PairFixtures.payload(code: "DDDD", expiresAt: Date(timeIntervalSince1970: 1_000_080))) } }
        #expect(await runner.argv == [["pair", "--json"], ["web", "enable", "--json"], ["pair", "--json"]])
        model.stop()
    }

    @Test func theActualBindIsKeptAndSurfacedAfterEnabling() async throws {
        let runner = ScriptedRunner([
            PairFixtures.webDisabled, PairFixtures.enabledNoRestart,
            PairFixtures.payloadOutput(code: "FFFF", expiresAt: "1970-01-12T13:48:00Z"),
        ])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        model.start()
        try await until { await MainActor.run { model.state == .webDisabled(message: "web listener is off") } }
        #expect(model.webNotice == nil)

        model.enableWebAccess()

        try await until { await MainActor.run { model.state != .webDisabled(message: "web listener is off") && model.state != .enablingWeb } }
        #expect(model.enabledWeb == LeoWebBinding(bind: "127.0.0.1", port: 8123))
        #expect(model.webNotice == "Web access is on at 127.0.0.1:8123.")
        model.stop()
    }

    @Test func aRestartingDaemonIsRetriedUntilItComesBack() async throws {
        let unreachable = PairFixtures.out(#"{"error":"daemon_unreachable"}"#, status: 1)
        let runner = ScriptedRunner([
            PairFixtures.webDisabled, PairFixtures.enabled, unreachable, unreachable,
            PairFixtures.payloadOutput(code: "EEEE", expiresAt: "1970-01-12T13:48:00Z"),
        ])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        model.start()
        try await until { await MainActor.run { model.state == .webDisabled(message: "web listener is off") } }

        model.enableWebAccess()
        try await until { clock.pending(Self.seconds(LeoPairingModel.restartRetrySeconds)).count == 1 }
        #expect(model.state == .enablingWeb)
        clock.fire(Self.seconds(LeoPairingModel.restartRetrySeconds))
        try await until { clock.pending(Self.seconds(LeoPairingModel.restartRetrySeconds)).count == 1 }
        clock.fire(Self.seconds(LeoPairingModel.restartRetrySeconds))

        try await until { await MainActor.run { model.state == .ready(PairFixtures.payload(code: "EEEE", expiresAt: Date(timeIntervalSince1970: 1_000_080))) } }
        #expect(await runner.argv == [
            ["pair", "--json"], ["web", "enable", "--json"], ["pair", "--json"], ["pair", "--json"], ["pair", "--json"],
        ])
        model.stop()
    }

    @Test func theRestartedDaemonIsReconnectedOnceItAnswersPair() async throws {
        let unreachable = PairFixtures.out(#"{"error":"daemon_unreachable"}"#, status: 1)
        let runner = ScriptedRunner([
            PairFixtures.webDisabled, PairFixtures.enabled, unreachable,
            PairFixtures.payloadOutput(code: "GGGG", expiresAt: "1970-01-12T13:48:00Z"),
        ])
        let clock = LeoFiringClock()
        let reconnects = Counter()
        let model = Self.model(runner, clock: clock, onDaemonRestarted: { reconnects.count += 1 })
        model.start()
        try await until { await MainActor.run { model.state == .webDisabled(message: "web listener is off") } }

        model.enableWebAccess()
        try await until { clock.pending(Self.seconds(LeoPairingModel.restartRetrySeconds)).count == 1 }
        #expect(reconnects.count == 0)
        clock.fire(Self.seconds(LeoPairingModel.restartRetrySeconds))

        try await until { await MainActor.run { model.state == .ready(PairFixtures.payload(code: "GGGG", expiresAt: Date(timeIntervalSince1970: 1_000_080))) } }
        #expect(reconnects.count == 1)
        model.stop()
    }

    @Test func enablingWebWithoutADaemonRestartDoesNotReconnect() async throws {
        let runner = ScriptedRunner([
            PairFixtures.webDisabled, PairFixtures.enabledNoRestart,
            PairFixtures.payloadOutput(code: "HHHH", expiresAt: "1970-01-12T13:48:00Z"),
        ])
        let clock = LeoFiringClock()
        let reconnects = Counter()
        let model = Self.model(runner, clock: clock, onDaemonRestarted: { reconnects.count += 1 })
        model.start()
        try await until { await MainActor.run { model.state == .webDisabled(message: "web listener is off") } }

        model.enableWebAccess()

        try await until { await MainActor.run { model.state == .ready(PairFixtures.payload(code: "HHHH", expiresAt: Date(timeIntervalSince1970: 1_000_080))) } }
        #expect(reconnects.count == 0)
        model.stop()
    }

    @Test func aDaemonThatNeverComesBackEndsInAnError() async throws {
        let unreachable = PairFixtures.out(#"{"error":"daemon_unreachable","message":"no socket"}"#, status: 1)
        let runner = ScriptedRunner(
            [PairFixtures.webDisabled, PairFixtures.enabled] + Array(repeating: unreachable, count: LeoPairingModel.restartRetryAttempts + 1)
        )
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        model.start()
        try await until { await MainActor.run { model.state == .webDisabled(message: "web listener is off") } }

        model.enableWebAccess()
        for _ in 0..<LeoPairingModel.restartRetryAttempts {
            try await until { clock.pending(Self.seconds(LeoPairingModel.restartRetrySeconds)).count == 1 }
            clock.fire(Self.seconds(LeoPairingModel.restartRetrySeconds))
        }

        try await until { await MainActor.run { model.state == .failed("no socket") } }
        model.stop()
    }

    @Test func aFailedEnableShowsTheErrorAndDoesNotPairAgain() async throws {
        let runner = ScriptedRunner([PairFixtures.webDisabled, PairFixtures.out(#"{"error":"bind_failed","message":"port in use"}"#, status: 1)])
        let clock = LeoFiringClock()
        let model = Self.model(runner, clock: clock)
        model.start()
        try await until { await MainActor.run { model.state == .webDisabled(message: "web listener is off") } }

        model.enableWebAccess()

        try await until { await MainActor.run { model.state == .failed("port in use") } }
        #expect(await runner.argv == [["pair", "--json"], ["web", "enable", "--json"]])
        model.stop()
    }
}

struct LeoQRCodeTests {
    @Test func theImageCarriesThePayloadVerbatim() throws {
        let payload = "leo://pair?d=d-1f2e&c=ABCD-1234&u=https%3A%2F%2Fstudio.example.ts.net%3A8123"

        let image = try #require(LeoQRCode.image(for: payload, side: 300))

        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        #expect(features.map(\.messageString) == [payload])
    }

    @Test func theImageIsAtLeastTheRequestedSideAndSquare() throws {
        let image = try #require(LeoQRCode.image(for: "leo://pair?c=1", side: 200))

        #expect(image.width == image.height)
        #expect(image.width >= 200)
    }

    @Test func anEmptyPayloadHasNoImage() {
        #expect(LeoQRCode.image(for: "", side: 200) == nil)
    }
}
