import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct AgentDetailTests {
    static let zeus = Agent(.make("zeus", attention: .state(.needsInput, 2)))

    static func state(_ agent: Agent = zeus) -> AgentDetail.State {
        AgentDetail.State(daemon: .dionysus, agent: agent, connection: .connected)
    }

    @Test func stoppingAsksForConfirmationFirst() async {
        let performed = LockIsolated<[String]>([])
        let store = TestStore(initialState: Self.state()) {
            AgentDetail()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.perform = { connection, agent, command in
                performed.withValue { $0.append("\(connection.daemonID) \(agent) \(command)") }
            }
        }
        await store.send(.stopButtonTapped) {
            $0.confirmation = AgentDetail.confirmation(for: .stop, agent: "zeus")
        }
        #expect(performed.value.isEmpty)
        await store.send(\.confirmation.presented.perform, .stop) {
            $0.confirmation = nil
            $0.inFlight = .stop
        }
        await store.receive(\.commandFinished) { $0.inFlight = nil }
        #expect(performed.value == ["d-dionysus zeus stop"])
    }

    @Test(arguments: [AgentCommand.stop, .restart, .interrupt])
    func destructiveConfirmationsNameTheAgentAndUseADestructiveButton(_ command: AgentCommand) throws {
        let dialog = AgentDetail.confirmation(for: command, agent: "zeus")
        #expect(String(state: dialog.title).contains("zeus"))
        let button = try #require(dialog.buttons.first)
        #expect(button.role == .destructive)
        #expect(dialog.buttons.contains { $0.role == .cancel })
    }

    @Test func cancellingTheConfirmationDoesNothing() async {
        let store = TestStore(initialState: Self.state()) { AgentDetail() }
        await store.send(.restartButtonTapped) {
            $0.confirmation = AgentDetail.confirmation(for: .restart, agent: "zeus")
        }
        await store.send(.confirmation(.dismiss)) { $0.confirmation = nil }
    }

    @Test func aFailedActionShowsTheDaemonsReason() async {
        let store = TestStore(initialState: Self.state()) {
            AgentDetail()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.perform = { _, _, _ in
                throw LeoDaemonError.daemon(code: "not_found", message: #"no such agent "zeus""#, matches: [])
            }
        }
        await store.send(.interruptButtonTapped) {
            $0.confirmation = AgentDetail.confirmation(for: .interrupt, agent: "zeus")
        }
        await store.send(\.confirmation.presented.perform, .interrupt) {
            $0.confirmation = nil
            $0.inFlight = .interrupt
        }
        await store.receive(\.commandFinished) {
            $0.inFlight = nil
            $0.alert = AlertState {
                TextState("Couldn't Interrupt zeus")
            } actions: {
                ButtonState(role: .cancel) { TextState("OK") }
            } message: {
                TextState(#"no such agent "zeus""#)
            }
        }
    }

    @Test func startingAStoppedAgentNeedsNoConfirmation() async {
        var stopped = Self.zeus
        stopped.status = .stopped
        let store = TestStore(initialState: Self.state(stopped)) {
            AgentDetail()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.perform = { _, _, command in #expect(command == .start) }
        }
        await store.send(.startButtonTapped) { $0.inFlight = .start }
        await store.receive(\.commandFinished) { $0.inFlight = nil }
    }

    @Test func switchingEnvironmentOffersTheCatalogThenRestartsWithTheChoice() async {
        var agent = Self.zeus
        agent.environments = LeoAgentEnvironments(names: ["work"], source: .override, error: nil)
        let performed = LockIsolated<[AgentCommand]>([])
        let store = TestStore(initialState: Self.state(agent)) {
            AgentDetail()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.environmentNames = { _ in ["aws", "work"] }
            $0.daemonClient.perform = { _, _, command in performed.withValue { $0.append(command) } }
        }
        await store.send(.switchEnvironmentButtonTapped) { $0.isLoadingEnvironments = true }
        await store.receive(\.environmentsLoaded.success) {
            $0.isLoadingEnvironments = false
            $0.confirmation = AgentDetail.environmentPicker(names: ["aws", "work"], current: agent.environments, agent: "zeus")
        }
        await store.send(\.confirmation.presented.perform, .setEnvironments(["aws"])) {
            $0.confirmation = nil
            $0.inFlight = .setEnvironments(["aws"])
        }
        await store.receive(\.commandFinished) { $0.inFlight = nil }
        #expect(performed.value == [.setEnvironments(["aws"])])
    }

    @Test func theEnvironmentPickerMarksTheCurrentChoiceAndOffersTheDefault() {
        let picker = AgentDetail.environmentPicker(
            names: ["aws", "work"], current: LeoAgentEnvironments(names: ["work"], source: .override, error: nil), agent: "zeus"
        )
        let labels = picker.buttons.map { String(state: $0.label) }
        #expect(labels == ["aws", "work (current)", "Template Default", "Cancel"])
    }

    @Test func anEnvironmentCatalogFailureShowsAnAlert() async {
        let store = TestStore(initialState: Self.state()) {
            AgentDetail()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.environmentNames = { _ in throw LeoDaemonError.daemon(code: nil, message: "config unavailable", matches: []) }
        }
        await store.send(.switchEnvironmentButtonTapped) { $0.isLoadingEnvironments = true }
        await store.receive(\.environmentsLoaded.failure) {
            $0.isLoadingEnvironments = false
            $0.alert = AlertState {
                TextState("Couldn't Load Environments")
            } actions: {
                ButtonState(role: .cancel) { TextState("OK") }
            } message: {
                TextState("config unavailable")
            }
        }
    }

    @Test func opensClaudeCodeForClaudeAgents() async {
        let opened = LockIsolated<URL?>(nil)
        let store = TestStore(initialState: Self.state()) {
            AgentDetail()
        } withDependencies: {
            $0.openURL = .init { url in opened.setValue(url); return true }
        }
        #expect(store.state.agent?.opensInClaude == true)
        await store.send(.openInClaudeButtonTapped)
        #expect(opened.value == URL(string: "https://claude.ai/code"))
    }

    @Test func onlyClaudeAgentsOpenInClaude() {
        #expect(Agent(.make("a", harness: "claude")).opensInClaude)
        #expect(!Agent(.make("b", harness: "codex")).opensInClaude)
        #expect(!Agent(.make("c", harness: nil)).opensInClaude)
    }

    @Test func aMissingTokenFailsTheActionWithoutARequest() async {
        let store = TestStore(initialState: Self.state()) {
            AgentDetail()
        } withDependencies: {
            $0.secrets.load = { _ in nil }
        }
        await store.send(.startButtonTapped) { $0.inFlight = .start }
        await store.receive(\.commandFinished) {
            $0.inFlight = nil
            $0.alert = AlertState {
                TextState("Couldn't Start zeus")
            } actions: {
                ButtonState(role: .cancel) { TextState("OK") }
            } message: {
                TextState("No saved token for dionysus. Pair it again.")
            }
        }
    }
}
