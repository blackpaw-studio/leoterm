import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// leo ≥ 0.56.2: `/health` carries `claude: {found, path?}`, re-resolved on
/// each call. Built against fakes: the daemon isn't released yet.
struct LeoClaudeHealthTests {
    private struct Transport: LeoDaemonTransport {
        let reply: @Sendable () throws -> LeoHTTPResponse
        func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
            #expect(request == LeoHTTPRequest(method: "GET", path: "/health"))
            return try reply()
        }
    }

    private func claude(_ reply: @escaping @Sendable () throws -> LeoHTTPResponse) async -> LeoClaudeHealth {
        await LeoDaemonProbe(socketPath: "/s/leo.sock", transport: Transport(reply: reply)).claudeHealth()
    }

    private func body(_ json: String) -> @Sendable () throws -> LeoHTTPResponse {
        { LeoHTTPResponse(status: 200, body: Data(json.utf8)) }
    }

    @Test func aFoundClaudeCarriesItsPath() async {
        let result = await claude(body(#"{"ok":true,"data":{"version":"0.56.2","claude":{"found":true,"path":"/Users/e/.local/bin/claude"}}}"#))
        #expect(result == .found(path: "/Users/e/.local/bin/claude"))
    }

    @Test func aFoundClaudeNeedsNoPath() async {
        #expect(await claude(body(#"{"ok":true,"data":{"version":"0.56.2","claude":{"found":true}}}"#)) == .found(path: nil))
    }

    @Test func aMissingClaudeIsReported() async {
        #expect(await claude(body(#"{"ok":true,"data":{"version":"0.56.2","claude":{"found":false}}}"#)) == .missing)
    }

    @Test(arguments: [
        #"{"ok":true,"data":{"version":"0.56.1","pid":4242}}"#,
        #"{"ok":true,"data":{"version":"0.56.2","claude":{}}}"#,
        #"{"ok":true,"data":{"version":"0.56.2","claude":"yes"}}"#,
        "garbage",
    ])
    func anOlderOrUnreadableAnswerSaysNothingAboutClaude(json: String) async {
        #expect(await claude(body(json)) == .unreported)
    }

    @Test func aDaemonThatDoesNotAnswerSaysNothingAboutClaude() async {
        #expect(await claude { throw LeoDaemonError.timeout } == .unreported)
        #expect(await claude { throw LeoDaemonError.transport("Connection refused") } == .unreported)
    }
}

/// Claude onboarding driven by that field, falling back to the locator.
@MainActor struct LeoClaudeOnboardingModelTests {
    final class Presenter: LeoClaudeOfferPresenting {
        private(set) var offers = 0
        private(set) var withdrawals = 0
        private(set) var setUps = 0
        var answer: Bool?
        private var waiter: CheckedContinuation<Bool, Never>?

        func presentOffer() async -> Bool {
            offers += 1
            if let answer { return answer }
            return await withCheckedContinuation { waiter = $0 }
        }

        func withdrawOffer() {
            withdrawals += 1
            waiter?.resume(returning: false)
            waiter = nil
        }

        func runSetUp() { setUps += 1 }
        func answerVisibleOffer(_ accepted: Bool) { waiter?.resume(returning: accepted); waiter = nil }
    }

    final class Sources {
        var health: [LeoClaudeHealth]
        var located: String?
        private(set) var healthCalls = 0
        private(set) var locateCalls = 0

        init(_ health: LeoClaudeHealth..., located: String? = nil) {
            self.health = health
            self.located = located
        }

        func nextHealth() -> LeoClaudeHealth {
            healthCalls += 1
            return health.count > 1 ? health.removeFirst() : health[0]
        }

        func locate() -> String? {
            locateCalls += 1
            return located
        }
    }

    final class Clock {
        var now: TimeInterval = 1_000
    }

    private func model(
        _ sources: Sources, _ presenter: Presenter, defaults: LeoInMemoryDefaults = LeoInMemoryDefaults(), clock: Clock = Clock()
    ) -> LeoClaudeOnboardingModel {
        LeoClaudeOnboardingModel(
            health: { sources.nextHealth() }, locate: { sources.locate() },
            store: LeoClaudeOnboardingStore(defaults: defaults), presenter: presenter, now: { clock.now }
        )
    }

    /// `/health` that suspends each call until the test answers it.
    final class GatedHealth {
        private var waiters: [CheckedContinuation<LeoClaudeHealth, Never>] = []
        private(set) var calls = 0

        func next() async -> LeoClaudeHealth {
            calls += 1
            return await withCheckedContinuation { waiters.append($0) }
        }

        func answer(_ health: LeoClaudeHealth) {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume(returning: health)
        }
    }

    private func gatedModel(_ gate: GatedHealth, _ presenter: Presenter, clock: Clock = Clock()) -> LeoClaudeOnboardingModel {
        LeoClaudeOnboardingModel(
            health: { await gate.next() }, locate: { nil },
            store: LeoClaudeOnboardingStore(defaults: LeoInMemoryDefaults()), presenter: presenter, now: { clock.now }
        )
    }

    /// Lets the model's task reach its suspension point.
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func aMissingClaudeOffersOnboardingOnceAndRemembersIt() async {
        let sources = Sources(.missing), presenter = Presenter()
        let defaults = LeoInMemoryDefaults()
        presenter.answer = false
        let model = model(sources, presenter, defaults: defaults)

        await model.snapshotLanded(hasLiveLocalDaemon: true)
        await model.snapshotLanded(hasLiveLocalDaemon: true)

        #expect(presenter.offers == 1)
        #expect(LeoClaudeOnboardingStore(defaults: defaults).wasOffered)
        #expect(sources.locateCalls == 0)
    }

    @Test func aFoundClaudeOffersNothingAndNeverRunsTheLocator() async {
        let sources = Sources(.found(path: "/x/claude")), presenter = Presenter()

        await model(sources, presenter).snapshotLanded(hasLiveLocalDaemon: true)

        #expect(presenter.offers == 0)
        #expect(sources.locateCalls == 0)
    }

    @Test func withoutALiveLocalDaemonNothingIsAsked() async {
        let sources = Sources(.missing), presenter = Presenter()

        await model(sources, presenter).snapshotLanded(hasLiveLocalDaemon: false)

        #expect(sources.healthCalls == 0)
        #expect(presenter.offers == 0)
    }

    @Test func anAlreadyOfferedSetupIsNotAskedAboutAgain() async {
        let sources = Sources(.missing), presenter = Presenter()
        let defaults = LeoInMemoryDefaults()
        LeoClaudeOnboardingStore(defaults: defaults).markOffered()

        await model(sources, presenter, defaults: defaults).snapshotLanded(hasLiveLocalDaemon: true)

        #expect(sources.healthCalls == 0)
        #expect(presenter.offers == 0)
    }

    @Test func anOlderDaemonFallsBackToTheLocator() async {
        let missing = Sources(.unreported, located: nil), presenter = Presenter()
        presenter.answer = false

        await model(missing, presenter).snapshotLanded(hasLiveLocalDaemon: true)

        #expect(missing.locateCalls == 1)
        #expect(presenter.offers == 1)
    }

    @Test func anOlderDaemonWithClaudeOnDiskNeverAsksAgain() async {
        let sources = Sources(.unreported, located: "/opt/homebrew/bin/claude"), presenter = Presenter()
        let defaults = LeoInMemoryDefaults()
        let model = model(sources, presenter, defaults: defaults)

        await model.snapshotLanded(hasLiveLocalDaemon: true)
        await model.snapshotLanded(hasLiveLocalDaemon: true)

        #expect(presenter.offers == 0)
        #expect(sources.locateCalls == 1)
        #expect(LeoClaudeOnboardingStore(defaults: defaults).wasOffered)
    }

    @Test func choosingSetUpRunsTheInstaller() async {
        let sources = Sources(.missing), presenter = Presenter()
        presenter.answer = true

        await model(sources, presenter).snapshotLanded(hasLiveLocalDaemon: true)

        #expect(presenter.setUps == 1)
    }

    @Test func notNowDoesNotRunTheInstaller() async {
        let sources = Sources(.missing), presenter = Presenter()
        presenter.answer = false

        await model(sources, presenter).snapshotLanded(hasLiveLocalDaemon: true)

        #expect(presenter.setUps == 0)
    }

    // MARK: hiding the offer once claude turns up

    @Test func theOpenOfferIsWithdrawnOnceHealthSaysFound() async {
        let sources = Sources(.missing, .missing, .found(path: "/x/claude")), presenter = Presenter()
        let model = model(sources, presenter)
        let first = Task { await model.snapshotLanded(hasLiveLocalDaemon: true) }
        await settle()
        #expect(presenter.offers == 1)

        await model.recheckOpenOffer()
        #expect(presenter.withdrawals == 0)
        await model.recheckOpenOffer()
        await first.value

        #expect(presenter.withdrawals == 1)
        #expect(presenter.setUps == 0)
    }

    @Test func claudeAppearingWhileTheUserClicksNotNowDoesNotTouchTheClosedOffer() async {
        let gate = GatedHealth(), presenter = Presenter()
        let model = gatedModel(gate, presenter)
        let first = Task { await model.snapshotLanded(hasLiveLocalDaemon: true) }
        await settle()
        gate.answer(.missing)
        await settle()
        #expect(presenter.offers == 1)

        let recheck = Task { await model.recheckOpenOffer() }
        await settle()
        #expect(gate.calls == 2)
        presenter.answerVisibleOffer(false)
        await first.value
        gate.answer(.found(path: "/x/claude"))
        await recheck.value

        #expect(presenter.withdrawals == 0)
    }

    @Test func aStaleRecheckNeverWithdrawsALaterOffer() async {
        let gate = GatedHealth(), presenter = Presenter()
        let model = gatedModel(gate, presenter)
        let first = Task { await model.snapshotLanded(hasLiveLocalDaemon: true) }
        await settle()
        gate.answer(.missing)
        await settle()
        let recheck = Task { await model.recheckOpenOffer() }
        await settle()
        presenter.answerVisibleOffer(false)
        await first.value

        let second = Task { await model.claudeNotFound() }
        await settle()
        #expect(presenter.offers == 2)
        gate.answer(.found(path: "/x/claude"))
        await recheck.value

        #expect(presenter.withdrawals == 0)
        presenter.answerVisibleOffer(false)
        await second.value
    }

    @Test func overlappingRechecksShareOneHealthCall() async {
        let gate = GatedHealth(), presenter = Presenter()
        let model = gatedModel(gate, presenter)
        let first = Task { await model.snapshotLanded(hasLiveLocalDaemon: true) }
        await settle()
        gate.answer(.missing)
        await settle()

        let a = Task { await model.recheckOpenOffer() }
        await settle()
        let b = Task { await model.recheckOpenOffer() }
        await settle()

        #expect(gate.calls == 2)
        gate.answer(.missing)
        await a.value
        await b.value
        presenter.answerVisibleOffer(false)
        await first.value
    }

    @Test func snapshotsRecheckTheOpenOfferAtMostOnceEveryTwoSeconds() async {
        let sources = Sources(.missing, .missing, .missing, .missing), presenter = Presenter()
        let clock = Clock()
        let model = model(sources, presenter, clock: clock)
        let first = Task { await model.snapshotLanded(hasLiveLocalDaemon: true) }
        await settle()
        #expect(sources.healthCalls == 1)

        await model.snapshotLanded(hasLiveLocalDaemon: true)
        #expect(sources.healthCalls == 2)
        clock.now += 1.9
        await model.snapshotLanded(hasLiveLocalDaemon: true)
        await model.snapshotLanded(hasLiveLocalDaemon: true)
        #expect(sources.healthCalls == 2)
        clock.now += 0.2
        await model.snapshotLanded(hasLiveLocalDaemon: true)
        #expect(sources.healthCalls == 3)

        // App activation always rechecks.
        await model.recheckOpenOffer()
        #expect(sources.healthCalls == 4)
        presenter.answerVisibleOffer(false)
        await first.value
    }

    @Test func aRecheckWithNoOpenOfferAsksNothing() async {
        let sources = Sources(.missing), presenter = Presenter()

        await model(sources, presenter).recheckOpenOffer()

        #expect(sources.healthCalls == 0)
    }

    // MARK: polling an idle daemon

    private func pollingModel(
        _ sources: Sources, _ presenter: Presenter, clock: Clock, ticks: LeoFiringClock
    ) -> LeoClaudeOnboardingModel {
        LeoClaudeOnboardingModel(
            health: { sources.nextHealth() }, locate: { sources.locate() },
            store: LeoClaudeOnboardingStore(defaults: LeoInMemoryDefaults()), presenter: presenter, now: { clock.now },
            sleep: { try await ticks.sleep(UInt64($0 * 1_000_000_000)) }
        )
    }

    private static let pollTick = UInt64(LeoClaudeOnboardingModel.recheckInterval * 1_000_000_000)

    @Test func theOpenOfferIsWithdrawnByPollingWhenNoSnapshotEverArrives() async {
        let sources = Sources(.missing, .missing, .found(path: "/x/claude")), presenter = Presenter()
        let clock = Clock(), ticks = LeoFiringClock()
        let model = pollingModel(sources, presenter, clock: clock, ticks: ticks)
        let first = Task { await model.snapshotLanded(hasLiveLocalDaemon: true) }
        await settle()
        #expect(presenter.offers == 1)

        clock.now += LeoClaudeOnboardingModel.recheckInterval
        ticks.fire(Self.pollTick)
        await settle()
        #expect(presenter.withdrawals == 0)
        clock.now += LeoClaudeOnboardingModel.recheckInterval
        ticks.fire(Self.pollTick)
        await settle()
        let withdrawals = presenter.withdrawals
        presenter.answerVisibleOffer(false)
        await first.value

        #expect(withdrawals == 1)
        #expect(ticks.pending(Self.pollTick).isEmpty)
    }

    @Test func nothingPollsWhileNoOfferIsOpen() async {
        let sources = Sources(.found(path: "/x/claude")), presenter = Presenter()
        let ticks = LeoFiringClock()
        let model = pollingModel(sources, presenter, clock: Clock(), ticks: ticks)

        await model.snapshotLanded(hasLiveLocalDaemon: true)
        await settle()

        #expect(ticks.pending(Self.pollTick).isEmpty)
        #expect(sources.healthCalls == 1)
    }

    @Test func pollingStopsOnceTheOfferIsAnswered() async {
        let sources = Sources(.missing), presenter = Presenter()
        let clock = Clock(), ticks = LeoFiringClock()
        let model = pollingModel(sources, presenter, clock: clock, ticks: ticks)
        let first = Task { await model.snapshotLanded(hasLiveLocalDaemon: true) }
        await settle()
        #expect(ticks.pending(Self.pollTick).count == 1)

        presenter.answerVisibleOffer(false)
        await first.value
        await settle()

        #expect(ticks.pending(Self.pollTick).isEmpty)
        let calls = sources.healthCalls
        clock.now += 10
        ticks.fire(Self.pollTick)
        await settle()
        #expect(sources.healthCalls == calls)
    }

    // MARK: a spawn that failed with claude_not_found

    @Test func aFailedSpawnOffersEvenAfterTheFirstRunOfferWasShown() async {
        let sources = Sources(.missing), presenter = Presenter()
        let defaults = LeoInMemoryDefaults()
        LeoClaudeOnboardingStore(defaults: defaults).markOffered()
        presenter.answer = true

        await model(sources, presenter, defaults: defaults).claudeNotFound()

        #expect(presenter.offers == 1)
        #expect(presenter.setUps == 1)
    }

    @Test func aFailedSpawnWhileAnOfferIsOpenDoesNotStackAnother() async {
        let sources = Sources(.missing), presenter = Presenter()
        let model = model(sources, presenter)
        let first = Task { await model.snapshotLanded(hasLiveLocalDaemon: true) }
        await settle()

        await model.claudeNotFound()

        #expect(presenter.offers == 1)
        presenter.answerVisibleOffer(false)
        await first.value
    }
}
