import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A sleeper the test advances by hand: no real waiting. Every `sleep` parks
/// until `tick`, or throws when its task is cancelled.
actor ServiceTicker {
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<Int> = []
    private var next = 0
    private(set) var intervals: [Duration] = []

    var parked: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        let id = next
        next += 1
        intervals.append(duration)
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if cancelled.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = continuation
                    }
                }
            },
            onCancel: { Task { await self.cancel(id) } }
        )
    }

    private func cancel(_ id: Int) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }

    /// Waits for something to be sleeping, then wakes everything that is.
    func tick() async {
        while waiters.isEmpty { await Task.yield() }
        let waiting = waiters
        waiters = [:]
        for waiter in waiting.values { waiter.resume() }
    }

    /// Waits for `count` sleepers to be parked: the loop has come round again.
    func untilParked(_ count: Int = 1) async {
        while waiters.count < count { await Task.yield() }
    }

    /// Lets cancellations that are still on their way land.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// A clock the test moves: the restart wait's deadline reads it, and each
/// sleep that wakes moves it by the time slept.
final class ServiceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_792_738_800)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor final class PasteboardSpy {
    private(set) var copied: [String] = []
    func write(_ text: String) { copied.append(text) }
}

@MainActor struct LeoServiceSettingsModelTests {
    private static let start = Date(timeIntervalSince1970: 1_792_738_800)

    private static let processes = [
        LeoServiceProcess(name: "coder", status: "running"),
        LeoServiceProcess(name: "reviewer", status: "restarting"),
        LeoServiceProcess(name: "scratch", status: "running", isEphemeral: true),
        LeoServiceProcess(name: "old", status: "stopped"),
    ]

    private struct Harness {
        let model: LeoServiceSettingsModel
        let fake: LeoFakeConfigClient
        let ticker: ServiceTicker
        let pasteboard: PasteboardSpy
        let clock: ServiceClock
    }

    private static func state(pid: Int = 100, log: String = "", agents: LeoAgentsRestartResult = LeoAgentsRestartResult()) -> LeoFakeServiceState {
        LeoFakeServiceState(
            version: "v0.52.0", pid: pid, startedAt: start.addingTimeInterval(Double(pid - 100) * 60), processes: processes, log: log, agentsRestart: agents
        )
    }

    private static func harness(
        log: String = "", agents: LeoAgentsRestartResult = LeoAgentsRestartResult(), maxRestartPolls: Int = 60, load: Bool = true
    ) async throws -> Harness {
        let fake = try LeoConfigGolden.client()
        await fake.setService(state(log: log, agents: agents))
        let ticker = ServiceTicker()
        let pasteboard = PasteboardSpy()
        let clock = ServiceClock()
        let model = LeoServiceSettingsModel(
            client: fake, machine: "dionysus",
            sleep: { duration in
                try await ticker.sleep(duration)
                clock.advance(Double(duration.components.seconds))
            },
            copyToPasteboard: { pasteboard.write($0) }, maxRestartPolls: maxRestartPolls, now: { clock.now }
        )
        if load { await model.load() }
        return Harness(model: model, fake: fake, ticker: ticker, pasteboard: pasteboard, clock: clock)
    }

    private static func count(_ fake: LeoFakeConfigClient, _ call: LeoFakeConfigCall) async -> Int {
        await fake.calls.filter { $0 == call }.count
    }

    // MARK: status

    @Test func loadingReadsTheDaemonStatus() async throws {
        let harness = try await Self.harness()

        #expect(harness.model.phase == .loaded)
        #expect(harness.model.status?.pid == 100)
        #expect(harness.model.status?.version == "v0.52.0")
        #expect(harness.model.status?.runningAgentCount == 2)
    }

