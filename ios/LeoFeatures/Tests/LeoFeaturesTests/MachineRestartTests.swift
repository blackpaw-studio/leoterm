import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct MachineRestartTests {
    typealias Store = TestStore<MachineRestart.State, MachineRestart.Action>

    @MainActor
    struct Harness {
        let store: Store
        let fake: LeoFakeConfigClient
        let clock: TestClock<Duration>
        let now: LockIsolated<Date>

        var state: MachineRestart.State { store.state }

        func statusReads() async -> Int {
            await fake.calls.filter { $0 == .serviceStatus }.count
        }

        /// One second goes by on both the clock the wait sleeps on and the date it reads.
        func tick(seconds: Double = 1) async {
            now.withValue { $0 = $0.addingTimeInterval(seconds) }
            await clock.advance(by: .seconds(1))
        }

        /// Asks for a daemon restart and confirms it.
        func startDaemonRestart() async {
            await store.send(.requested(.daemon))
            await store.receive(\.statusChecked)
            guard let alert = state.alert, let button = alert.buttons.first(where: { $0.role != .cancel }), let action = button.action.action else {
                Issue.record("no confirmation")
                return
            }
            await store.send(.alert(.presented(action)))
            await store.receive(\.restartAccepted)
        }
    }

    nonisolated static let epoch = Date(timeIntervalSince1970: 1_792_738_800)

    static func harness(running: [String] = ["zeus", "hera"], agentsRestart: LeoAgentsRestartResult = LeoAgentsRestartResult()) async throws -> Harness {
        let fake = try ConfigGolden.client()
        await fake.setService(LeoFakeServiceState(
            pid: 10, processes: running.map { LeoServiceProcess(name: $0, status: "running") } + [LeoServiceProcess(name: "ares", status: "stopped")],
            log: "line\n", agentsRestart: agentsRestart
        ))
        let clock = TestClock()
        let now = LockIsolated(epoch)
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        let store = TestStore(initialState: MachineRestart.State(machine: "Dionysus", connection: connection)) {
            MachineRestart()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.continuousClock = clock
            $0.date = DateGenerator { now.value }
        }
        store.exhaustivity = .off
        return Harness(store: store, fake: fake, clock: clock, now: now)
    }

    // MARK: asking

    @Test func confirmNamesMachineAndAgentCount() async throws {
        let harness = try await Self.harness(running: ["zeus", "hera"])

        await harness.store.send(.requested(.agents))
        await harness.store.receive(\.statusChecked)

        let alert = try #require(harness.state.alert)
        #expect(String(state: alert.title) == "Restart all agents on Dionysus?")
        #expect(alert.message.map { String(state: $0) } == LeoServiceText.agentsRestartMessage(running: 2))
        #expect(await harness.fake.calls.contains(.restartAgents) == false)

        await harness.store.send(.alert(.dismiss))
        await harness.store.send(.requested(.daemon))
        await harness.store.receive(\.statusChecked)
        let daemonAlert = try #require(harness.state.alert)
        #expect(String(state: daemonAlert.title) == "Restart leo on Dionysus?")
        #expect(daemonAlert.message.map { String(state: $0) } == "2 running agents keep their tmux sessions.")
        #expect(await harness.statusReads() == 2)
    }

    @Test func confirmActsOnAlertPayload() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.requested(.daemon))
        await harness.store.receive(\.statusChecked)
        let button = try #require(harness.state.alert?.buttons.first { $0.role != .cancel })
        let action = try #require(button.action.action)
        // The daemon restarts before the button is pressed: the restart is
        // still told apart from the process the question was asked about.
        await harness.fake.finishServiceRestart()
        await harness.store.send(.alert(.presented(action)))
        await harness.store.receive(\.restartAccepted)

        await harness.tick()
        await harness.store.receive(\.waitEnded)

        #expect(harness.state.phase == .idle)
        #expect(harness.state.notice == "leo restarted on Dionysus.")
    }

    // MARK: waiting

    @Test func drainPollsDontSpendBudget() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()

        for _ in 0..<70 {
            await harness.tick()
            await harness.store.receive(\.waitProgress)
        }
        #expect(harness.state.phase == .restarting(waitingOnAgents: true))
        #expect(harness.state.errorMessage == nil)

        await harness.fake.finishServiceRestart()
        await harness.tick()
        await harness.store.receive(\.waitEnded)
        #expect(harness.state.phase == .idle)
        #expect(harness.state.notice == "leo restarted on Dionysus.")
    }

    @Test func newPidEndsWait() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()
        await harness.fake.finishServiceRestart()

        await harness.tick()
        await harness.store.receive(\.waitEnded)

        #expect(harness.state.phase == .idle)
        #expect(harness.state.errorMessage == nil)
    }

    @Test func deadlineGivesUpWithAgentsMessage() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()
        await harness.tick()
        await harness.store.receive(\.waitProgress)

        await harness.tick(seconds: LeoServicePane.defaultRestartDeadline)
        await harness.store.receive(\.waitEnded)

        #expect(harness.state.phase == .idle)
        #expect(harness.state.errorMessage == LeoServiceText.gaveUp(afterDown: false, machine: "Dionysus"))
    }

    @Test func deadlineChecksBeforeEveryPoll() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()
        let readsBefore = await harness.statusReads()

        // The old daemon would answer, as the same process, but the deadline
        // passed while the wait slept: nothing more is asked of it.
        await harness.tick(seconds: LeoServicePane.defaultRestartDeadline + 1)
        await harness.store.receive(\.waitEnded)

        #expect(await harness.statusReads() == readsBefore)
        #expect(harness.state.errorMessage == LeoServiceText.gaveUp(afterDown: false, machine: "Dionysus"))
    }

    @Test func unreachableBudgetGivesUp() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()

        for _ in 0..<LeoServicePane.defaultMaxRestartPolls {
            await harness.fake.failNextRead(with: LeoDaemonError.daemon(code: "unavailable", message: "down", matches: []))
            await harness.tick()
        }
        await harness.store.receive(\.waitEnded)

        #expect(harness.state.phase == .idle)
        #expect(harness.state.errorMessage == LeoServiceText.gaveUp(afterDown: true, machine: "Dionysus"))
    }

    @Test func inProgressCountsAsStarted() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()
        await harness.store.send(.waitEnded(.gaveUp(afterDown: false)))

        await harness.startDaemonRestart()

        #expect(harness.state.notice == "A restart is already in progress on Dionysus.")
        #expect(harness.state.errorMessage == nil)
        #expect(harness.state.isRestarting)
    }

    // MARK: agents and reload

    @Test func restartAllSummary() async throws {
        let harness = try await Self.harness(agentsRestart: LeoAgentsRestartResult(restarted: ["zeus", "hera"], skipped: ["ares"], failed: [:]))
        await harness.store.send(.requested(.agents))
        await harness.store.receive(\.statusChecked)
        let button = try #require(harness.state.alert?.buttons.first { $0.role != .cancel })
        await harness.store.send(.alert(.presented(try #require(button.action.action))))
        await harness.store.receive(\.agentsRestarted)

        #expect(harness.state.agentsSummary == "Restarted 2 agents. 1 skipped.")
        #expect(harness.state.phase == .idle)
    }

    @Test func aSecondRequestWhileBusyIsIgnored() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()

        await harness.store.send(.requested(.agents))
        await harness.store.send(.reloadRequested)

        let alert = try #require(harness.state.alert)
        #expect(String(state: alert.title) == "A restart is already in progress")
        #expect(alert.message.map { String(state: $0) } == "leo on Dionysus is already restarting.")
        #expect(harness.state.phase == .restarting(waitingOnAgents: false))
        #expect(await harness.fake.calls.contains(.reloadConfig) == false)
    }

    @Test func aRestartAskedWhileAnotherIsBeingAskedSaysSoToo() async throws {
        let connection = DaemonConnection(daemon: .dionysus, secrets: DaemonSecrets(token: "t"))
        var checking = MachineRestart.State(machine: "Dionysus", connection: connection)
        checking.phase = .checking
        let store = TestStore(initialState: checking) { MachineRestart() }

        await store.send(.requested(.daemon)) {
            $0.alert = AlertState {
                TextState("A restart is already in progress")
            } actions: {
                ButtonState(role: .cancel) { TextState("OK") }
            } message: {
                TextState("leo on Dionysus is already restarting.")
            }
        }
    }

    @Test func aDaemonRestartWithOneAgentSaysAgentNotAgents() async throws {
        let harness = try await Self.harness(running: ["zeus"])

        await harness.store.send(.requested(.daemon))
        await harness.store.receive(\.statusChecked)

        #expect(harness.state.alert?.message.map { String(state: $0) } == "1 running agent keeps its tmux sessions.")
    }

    // MARK: the app leaving the foreground

    @Test func theWaitStopsInTheBackgroundAndAFreshOneReadsANewPid() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()
        let readsBefore = await harness.statusReads()

        await harness.store.send(.scenePhaseChanged(isActive: false))
        // Thirteen minutes pass, the daemon restarts meanwhile.
        await harness.fake.finishServiceRestart()
        harness.now.withValue { $0 = $0.addingTimeInterval(13 * 60) }
        await harness.clock.advance(by: .seconds(13 * 60))
        #expect(harness.state.phase == .restarting(waitingOnAgents: false))
        #expect(harness.state.errorMessage == nil)
        #expect(await harness.statusReads() == readsBefore)

        await harness.store.send(.scenePhaseChanged(isActive: true))
        await harness.tick()
        await harness.store.receive(\.waitEnded)

        #expect(harness.state.phase == .idle)
        #expect(harness.state.notice == "leo restarted on Dionysus.")
        #expect(harness.state.errorMessage == nil)
    }

    @Test func aRestartAcceptedWhileInTheBackgroundWaitsOnlyOnceBackInTheForeground() async throws {
        let harness = try await Self.harness()
        await harness.store.send(.requested(.daemon))
        await harness.store.receive(\.statusChecked)
        let action = try #require(harness.state.alert?.buttons.first { $0.role != .cancel }?.action.action)
        await harness.fake.holdWrites()
        await harness.store.send(.alert(.presented(action)))
        #expect(harness.state.phase == .working)

        // The app leaves while the request is still in flight; the daemon takes it.
        await harness.store.send(.scenePhaseChanged(isActive: false))
        await harness.fake.releaseWrites()
        await harness.store.receive(\.restartAccepted)
        await harness.fake.finishServiceRestart()
        harness.now.withValue { $0 = $0.addingTimeInterval(13 * 60) }
        await harness.clock.advance(by: .seconds(13 * 60))
        #expect(harness.state.phase == .restarting(waitingOnAgents: false))
        #expect(harness.state.errorMessage == nil)

        await harness.store.send(.scenePhaseChanged(isActive: true))
        await harness.tick()
        await harness.store.receive(\.waitEnded)

        #expect(harness.state.phase == .idle)
        #expect(harness.state.notice == "leo restarted on Dionysus.")
    }

    @Test func theOldPidAfterResumeDoesNotReadAsRestarted() async throws {
        let harness = try await Self.harness()
        await harness.startDaemonRestart()
        await harness.store.send(.scenePhaseChanged(isActive: false))
        harness.now.withValue { $0 = $0.addingTimeInterval(13 * 60) }
        await harness.clock.advance(by: .seconds(13 * 60))

        await harness.store.send(.scenePhaseChanged(isActive: true))
        await harness.tick()
        await harness.store.receive(\.waitProgress)

        #expect(harness.state.phase == .restarting(waitingOnAgents: true))
        #expect(harness.state.notice == nil)
        #expect(harness.state.errorMessage == nil)
    }

    @Test func comingToTheForegroundWithNothingRestartingDoesNothing() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.scenePhaseChanged(isActive: true))
        await harness.store.send(.scenePhaseChanged(isActive: false))

        #expect(harness.state.phase == .idle)
        #expect(await harness.statusReads() == 0)
    }

    @Test func reloadSaysSo() async throws {
        let harness = try await Self.harness()

        await harness.store.send(.reloadRequested)
        await harness.store.receive(\.reloaded)

        #expect(harness.state.notice == "Configuration reloaded on Dionysus.")
        #expect(harness.state.phase == .idle)
    }
}