    @Test func aStatusThatCantBeReadIsAFailureWithARetry() async throws {
        let harness = try await Self.harness(load: false)
        await harness.fake.failNextRead(with: LeoDaemonError.transport("tunnel dropped"))
        await harness.model.load()

        guard case .failed = harness.model.phase else {
            Issue.record("Expected failed")
            return
        }
        await harness.model.load()
        #expect(harness.model.phase == .loaded)
    }

    // MARK: restart daemon

    @Test func restartingTheDaemonAsksFirstAndSendsNothingUntilConfirmed() async throws {
        let harness = try await Self.harness()
        harness.model.requestRestartDaemon()

        #expect(harness.model.confirmation == .restartDaemon)
        #expect(await Self.count(harness.fake, .restartService) == 0)
        harness.model.cancelConfirmation()
        #expect(harness.model.confirmation == nil)
        #expect(await Self.count(harness.fake, .restartService) == 0)
    }

    @Test func confirmingActsOnTheConfirmationTheAlertShowedEvenThoughItsAlreadyCleared() async throws {
        let harness = try await Self.harness()
        harness.model.requestRestartDaemon()
        let shown = try #require(harness.model.confirmation)
        harness.model.cancelConfirmation()
        await harness.model.confirm(shown)

        #expect(await Self.count(harness.fake, .restartService) == 1)
        #expect(harness.model.isRestarting)
    }

    @Test func theDaemonShowsRestartingUntilItReportsANewProcess() async throws {
        let harness = try await Self.harness()
        await harness.model.restartDaemon()
        #expect(harness.model.isRestarting)

        await harness.ticker.untilParked()
        await harness.ticker.tick()
        await harness.ticker.untilParked()
        #expect(harness.model.isRestarting)
        #expect(harness.model.status?.pid == 100)

        await harness.fake.finishServiceRestart()
        await harness.ticker.tick()
        await harness.model.settledRestart()

        #expect(!harness.model.isRestarting)
        #expect(harness.model.status?.pid == 101)
        #expect(harness.model.notice == "leo restarted on dionysus.")
        #expect(harness.model.errorMessage == nil)
    }

    @Test func aSecondRestartIsNotOfferedWhileOneRuns() async throws {
        let harness = try await Self.harness()
        await harness.model.restartDaemon()
        harness.model.requestRestartDaemon()

        #expect(harness.model.confirmation == nil)
        #expect(!harness.model.canRestartDaemon)
        await harness.model.restartDaemon()
        #expect(await Self.count(harness.fake, .restartService) == 1)
    }

    @Test func aRestartThatIsAlreadyRunningOnTheDaemonIsShownAsInProgressNotAsAFailure() async throws {
        let harness = try await Self.harness()
        _ = try await harness.fake.restartService()
        await harness.model.restartDaemon()

        #expect(harness.model.errorMessage == nil)
        #expect(harness.model.isRestarting)
        #expect(harness.model.notice == "A restart is already in progress on dionysus.")

        await harness.fake.finishServiceRestart()
        await harness.ticker.tick()
        await harness.model.settledRestart()
        #expect(!harness.model.isRestarting)
        #expect(harness.model.status?.pid == 101)
    }

    @Test func aRestartThatFailsToStartIsAnErrorAndLeavesTheDaemonAlone() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "internal", message: "restarting service: exec failed", matches: []))
        await harness.model.restartDaemon()

        #expect(harness.model.errorMessage == "restarting service: exec failed")
        #expect(!harness.model.isRestarting)
    }

    @Test func pollingRidesOutTheConnectionBeingDown() async throws {
        let harness = try await Self.harness()
        await harness.model.restartDaemon()
        await harness.ticker.untilParked()

        await harness.fake.failNextRead(with: LeoDaemonError.transport("socket closed"))
        await harness.ticker.tick()
        await harness.ticker.untilParked()
        #expect(harness.model.isRestarting)
        #expect(harness.model.errorMessage == nil)

        await harness.fake.finishServiceRestart()
        await harness.ticker.tick()
        await harness.model.settledRestart()
        #expect(!harness.model.isRestarting)
    }

    /// The daemon restarts gracefully: it waits, answering as the same process,
    /// for busy agents to pause, for up to ten minutes.
    @Test func aDaemonDrainingBusyAgentsOutlastsTheDownBudgetWithoutFailing() async throws {
        let harness = try await Self.harness(maxRestartPolls: 3)
        await harness.model.restartDaemon()
        for _ in 0..<10 {
            await harness.ticker.tick()
            await harness.ticker.untilParked()
        }

        #expect(harness.model.isRestarting)
        #expect(harness.model.isWaitingOnAgents)
        #expect(harness.model.errorMessage == nil)

        await harness.fake.finishServiceRestart()
        await harness.ticker.tick()
        await harness.model.settledRestart()
        #expect(!harness.model.isRestarting)
        #expect(!harness.model.isWaitingOnAgents)
        #expect(harness.model.notice == "leo restarted on dionysus.")
    }

    @Test func theDrainNoteGivesWayWhenTheDaemonGoesDown() async throws {
        let harness = try await Self.harness()
        await harness.model.restartDaemon()
        await harness.ticker.tick()
        await harness.ticker.untilParked()
        #expect(harness.model.isWaitingOnAgents)

        await harness.fake.failNextRead(with: LeoDaemonError.transport("socket closed"))
        await harness.ticker.tick()
        await harness.ticker.untilParked()
        #expect(harness.model.isRestarting)
        #expect(!harness.model.isWaitingOnAgents)
    }

    @Test func aDaemonThatWentDownAndNeverComesBackIsGivenUpOnWithAHint() async throws {
        let harness = try await Self.harness(maxRestartPolls: 3)
        await harness.model.restartDaemon()
        for _ in 0..<3 {
            await harness.fake.failNextRead(with: LeoDaemonError.transport("socket closed"))
            await harness.ticker.tick()
            await harness.ticker.untilParkedOrDone(harness.model)
        }
        await harness.model.settledRestart()

        #expect(!harness.model.isRestarting)
        #expect(harness.model.errorMessage?.contains("hasn’t come back") == true)
    }

    @Test func aRestartThatOutlastsTheWallClockDeadlineIsGivenUpOn() async throws {
        let harness = try await Self.harness()
        await harness.model.restartDaemon()
        await harness.ticker.untilParked()
        harness.clock.advance(13 * 60)
        await harness.ticker.tick()
        await harness.model.settledRestart()

        #expect(!harness.model.isRestarting)
        #expect(harness.model.errorMessage?.contains("still waiting for busy agents") == true)
        #expect(harness.model.errorMessage?.contains("hasn’t come back") == false)
    }

    @Test func theWallClockDeadlineAlsoEndsAWaitThatKeepsFindingTheDaemonDown() async throws {
        let harness = try await Self.harness(maxRestartPolls: 1000)
        await harness.model.restartDaemon()
        await harness.ticker.untilParked()
        await harness.fake.failNextRead(with: LeoDaemonError.transport("socket closed"))
        await harness.ticker.tick()
        await harness.ticker.untilParked()
        harness.clock.advance(13 * 60)
        await harness.ticker.tick()
        await harness.model.settledRestart()

        #expect(!harness.model.isRestarting)
        #expect(harness.model.errorMessage?.contains("hasn’t come back") == true)
    }

    @Test func aReconnectDuringTheRestartFinishesItThroughTheNewClient() async throws {
        let harness = try await Self.harness()
        await harness.model.restartDaemon()
        await harness.ticker.untilParked()

        let replacement = try LeoConfigGolden.client()
        await replacement.setService(Self.state(pid: 101))
        await harness.fake.failNextRead(with: LeoDaemonError.transport("socket closed"))
        await harness.model.reload(using: replacement)
        #expect(harness.model.isRestarting)

        await harness.ticker.tick()
        await harness.model.settledRestart()
        #expect(!harness.model.isRestarting)
        #expect(harness.model.status?.pid == 101)
    }

    @Test func theServicePaneStaysMountedWhileItRestartsAndNotAfter() async throws {
        let harness = try await Self.harness()
        #expect(!harness.model.hasUnsavedChanges)
        #expect(!harness.model.staysMountedWhileReconnecting)

        await harness.model.restartDaemon()
        #expect(!harness.model.hasUnsavedChanges)
        #expect(harness.model.staysMountedWhileReconnecting)

        await harness.fake.finishServiceRestart()
        await harness.ticker.tick()
        await harness.model.settledRestart()
        #expect(!harness.model.staysMountedWhileReconnecting)
    }

    @Test func theRestartPromptActionReportsAFailureAsText() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "internal", message: "exec failed", matches: []))

        #expect(await harness.model.restartDaemon() == "exec failed")
        #expect(await harness.model.restartDaemon() == nil)
    }

    // MARK: restart all agents

    @Test func restartingAgentsNamesHowManyAreRunningAndSendsNothingUntilConfirmed() async throws {
        let harness = try await Self.harness()
        harness.model.requestRestartAgents()

        #expect(harness.model.confirmation == .restartAgents(running: 2))
        #expect(await Self.count(harness.fake, .restartAgents) == 0)
    }

    @Test func aConfirmedRestartOfTheAgentsSummarisesWhoRestarted() async throws {
        let harness = try await Self.harness(agents: LeoAgentsRestartResult(restarted: ["coder", "scratch"], skipped: ["old"]))
        await harness.fake.raiseRestartRequired(LeoConfigRestartRequired(service: false, agents: true))
        await harness.model.refreshStatus()
        #expect(harness.model.status?.restartRequired.agents == true)

        harness.model.requestRestartAgents()
        await harness.model.confirm(try #require(harness.model.confirmation))

        #expect(await Self.count(harness.fake, .restartAgents) == 1)
        #expect(harness.model.agentsSummary == "Restarted 2 agents. 1 skipped.")
        #expect(harness.model.errorMessage == nil)
        #expect(harness.model.status?.restartRequired.agents == false)
    }

    @Test func aFailedAgentRestartNamesTheAgentAndKeepsTheFlag() async throws {
        let harness = try await Self.harness(agents: LeoAgentsRestartResult(restarted: ["coder"], failed: ["reviewer": "tmux: no server running"]))
        await harness.fake.raiseRestartRequired(LeoConfigRestartRequired(service: false, agents: true))
        harness.model.requestRestartAgents()
        await harness.model.confirm(try #require(harness.model.confirmation))

        #expect(harness.model.agentsSummary == "Restarted 1 agent. Couldn’t restart reviewer: tmux: no server running.")
        #expect(harness.model.status?.restartRequired.agents == true)
    }

    @Test func theRestartPromptActionForAgentsReturnsTheFailure() async throws {
        let harness = try await Self.harness(agents: LeoAgentsRestartResult(failed: ["reviewer": "boom"]))

        #expect(await harness.model.restartAllAgents() == "Couldn’t restart reviewer: boom.")
    }

    // MARK: reload config

    @Test func reloadingTheConfigReportsItAndRefreshesTheStatus() async throws {
        let harness = try await Self.harness()
        await harness.model.reloadConfig()

        #expect(await Self.count(harness.fake, .reloadConfig) == 1)
        #expect(harness.model.notice == "Configuration reloaded on dionysus.")
        #expect(harness.model.errorMessage == nil)
    }

    @Test func aFailedReloadIsAnError() async throws {
        let harness = try await Self.harness()
        await harness.fake.failNextWrite(with: LeoDaemonError.daemon(code: "internal", message: "reload failed: bad yaml", matches: []))
        await harness.model.reloadConfig()

        #expect(harness.model.errorMessage == "reload failed: bad yaml")
        #expect(harness.model.notice == nil)
    }

    // MARK: log tail

    @Test func theLogIsFetchedAtOnceWhenItBecomesVisibleThenEveryTwoSeconds() async throws {
        let harness = try await Self.harness(log: "one\n")
        harness.model.setLogVisible(true)
        await harness.ticker.untilParked()

        #expect(harness.model.logText == "one\n")
        #expect(await Self.count(harness.fake, .serviceLog(lines: 200)) == 1)
        #expect(await harness.ticker.intervals == [.seconds(2)])

        await harness.fake.setService(Self.state(log: "one\ntwo\n"))
        await harness.ticker.tick()
        await harness.ticker.untilParked()
        #expect(harness.model.logText == "one\ntwo\n")
        #expect(await Self.count(harness.fake, .serviceLog(lines: 200)) == 2)
    }

    @Test func nothingIsPolledWhileTheLogIsHidden() async throws {
        let harness = try await Self.harness(log: "one\n")
        harness.model.setLogVisible(true)
        await harness.ticker.untilParked()
        harness.model.setLogVisible(false)
        await harness.ticker.settle()

        #expect(await harness.ticker.parked == 0)
        #expect(await Self.count(harness.fake, .serviceLog(lines: 200)) == 1)
    }

    @Test func pausingStopsPollingAndKeepsTheTextAndResumingFetchesAtOnce() async throws {
        let harness = try await Self.harness(log: "one\n")
        harness.model.setLogVisible(true)
        await harness.ticker.untilParked()
        harness.model.setLogPaused(true)
        await harness.ticker.settle()
        await harness.fake.setService(Self.state(log: "one\ntwo\n"))

        #expect(await harness.ticker.parked == 0)
        #expect(harness.model.isLogPaused)
        #expect(harness.model.logText == "one\n")
        #expect(await Self.count(harness.fake, .serviceLog(lines: 200)) == 1)

        harness.model.setLogPaused(false)
        await harness.ticker.untilParked()
        #expect(harness.model.logText == "one\ntwo\n")
    }

    @Test func aPausedLogStaysPausedWhenItBecomesVisibleAgain() async throws {
        let harness = try await Self.harness(log: "one\n")
        harness.model.setLogPaused(true)
        harness.model.setLogVisible(true)
        await harness.ticker.settle()

        #expect(await Self.count(harness.fake, .serviceLog(lines: 200)) == 0)
        #expect(await harness.ticker.parked == 0)
    }

    @Test func aLogThatCantBeReadKeepsTheLastTextAndSaysWhy() async throws {
        let harness = try await Self.harness(log: "one\n")
        harness.model.setLogVisible(true)
        await harness.ticker.untilParked()
        await harness.fake.failNextRead(with: LeoDaemonError.transport("socket closed"))
        await harness.ticker.tick()
        await harness.ticker.untilParked()

        #expect(harness.model.logText == "one\n")
        #expect(harness.model.logError != nil)

        await harness.ticker.tick()
        await harness.ticker.untilParked()
        #expect(harness.model.logError == nil)
    }

    @Test func copyWritesTheTextShown() async throws {
        let harness = try await Self.harness(log: "one\ntwo\n")
        harness.model.setLogVisible(true)
        await harness.ticker.untilParked()
        harness.model.copyLog()

        #expect(harness.pasteboard.copied == ["one\ntwo\n"])
    }

    @Test func stoppingEndsEveryLoop() async throws {
        let harness = try await Self.harness(log: "one\n")
        harness.model.setLogVisible(true)
        await harness.model.restartDaemon()
        await harness.ticker.untilParked(2)
        harness.model.stop()
        await harness.ticker.settle()

        #expect(await harness.ticker.parked == 0)
    }
}

extension ServiceTicker {
    /// Waits for a loop to park again, or for the restart wait to be over.
    @MainActor func untilParkedOrDone(_ model: LeoServiceSettingsModel) async {
        while await parked == 0, model.isRestarting { await Task.yield() }
    }
}
